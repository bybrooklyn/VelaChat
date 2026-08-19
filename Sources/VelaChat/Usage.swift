import Foundation
import Observation

/// Local, per-provider usage accounting — the layer that makes
/// subscription quotas legible. Hourly buckets are enough to derive a
/// rolling 5-hour window (Claude-style), today, this week, and this
/// month; kept ~35 days and pruned on load.
struct UsageBucket: Codable, Equatable {
    var requests: Int = 0
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    /// Sum of real-priced replies only — never estimated from guessed
    /// pricing (house rule: unobserved numbers are never implied).
    var costUSD: Double = 0
    var pricedRequests: Int = 0

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        pricedRequests = try container.decodeIfPresent(Int.self, forKey: .pricedRequests) ?? 0
    }
}

struct UsageWindow {
    var requests = 0
    var promptTokens = 0
    var completionTokens = 0
    var costUSD = 0.0
    var pricedRequests = 0

    var totalTokens: Int { promptTokens + completionTokens }
    /// Only shown when every counted request had real pricing… no — shown
    /// whenever any priced spend exists, labeled as a minimum when some
    /// requests were unpriced.
    var costLabel: String? {
        guard costUSD > 0 else { return nil }
        let value = String(format: "$%.4f", costUSD)
        return pricedRequests < requests ? "≥ \(value)" : value
    }
}

@MainActor
@Observable
final class UsageStore {
    /// Keyed "providerID|hourIndex" (hourIndex = unix epoch / 3600).
    private(set) var buckets: [String: UsageBucket] = [:]
    private let key = "velachat.usage-ledger"

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

extension UsageSummary {
    /// Real-priced cost for one reply — nil unless BOTH prices are known.
    func costUSD(for model: RemoteModel?) -> Double? {
        guard let model,
              let inputPrice = model.inputPricePerMillion,
              let outputPrice = model.outputPricePerMillion,
              let prompt = promptTokens, let completion = completionTokens else { return nil }
        return (Double(prompt) * inputPrice + Double(completion) * outputPrice) / 1_000_000
    }
}
