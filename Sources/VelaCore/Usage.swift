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

// MARK: - Durable request usage

/// Why a provider request was made. A user turn can produce more than one
/// request (for example, tool rounds and auto-continue), so this is stored on
/// every request instead of being inferred later from assistant messages.
public enum UsagePurpose: String, Codable, Sendable, CaseIterable {
    case chat
    case toolRound = "tool_round"
    case autoContinue = "auto_continue"
    case title
    case compaction
    case handoff
    case subagent
    /// Imported pre-ledger hourly buckets. These remain visible but are kept
    /// distinguishable from actual request rows because their per-request
    /// reporting coverage can no longer be reconstructed.
    case legacyAggregate = "legacy_aggregate"
}

/// Terminal state of one provider request. `unknown` is reserved for legacy
/// data whose original terminal state was not persisted.
public enum UsageOutcome: String, Codable, Sendable, CaseIterable {
    case succeeded
    case failed
    case cancelled
    case refused
    case unknown
}

/// Where token counts came from. This describes the evidence, not merely the
/// provider: a hosted provider may still lack usage fields and require a local
/// estimate, while a local runtime may report exact counts.
public enum UsageMetricProvenance: String, Codable, Sendable, CaseIterable {
    case providerReported = "provider_reported"
    case locallyEstimated = "locally_estimated"
    case persistedMessage = "persisted_message"
    case legacyAggregate = "legacy_aggregate"
}

/// Why a cost is trustworthy. The amount itself is optional at the
/// `RequestUsage` level: no evidence means unknown cost, never zero cost.
public enum CostProvenance: String, Codable, Sendable, CaseIterable {
    case providerReported = "provider_reported"
    case publishedPricingSnapshot = "published_pricing_snapshot"
    case legacyAggregate = "legacy_aggregate"
}

/// A dollar amount together with the rates that produced it. Provider-reported
/// amounts normally have no local rate snapshot. Locally derived amounts retain
/// the exact pricing inputs so historical totals do not change when a model's
/// current price changes.
public struct CostEvidence: Codable, Sendable, Equatable {
    public var amountUSD: Double
    public var provenance: CostProvenance
    public var inputPerMillion: Double?
    public var outputPerMillion: Double?
    public var reasoningPerMillion: Double?
    public var cacheReadPerMillion: Double?
    public var cacheWrite5mPerMillion: Double?
    public var cacheWrite1hPerMillion: Double?
    public var longContextInputPerMillion: Double?
    public var longContextOutputPerMillion: Double?
    public var longContextThresholdTokens: Int?
    public var pricingCapturedAt: Date?

    public init(
        amountUSD: Double,
        provenance: CostProvenance,
        inputPerMillion: Double? = nil,
        outputPerMillion: Double? = nil,
        reasoningPerMillion: Double? = nil,
        cacheReadPerMillion: Double? = nil,
        cacheWrite5mPerMillion: Double? = nil,
        cacheWrite1hPerMillion: Double? = nil,
        longContextInputPerMillion: Double? = nil,
        longContextOutputPerMillion: Double? = nil,
        longContextThresholdTokens: Int? = nil,
        pricingCapturedAt: Date? = nil
    ) {
        self.amountUSD = amountUSD
        self.provenance = provenance
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.reasoningPerMillion = reasoningPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWrite5mPerMillion = cacheWrite5mPerMillion
        self.cacheWrite1hPerMillion = cacheWrite1hPerMillion
        self.longContextInputPerMillion = longContextInputPerMillion
        self.longContextOutputPerMillion = longContextOutputPerMillion
        self.longContextThresholdTokens = longContextThresholdTokens
        self.pricingCapturedAt = pricingCapturedAt
    }

    public static func providerReported(_ amountUSD: Double) -> CostEvidence {
        CostEvidence(amountUSD: amountUSD, provenance: .providerReported)
    }

    public var isProviderReported: Bool { provenance == .providerReported }
}

/// Numeric rate-limit evidence observed alongside a request. Plan names and
/// response bodies deliberately do not belong here; the ledger only needs the
/// quantities and their reset time.
public struct UsageQuotaEvidence: Codable, Sendable, Equatable {
    public enum Provenance: String, Codable, Sendable, CaseIterable {
        case responseHeaders = "response_headers"
        case providerResult = "provider_result"
        case providerAPI = "provider_api"
    }

    public var provenance: Provenance
    public var observedAt: Date
    public var requestsRemaining: Int?
    public var requestsLimit: Int?
    public var tokensRemaining: Int?
    public var tokensLimit: Int?
    public var resetAt: Date?

    public init(
        provenance: Provenance,
        observedAt: Date = Date(),
        requestsRemaining: Int? = nil,
        requestsLimit: Int? = nil,
        tokensRemaining: Int? = nil,
        tokensLimit: Int? = nil,
        resetAt: Date? = nil
    ) {
        self.provenance = provenance
        self.observedAt = observedAt
        self.requestsRemaining = requestsRemaining
        self.requestsLimit = requestsLimit
        self.tokensRemaining = tokensRemaining
        self.tokensLimit = tokensLimit
        self.resetAt = resetAt
    }
}

/// Whether the number of contributing requests is known. New request rows use
/// `.exact(0 or 1)`. Legacy aggregates use `.indeterminate`, because the old
/// `UserDefaults` buckets converted absent usage to zero and did not remember
/// how many requests actually reported token counts.
public enum UsageReportingEvidence: Codable, Sendable, Equatable {
    case exact(reportedRequests: Int)
    case indeterminate

    public var reportedRequests: Int? {
        guard case .exact(let value) = self else { return nil }
        return value
    }
}

/// The non-content provenance of a row. `sourceID` below is an opaque UUID
/// (provider request ID, message ID, etc.), never prompt or response text.
public enum UsageRecordSource: String, Codable, Sendable, CaseIterable {
    case liveRequest = "live_request"
    case messageBackfill = "message_backfill"
    case legacyAggregate = "legacy_aggregate"
}

/// Canonical usage for one provider request, or for one explicitly marked
/// legacy aggregate. Every count is optional: `nil` means not reported and
/// `0` means reported as zero. That distinction is preserved as SQL NULL vs 0.
public struct RequestUsage: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var occurredAt: Date
    public var providerID: UUID?
    public var requestedModelID: String?
    public var effectiveModelID: String?
    public var purpose: UsagePurpose
    public var outcome: UsageOutcome

    /// Canonical logical input. It includes cache reads/writes when a provider
    /// reports them as separate lanes; those lanes remain duplicated below for
    /// pricing analysis and must not be added to this total again.
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWrite5mTokens: Int?
    public var cacheWrite1hTokens: Int?
    public var latencyMilliseconds: Int?
    public var metricProvenance: UsageMetricProvenance?
    public var cost: CostEvidence?
    public var quota: UsageQuotaEvidence?

    /// Normally one. Greater values are used only by imported hourly buckets.
    public var requestCount: Int
    public var usageReporting: UsageReportingEvidence
    public var costReporting: UsageReportingEvidence
    public var source: UsageRecordSource
    public var sourceID: UUID?

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        providerID: UUID? = nil,
        requestedModelID: String? = nil,
        effectiveModelID: String? = nil,
        purpose: UsagePurpose,
        outcome: UsageOutcome,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWrite5mTokens: Int? = nil,
        cacheWrite1hTokens: Int? = nil,
        latencyMilliseconds: Int? = nil,
        metricProvenance: UsageMetricProvenance? = nil,
        cost: CostEvidence? = nil,
        quota: UsageQuotaEvidence? = nil,
        requestCount: Int = 1,
        usageReporting: UsageReportingEvidence? = nil,
        costReporting: UsageReportingEvidence? = nil,
        source: UsageRecordSource = .liveRequest,
        sourceID: UUID? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.providerID = providerID
        self.requestedModelID = requestedModelID
        self.effectiveModelID = effectiveModelID
        self.purpose = purpose
        self.outcome = outcome
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.latencyMilliseconds = latencyMilliseconds
        self.metricProvenance = metricProvenance
        self.cost = cost
        self.quota = quota
        self.requestCount = requestCount

        let hasReportedUsage = [
            inputTokens, outputTokens, reasoningTokens, cacheReadTokens,
            cacheWrite5mTokens, cacheWrite1hTokens,
        ].contains { $0 != nil }
        self.usageReporting = usageReporting ?? .exact(reportedRequests: hasReportedUsage ? requestCount : 0)
        self.costReporting = costReporting ?? .exact(reportedRequests: cost == nil ? 0 : requestCount)
        self.source = source
        self.sourceID = sourceID
    }

    public var cacheWriteTokens: Int? {
        guard cacheWrite5mTokens != nil || cacheWrite1hTokens != nil else { return nil }
        return (cacheWrite5mTokens ?? 0) + (cacheWrite1hTokens ?? 0)
    }
}

/// Period selector used by the Usage & Limits screen. Seven and thirty days
/// include today plus the preceding 6/29 calendar days in the supplied local
/// calendar, which gives charts stable day buckets around DST changes.
public enum UsagePeriod: String, Codable, Sendable, CaseIterable {
    case today
    case sevenDays = "seven_days"
    case thirtyDays = "thirty_days"
    case allTime = "all_time"

    public func startDate(endingAt endDate: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: endDate)
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: endDate))
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: endDate))
        case .allTime:
            return nil
        }
    }
}

public struct UsageQuery: Sendable, Equatable {
    public var period: UsagePeriod
    public var endingAt: Date
    public var providerID: UUID?
    public var effectiveModelID: String?
    public var purpose: UsagePurpose?
    public var recentLimit: Int

    public init(
        period: UsagePeriod,
        endingAt: Date = Date(),
        providerID: UUID? = nil,
        effectiveModelID: String? = nil,
        purpose: UsagePurpose? = nil,
        recentLimit: Int = 50
    ) {
        self.period = period
        self.endingAt = endingAt
        self.providerID = providerID
        self.effectiveModelID = effectiveModelID
        self.purpose = purpose
        self.recentLimit = recentLimit
    }
}

/// Coverage stays explicit instead of letting an unknown request silently add
/// zero tokens or zero dollars to a total.
public struct UsageReportingCoverage: Codable, Sendable, Equatable {
    public var reportedRequests: Int
    public var unreportedRequests: Int
    public var indeterminateRequests: Int

    public init(reportedRequests: Int = 0, unreportedRequests: Int = 0, indeterminateRequests: Int = 0) {
        self.reportedRequests = reportedRequests
        self.unreportedRequests = unreportedRequests
        self.indeterminateRequests = indeterminateRequests
    }

    public var totalRequests: Int { reportedRequests + unreportedRequests + indeterminateRequests }

    /// Available only when every row's reporting count is known.
    public var exactFraction: Double? {
        guard totalRequests > 0, indeterminateRequests == 0 else { return nil }
        return Double(reportedRequests) / Double(totalRequests)
    }

    /// A truthful lower bound when legacy rows have indeterminate coverage.
    public var minimumFraction: Double? {
        guard totalRequests > 0 else { return nil }
        return Double(reportedRequests) / Double(totalRequests)
    }
}

public struct UsageTokenTotal: Codable, Sendable, Equatable {
    /// `nil` when no row supplied this metric; zero remains a real value.
    public var value: Int?
    public var coverage: UsageReportingCoverage

    public init(value: Int? = nil, coverage: UsageReportingCoverage = .init()) {
        self.value = value
        self.coverage = coverage
    }
}

public struct UsageCostTotal: Codable, Sendable, Equatable {
    /// `nil` means no request had cost evidence. A known free request is 0.
    public var amountUSD: Double?
    public var coverage: UsageReportingCoverage
    public var providerReportedRequests: Int
    public var pricingSnapshotRequests: Int
    public var legacyAggregateRequests: Int

    public init(
        amountUSD: Double? = nil,
        coverage: UsageReportingCoverage = .init(),
        providerReportedRequests: Int = 0,
        pricingSnapshotRequests: Int = 0,
        legacyAggregateRequests: Int = 0
    ) {
        self.amountUSD = amountUSD
        self.coverage = coverage
        self.providerReportedRequests = providerReportedRequests
        self.pricingSnapshotRequests = pricingSnapshotRequests
        self.legacyAggregateRequests = legacyAggregateRequests
    }
}

public struct UsageAggregate: Codable, Sendable, Equatable {
    public var recordCount: Int
    public var requestCount: Int
    public var turnCount: Int
    public var succeededRequests: Int
    public var failedRequests: Int
    public var cancelledRequests: Int
    public var refusedRequests: Int
    public var unknownOutcomeRequests: Int
    public var inputTokens: UsageTokenTotal
    public var outputTokens: UsageTokenTotal
    public var reasoningTokens: UsageTokenTotal
    public var cacheReadTokens: UsageTokenTotal
    public var cacheWrite5mTokens: UsageTokenTotal
    public var cacheWrite1hTokens: UsageTokenTotal
    public var usageReporting: UsageReportingCoverage
    public var cost: UsageCostTotal
    public var totalLatencyMilliseconds: Int
    public var latencyReportedRequests: Int

    public init() {
        recordCount = 0
        requestCount = 0
        turnCount = 0
        succeededRequests = 0
        failedRequests = 0
        cancelledRequests = 0
        refusedRequests = 0
        unknownOutcomeRequests = 0
        inputTokens = .init()
        outputTokens = .init()
        reasoningTokens = .init()
        cacheReadTokens = .init()
        cacheWrite5mTokens = .init()
        cacheWrite1hTokens = .init()
        usageReporting = .init()
        cost = .init()
        totalLatencyMilliseconds = 0
        latencyReportedRequests = 0
    }

    public var cacheWriteTokens: Int? {
        guard cacheWrite5mTokens.value != nil || cacheWrite1hTokens.value != nil else { return nil }
        return (cacheWrite5mTokens.value ?? 0) + (cacheWrite1hTokens.value ?? 0)
    }

    public var averageLatencyMilliseconds: Double? {
        guard latencyReportedRequests > 0 else { return nil }
        return Double(totalLatencyMilliseconds) / Double(latencyReportedRequests)
    }
}

public enum UsageBreakdownDimension: String, Codable, Sendable, CaseIterable {
    case provider
    case model
    case purpose
}

public struct UsageBreakdown: Codable, Sendable, Equatable, Identifiable {
    public var dimension: UsageBreakdownDimension
    /// Provider UUID string, effective model ID, or `UsagePurpose.rawValue`.
    /// `nil` is an intentionally visible “unknown” group.
    public var key: String?
    public var aggregate: UsageAggregate

    public init(dimension: UsageBreakdownDimension, key: String?, aggregate: UsageAggregate) {
        self.dimension = dimension
        self.key = key
        self.aggregate = aggregate
    }

    public var id: String { "\(dimension.rawValue)|\(key ?? "unknown")" }
}

public struct UsageTrendPoint: Codable, Sendable, Equatable, Identifiable {
    public var day: Date
    public var aggregate: UsageAggregate

    public init(day: Date, aggregate: UsageAggregate) {
        self.day = day
        self.aggregate = aggregate
    }

    public var id: Date { day }
}

public struct UsageReport: Sendable, Equatable {
    public var query: UsageQuery
    public var startDate: Date?
    public var aggregate: UsageAggregate
    public var trend: [UsageTrendPoint]
    public var providers: [UsageBreakdown]
    public var models: [UsageBreakdown]
    public var purposes: [UsageBreakdown]
    public var recent: [RequestUsage]

    public init(
        query: UsageQuery,
        startDate: Date?,
        aggregate: UsageAggregate,
        trend: [UsageTrendPoint],
        providers: [UsageBreakdown],
        models: [UsageBreakdown],
        purposes: [UsageBreakdown],
        recent: [RequestUsage]
    ) {
        self.query = query
        self.startDate = startDate
        self.aggregate = aggregate
        self.trend = trend
        self.providers = providers
        self.models = models
        self.purposes = purposes
        self.recent = recent
    }
}

/// One old `providerID|hourIndex` bucket. Callers should map zero token totals
/// to nil when `usageReportedRequests` is unknown; doing so avoids converting
/// the old store's “missing became zero” behavior into false observed zeros.
public struct LegacyUsageAggregate: Sendable, Equatable {
    public var id: UUID
    public var providerID: UUID
    public var hourStartingAt: Date
    public var requestCount: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cost: CostEvidence?
    public var usageReportedRequests: Int?
    public var costReportedRequests: Int?

    public init(
        id: UUID = UUID(),
        providerID: UUID,
        hourStartingAt: Date,
        requestCount: Int,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cost: CostEvidence? = nil,
        usageReportedRequests: Int? = nil,
        costReportedRequests: Int? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.hourStartingAt = hourStartingAt
        self.requestCount = requestCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
        self.usageReportedRequests = usageReportedRequests
        self.costReportedRequests = costReportedRequests
    }

    /// Loss-aware adapter for the pre-SQLite `UsageBucket` payload. Its zero
    /// token totals are ambiguous because the old recorder used `nil ?? 0`, so
    /// they migrate as unknown. A zero dollar amount is retained when
    /// `pricedRequests > 0`, because that is a genuinely observed free request.
    public init(providerID: UUID, hourIndex: Int, bucket: UsageBucket) {
        self.init(
            providerID: providerID,
            hourStartingAt: Date(timeIntervalSince1970: TimeInterval(hourIndex) * 3_600),
            requestCount: bucket.requests,
            inputTokens: bucket.promptTokens == 0 ? nil : bucket.promptTokens,
            outputTokens: bucket.completionTokens == 0 ? nil : bucket.completionTokens,
            cost: bucket.pricedRequests > 0
                ? CostEvidence(amountUSD: bucket.costUSD, provenance: .legacyAggregate)
                : nil,
            usageReportedRequests: nil,
            costReportedRequests: bucket.pricedRequests
        )
    }
}

/// A persisted assistant message prepared for ledger backfill. The message ID
/// is the dedupe key; no message content or title crosses this interface.
public struct MessageUsageBackfill: Sendable, Equatable {
    public var messageID: UUID
    public var usage: RequestUsage

    public init(messageID: UUID, usage: RequestUsage) {
        self.messageID = messageID
        self.usage = usage
    }
}

public struct UsageMigrationResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case applied, alreadyApplied }

    public var status: Status
    public var importedLegacyRows: Int
    public var backfilledMessages: Int
    public var skippedMessagesInsideLegacyRange: Int
    public var duplicateRows: Int

    public init(
        status: Status,
        importedLegacyRows: Int = 0,
        backfilledMessages: Int = 0,
        skippedMessagesInsideLegacyRange: Int = 0,
        duplicateRows: Int = 0
    ) {
        self.status = status
        self.importedLegacyRows = importedLegacyRows
        self.backfilledMessages = backfilledMessages
        self.skippedMessagesInsideLegacyRange = skippedMessagesInsideLegacyRange
        self.duplicateRows = duplicateRows
    }

    /// Both statuses prove a SQLite commit completed: `.applied` committed in
    /// this call, while `.alreadyApplied` read the durable migration marker from
    /// an earlier commit (for example, after a crash before defaults cleanup).
    /// Errors throw and never produce a result.
    public var mayClearLegacySource: Bool { true }
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

public extension RequestUsage {
    /// Snapshots the highest-authority published schedule at request time.
    /// Provider-reported cost always wins; unknown cache pricing leaves cost
    /// unknown rather than silently applying a universal multiplier.
    func applyingPublishedPricing(from model: RemoteModel?) -> RequestUsage {
        guard cost == nil, let model, let logicalInput = inputTokens, let output = outputTokens else { return self }
        let schedules = model.pricingEvidence.sorted { lhs, rhs in
            if lhs.source.priority != rhs.source.priority { return lhs.source.priority > rhs.source.priority }
            return lhs.exactModelMatch && !rhs.exactModelMatch
        }
        guard let schedule = schedules.first(where: { $0.inputPerMillion != nil && $0.outputPerMillion != nil }) else { return self }

        let longContext = schedule.longContextThresholdTokens.map { logicalInput > $0 } ?? false
        guard let inputRate = longContext ? (schedule.longContextInputPerMillion ?? schedule.inputPerMillion) : schedule.inputPerMillion,
              let outputRate = longContext ? (schedule.longContextOutputPerMillion ?? schedule.outputPerMillion) : schedule.outputPerMillion else {
            return self
        }
        let cacheRead = cacheReadTokens ?? 0
        let cacheWrite5m = cacheWrite5mTokens ?? 0
        let cacheWrite1h = cacheWrite1hTokens ?? 0
        let cacheWrite = cacheWrite5m + cacheWrite1h
        let cacheReadRate = longContext
            ? (schedule.longContextCacheReadPerMillion ?? schedule.cacheReadPerMillion)
            : schedule.cacheReadPerMillion
        let cacheWriteRate = longContext
            ? (schedule.longContextCacheWritePerMillion ?? schedule.cacheWritePerMillion)
            : schedule.cacheWritePerMillion
        if cacheRead > 0, cacheReadRate == nil { return self }
        if cacheWrite > 0, cacheWriteRate == nil { return self }

        let freshInput = max(0, logicalInput - cacheRead - cacheWrite)
        let separatelyPricedReasoning = schedule.reasoningPerMillion == nil ? 0 : min(reasoningTokens ?? 0, output)
        let ordinaryOutput = max(0, output - separatelyPricedReasoning)
        var amount = Double(freshInput) * inputRate
        amount += Double(cacheRead) * (cacheReadRate ?? 0)
        amount += Double(cacheWrite) * (cacheWriteRate ?? 0)
        amount += Double(ordinaryOutput) * outputRate
        amount += Double(separatelyPricedReasoning) * (schedule.reasoningPerMillion ?? outputRate)
        amount /= 1_000_000

        var copy = self
        copy.cost = CostEvidence(
            amountUSD: amount,
            provenance: .publishedPricingSnapshot,
            inputPerMillion: inputRate,
            outputPerMillion: outputRate,
            reasoningPerMillion: schedule.reasoningPerMillion,
            cacheReadPerMillion: cacheReadRate,
            cacheWrite5mPerMillion: cacheWriteRate,
            cacheWrite1hPerMillion: cacheWriteRate,
            longContextInputPerMillion: schedule.longContextInputPerMillion,
            longContextOutputPerMillion: schedule.longContextOutputPerMillion,
            longContextThresholdTokens: schedule.longContextThresholdTokens,
            pricingCapturedAt: Date()
        )
        return copy
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
