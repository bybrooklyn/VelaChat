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
