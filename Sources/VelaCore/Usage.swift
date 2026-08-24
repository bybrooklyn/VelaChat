import Foundation

/// Local, per-provider usage accounting — the layer that makes
/// subscription quotas legible. Hourly buckets are enough to derive a
/// rolling 5-hour window (Claude-style), today, this week, and this
/// month; kept ~35 days and pruned on load.
public struct UsageBucket: Codable, Equatable {
    public var requests: Int = 0
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    /// Sum of real-priced replies only — never estimated from guessed
    /// pricing (house rule: unobserved numbers are never implied).
    public var costUSD: Double = 0
    public var pricedRequests: Int = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        pricedRequests = try container.decodeIfPresent(Int.self, forKey: .pricedRequests) ?? 0
    }
}

public struct UsageWindow {
    public var requests = 0
    public var promptTokens = 0
    public var completionTokens = 0
    public var costUSD = 0.0
    public var pricedRequests = 0

    public init() {}

    public var totalTokens: Int { promptTokens + completionTokens }
    /// Only shown when every counted request had real pricing… no — shown
    /// whenever any priced spend exists, labeled as a minimum when some
    /// requests were unpriced.
    public var costLabel: String? {
        guard costUSD > 0 else { return nil }
        let value = String(format: "$%.4f", costUSD)
        return pricedRequests < requests ? "≥ \(value)" : value
    }
}

/// Cache pricing multipliers, expressed against the model's base input
/// rate. These are Anthropic's published ratios; providers that don't
/// price caching separately simply never report the token counts these
/// apply to, so the multipliers stay unused rather than wrong.
public enum CachePricing {
    /// A cache *read* — the cheap case, and the whole point of caching.
    public static let read = 0.10
    /// A cache *write* at the 5-minute TTL.
    public static let write5m = 1.25
    /// A cache *write* at the 1-hour TTL.
    public static let write1h = 2.0
    /// Batch requests bill at half.
    public static let batch = 0.5
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
    public func costUSD(for model: RemoteModel?, promptIncludesCached: Bool) -> Double? {
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
    public func costUSD(for model: RemoteModel?, providerKind: ProviderKind?) -> Double? {
        costUSD(for: model, promptIncludesCached: providerKind?.promptTokensIncludeCached ?? true)
    }

    /// True when the figure came from the provider rather than from this
    /// formula — the UI labels those differently.
    public var isCostProviderReported: Bool { providerReportedCostUSD != nil }
}
