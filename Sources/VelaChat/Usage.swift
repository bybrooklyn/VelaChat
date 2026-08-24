import Foundation
import VelaCore
import Observation

@MainActor
@Observable
final class UsageStore {
    /// Keyed "providerID|hourIndex" (hourIndex = unix epoch / 3600).
    private(set) var buckets: [String: UsageBucket] = [:]
    private let key = DefaultsKey.usageLedger

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: UsageBucket].self, from: data) {
            buckets = saved
        }
        prune()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(buckets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func prune(olderThanDays days: Int = 35) {
        let cutoff = Int(Date().timeIntervalSince1970 / 3600) - days * 24
        buckets = buckets.filter { entry in
            guard let hour = Int(entry.key.split(separator: "|").last ?? "") else { return false }
            return hour >= cutoff
        }
    }

    func record(providerID: UUID, promptTokens: Int?, completionTokens: Int?, costUSD: Double?) {
        let hour = Int(Date().timeIntervalSince1970 / 3600)
        let bucketKey = "\(providerID.uuidString)|\(hour)"
        var bucket = buckets[bucketKey] ?? UsageBucket()
        bucket.requests += 1
        bucket.promptTokens += promptTokens ?? 0
        bucket.completionTokens += completionTokens ?? 0
        if let costUSD {
            bucket.costUSD += costUSD
            bucket.pricedRequests += 1
        }
        buckets[bucketKey] = bucket
        prune()
        persist()
    }

    func window(providerID: UUID, since: Date) -> UsageWindow {
        let fromHour = Int(since.timeIntervalSince1970 / 3600)
        var window = UsageWindow()
        let prefix = providerID.uuidString + "|"
        for (bucketKey, bucket) in buckets where bucketKey.hasPrefix(prefix) {
            guard let hour = Int(bucketKey.split(separator: "|").last ?? ""), hour >= fromHour else { continue }
            window.requests += bucket.requests
            window.promptTokens += bucket.promptTokens
            window.completionTokens += bucket.completionTokens
            window.costUSD += bucket.costUSD
            window.pricedRequests += bucket.pricedRequests
        }
        return window
    }

    func rollingFiveHours(providerID: UUID) -> UsageWindow {
        window(providerID: providerID, since: Date().addingTimeInterval(-5 * 3600))
    }
    func today(providerID: UUID) -> UsageWindow {
        window(providerID: providerID, since: Calendar.current.startOfDay(for: Date()))
    }
    func thisWeek(providerID: UUID) -> UsageWindow {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date().addingTimeInterval(-7 * 86_400)
        return window(providerID: providerID, since: start)
    }
    func thisMonth(providerID: UUID) -> UsageWindow {
        let start = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date().addingTimeInterval(-30 * 86_400)
        return window(providerID: providerID, since: start)
    }
}
