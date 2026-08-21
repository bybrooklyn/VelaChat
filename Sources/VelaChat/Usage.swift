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

extension UsageSummary {
    /// Real-priced cost for one reply — nil unless BOTH prices are known.
    ///
    /// Previously this was `(prompt × input + completion × output)` with
    /// `cachedTokens` captured and then ignored, which was wrong in
    /// *opposite directions* depending on the provider:
    ///
    /// - **Anthropic** excludes cached tokens from `input_tokens` and
    ///   reports reads and writes separately. Neither was priced at all,
    ///   so the total undercounted — badly, since a cache write costs
    ///   1.25–2× base input.
    /// - **OpenAI-compatible** providers include cached tokens inside
    ///   `prompt_tokens`. The cached portion was therefore billed at full
    ///   input price instead of 0.10×, so the total overcounted.
    ///
    /// `promptIncludesCached` is the per-provider capability that decides
    /// which correction applies. It is passed in from `ProviderKind`
    /// rather than guessed at the call site.
    func costUSD(for model: RemoteModel?, promptIncludesCached: Bool) -> Double? {
        // A cost the provider computed itself always wins: it is observed,
        // not derived (house rule — unobserved numbers are never implied).
        if let providerReportedCostUSD { return providerReportedCostUSD }
        guard let model,
              let inputPrice = model.inputPricePerMillion,
              let outputPrice = model.outputPricePerMillion,
              let prompt = promptTokens, let completion = completionTokens else { return nil }

        let cacheReads = cachedTokens ?? 0
        // Fresh input is what was neither read from nor written to cache.
        // When the provider folds cache reads into its prompt count, they
        // have to come back out before pricing the remainder at full rate.
        let freshInput = promptIncludesCached ? max(0, prompt - cacheReads) : prompt

        var total = Double(freshInput) * inputPrice
        total += Double(completion) * outputPrice
        total += Double(cacheCreation5mTokens ?? 0) * inputPrice * CachePricing.write5m
        total += Double(cacheCreation1hTokens ?? 0) * inputPrice * CachePricing.write1h
        total += Double(cacheReads) * inputPrice * CachePricing.read
        total /= 1_000_000
        return isBatch ? total * CachePricing.batch : total
    }

    /// Convenience for call sites that have the provider rather than the
    /// raw capability flag.
    func costUSD(for model: RemoteModel?, providerKind: ProviderKind?) -> Double? {
        costUSD(for: model, promptIncludesCached: providerKind?.promptTokensIncludeCached ?? true)
    }

    /// True when the figure came from the provider rather than from this
    /// formula — the UI labels those differently.
    var isCostProviderReported: Bool { providerReportedCostUSD != nil }
}
