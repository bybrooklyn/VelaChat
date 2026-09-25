import Foundation
import SQLite3

public enum UsageLedgerError: Error, LocalizedError, Sendable {
    case invalidRecord(String)
    case couldNotOpen(String)
    case database(String)
    case corruptRecord(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRecord(let message): return "Invalid usage record: \(message)"
        case .couldNotOpen(let message): return "Could not open usage history: \(message)"
        case .database(let message): return "Usage history database error: \(message)"
        case .corruptRecord(let message): return "Usage history contains an invalid row: \(message)"
        }
    }
}

public enum UsageInsertResult: Sendable, Equatable {
    case inserted
    case duplicate
}

/// Durable, content-free request accounting.
///
/// The database contains opaque IDs, provider/model identifiers, enums, dates,
/// and numeric telemetry. It never accepts prompt text, response text,
/// attachment bytes/names, or conversation titles. The actor boundary keeps a
/// single SQLite connection serialized while generation and UI queries happen
/// concurrently.
public actor UsageLedger {
    public static let shared = UsageLedger()

    public nonisolated let databaseURL: URL
    private var database: OpaquePointer?

    public static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelaChat", isDirectory: true)
            .appendingPathComponent("usage.sqlite")
    }

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    // MARK: - Lifecycle

    public func open() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let handle { sqlite3_close_v2(handle) }
            throw UsageLedgerError.couldNotOpen(message)
        }
        database = handle
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5_000)

        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("PRAGMA foreign_keys=ON;")
            try createSchema()
        } catch {
            sqlite3_close_v2(handle)
            database = nil
            throw error
        }
    }

    /// Closes the connection without deleting history. The next operation
    /// reopens it; primarily useful to make temporary test databases removable.
    public func close() {
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS usage_records (
            id TEXT PRIMARY KEY NOT NULL,
            occurred_at REAL NOT NULL,
            provider_id TEXT,
            requested_model_id TEXT,
            effective_model_id TEXT,
            purpose TEXT NOT NULL,
            outcome TEXT NOT NULL,
            request_count INTEGER NOT NULL CHECK(request_count > 0),

            input_tokens INTEGER CHECK(input_tokens IS NULL OR input_tokens >= 0),
            output_tokens INTEGER CHECK(output_tokens IS NULL OR output_tokens >= 0),
            reasoning_tokens INTEGER CHECK(reasoning_tokens IS NULL OR reasoning_tokens >= 0),
            cache_read_tokens INTEGER CHECK(cache_read_tokens IS NULL OR cache_read_tokens >= 0),
            cache_write_5m_tokens INTEGER CHECK(cache_write_5m_tokens IS NULL OR cache_write_5m_tokens >= 0),
            cache_write_1h_tokens INTEGER CHECK(cache_write_1h_tokens IS NULL OR cache_write_1h_tokens >= 0),
            latency_ms INTEGER CHECK(latency_ms IS NULL OR latency_ms >= 0),
            metric_provenance TEXT,
            usage_reported_requests INTEGER CHECK(
                usage_reported_requests IS NULL OR
                (usage_reported_requests >= 0 AND usage_reported_requests <= request_count)
            ),

            cost_usd REAL CHECK(cost_usd IS NULL OR cost_usd >= 0),
            cost_provenance TEXT,
            input_price_per_million REAL CHECK(input_price_per_million IS NULL OR input_price_per_million >= 0),
            output_price_per_million REAL CHECK(output_price_per_million IS NULL OR output_price_per_million >= 0),
            reasoning_price_per_million REAL CHECK(reasoning_price_per_million IS NULL OR reasoning_price_per_million >= 0),
            cache_read_price_per_million REAL CHECK(cache_read_price_per_million IS NULL OR cache_read_price_per_million >= 0),
            cache_write_5m_price_per_million REAL CHECK(cache_write_5m_price_per_million IS NULL OR cache_write_5m_price_per_million >= 0),
            cache_write_1h_price_per_million REAL CHECK(cache_write_1h_price_per_million IS NULL OR cache_write_1h_price_per_million >= 0),
            long_context_input_price_per_million REAL CHECK(long_context_input_price_per_million IS NULL OR long_context_input_price_per_million >= 0),
            long_context_output_price_per_million REAL CHECK(long_context_output_price_per_million IS NULL OR long_context_output_price_per_million >= 0),
            long_context_threshold_tokens INTEGER CHECK(long_context_threshold_tokens IS NULL OR long_context_threshold_tokens >= 0),
            pricing_captured_at REAL,
            cost_reported_requests INTEGER CHECK(
                cost_reported_requests IS NULL OR
                (cost_reported_requests >= 0 AND cost_reported_requests <= request_count)
            ),

            quota_provenance TEXT,
            quota_observed_at REAL,
            quota_requests_remaining INTEGER CHECK(quota_requests_remaining IS NULL OR quota_requests_remaining >= 0),
            quota_requests_limit INTEGER CHECK(quota_requests_limit IS NULL OR quota_requests_limit >= 0),
            quota_tokens_remaining INTEGER CHECK(quota_tokens_remaining IS NULL OR quota_tokens_remaining >= 0),
            quota_tokens_limit INTEGER CHECK(quota_tokens_limit IS NULL OR quota_tokens_limit >= 0),
            quota_reset_at REAL,

            source TEXT NOT NULL,
            source_id TEXT
        );

        CREATE INDEX IF NOT EXISTS usage_records_date
            ON usage_records(occurred_at);
        CREATE INDEX IF NOT EXISTS usage_records_provider_date
            ON usage_records(provider_id, occurred_at);
        CREATE INDEX IF NOT EXISTS usage_records_model_date
            ON usage_records(effective_model_id, occurred_at);
        CREATE INDEX IF NOT EXISTS usage_records_purpose_date
            ON usage_records(purpose, occurred_at);
        CREATE UNIQUE INDEX IF NOT EXISTS usage_records_source_id
            ON usage_records(source, source_id)
            WHERE source_id IS NOT NULL;
        CREATE UNIQUE INDEX IF NOT EXISTS usage_records_legacy_bucket
            ON usage_records(provider_id, occurred_at, source)
            WHERE source = 'legacy_aggregate';

        CREATE TABLE IF NOT EXISTS usage_migrations (
            identifier TEXT PRIMARY KEY NOT NULL,
            completed_at REAL NOT NULL
        );

        PRAGMA user_version = 1;
        """)
    }

    // MARK: - Recording

    @discardableResult
    public func record(_ usage: RequestUsage) throws -> UsageInsertResult {
        try ensureOpen()
        try validate(usage)
        return try insert(usage)
    }

    /// Inserts a batch atomically. Duplicate IDs/source IDs are harmless and
    /// counted separately from newly inserted rows.
    public func record(_ usages: [RequestUsage]) throws -> (inserted: Int, duplicates: Int) {
        try ensureOpen()
        for usage in usages { try validate(usage) }
        guard !usages.isEmpty else { return (0, 0) }

        try execute("BEGIN IMMEDIATE;")
        do {
            var inserted = 0
            var duplicates = 0
            for usage in usages {
                switch try insert(usage) {
                case .inserted: inserted += 1
                case .duplicate: duplicates += 1
                }
            }
            try execute("COMMIT;")
            return (inserted, duplicates)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Clears user-visible history but deliberately retains completed migration
    /// markers. Otherwise “Clear Usage History” could re-import old defaults on
    /// the next launch if cleanup of the legacy key was delayed or interrupted.
    public func clear() throws {
        try ensureOpen()
        try execute("DELETE FROM usage_records;")
    }

    public func count() throws -> Int {
        try ensureOpen()
        let statement = try prepare("SELECT COUNT(*) FROM usage_records;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Legacy migration

    /// Atomically imports the old hourly buckets and message-derived usage.
    ///
    /// For each provider, messages inside the inclusive span covered by its old
    /// hourly buckets are skipped; importing both would double count them.
    /// Messages outside that span are keyed by message ID and therefore safe to
    /// retry. The migration marker is committed in the same transaction as the
    /// rows. A returned `.applied` is the caller's signal that it may now remove
    /// the legacy `UserDefaults` value.
    public func migrateLegacy(
        identifier: String,
        aggregates: [LegacyUsageAggregate],
        messageBackfill: [MessageUsageBackfill]
    ) throws -> UsageMigrationResult {
        try ensureOpen()
        guard !identifier.isEmpty, identifier.utf8.count <= 256 else {
            throw UsageLedgerError.invalidRecord("migration identifier must contain 1...256 UTF-8 bytes")
        }
        if try migrationCompleted(identifier) {
            return UsageMigrationResult(status: .alreadyApplied)
        }

        var converted: [(record: RequestUsage, hour: Date)] = []
        converted.reserveCapacity(aggregates.count)
        var ranges: [UUID: (start: Date, end: Date)] = [:]

        for aggregate in aggregates {
            let hour = Self.startOfUnixHour(aggregate.hourStartingAt)
            let usageReporting = aggregate.usageReportedRequests
                .map { UsageReportingEvidence.exact(reportedRequests: $0) } ?? .indeterminate
            let costReporting = aggregate.costReportedRequests
                .map { UsageReportingEvidence.exact(reportedRequests: $0) } ?? .indeterminate
            let record = RequestUsage(
                id: aggregate.id,
                occurredAt: hour,
                providerID: aggregate.providerID,
                purpose: .legacyAggregate,
                outcome: .unknown,
                inputTokens: aggregate.inputTokens,
                outputTokens: aggregate.outputTokens,
                metricProvenance: .legacyAggregate,
                cost: aggregate.cost,
                requestCount: aggregate.requestCount,
                usageReporting: usageReporting,
                costReporting: costReporting,
                source: .legacyAggregate
            )
            try validate(record)
            converted.append((record, hour))

            let end = hour.addingTimeInterval(3_600)
            if let current = ranges[aggregate.providerID] {
                ranges[aggregate.providerID] = (min(current.start, hour), max(current.end, end))
            } else {
                ranges[aggregate.providerID] = (hour, end)
            }
        }

        var preparedBackfill: [RequestUsage] = []
        var skippedInsideRange = 0
        for item in messageBackfill {
            var usage = item.usage
            if let providerID = usage.providerID,
               let range = ranges[providerID],
               usage.occurredAt >= range.start, usage.occurredAt < range.end {
                skippedInsideRange += 1
                continue
            }
            guard usage.requestCount == 1 else {
                throw UsageLedgerError.invalidRecord("message backfill rows must represent exactly one request")
            }
            usage.source = .messageBackfill
            usage.sourceID = item.messageID
            if usage.metricProvenance == nil,
               usage.inputTokens != nil || usage.outputTokens != nil || usage.reasoningTokens != nil {
                usage.metricProvenance = .persistedMessage
            }
            try validate(usage)
            preparedBackfill.append(usage)
        }

        try execute("BEGIN IMMEDIATE;")
        do {
            // Another process may have completed it between our first check and
            // BEGIN IMMEDIATE. Rechecking under the write lock keeps this exact.
            if try migrationCompleted(identifier) {
                try execute("ROLLBACK;")
                return UsageMigrationResult(status: .alreadyApplied)
            }

            var imported = 0
            var backfilled = 0
            var duplicates = 0
            for item in converted {
                switch try insert(item.record) {
                case .inserted: imported += 1
                case .duplicate: duplicates += 1
                }
            }
            for usage in preparedBackfill {
                switch try insert(usage) {
                case .inserted: backfilled += 1
                case .duplicate: duplicates += 1
                }
            }

            let marker = try prepare("INSERT INTO usage_migrations(identifier, completed_at) VALUES (?, ?);")
            defer { sqlite3_finalize(marker) }
            try bindText(marker, 1, identifier)
            try bindDouble(marker, 2, Date().timeIntervalSince1970)
            guard sqlite3_step(marker) == SQLITE_DONE else { throw databaseError() }
            try execute("COMMIT;")

            return UsageMigrationResult(
                status: .applied,
                importedLegacyRows: imported,
                backfilledMessages: backfilled,
                skippedMessagesInsideLegacyRange: skippedInsideRange,
                duplicateRows: duplicates
            )
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func hasCompletedMigration(_ identifier: String) throws -> Bool {
        try ensureOpen()
        return try migrationCompleted(identifier)
    }

    private func migrationCompleted(_ identifier: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM usage_migrations WHERE identifier = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, identifier)
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw databaseError()
    }

    // MARK: - Queries

    /// Builds the complete data model for Usage & Limits in one streaming pass
    /// over the selected rows. Only the small `recent` tail is retained; all
    /// aggregates and breakdowns are accumulated as SQLite steps are read.
    public func query(_ query: UsageQuery, calendar: Calendar = .current) throws -> UsageReport {
        try ensureOpen()
        let startDate = query.period.startDate(endingAt: query.endingAt, calendar: calendar)
        var clauses = ["occurred_at <= ?"]
        var bindings: [SQLValue] = [.double(query.endingAt.timeIntervalSince1970)]
        if let startDate {
            clauses.append("occurred_at >= ?")
            bindings.append(.double(startDate.timeIntervalSince1970))
        }
        if let providerID = query.providerID {
            clauses.append("provider_id = ?")
            bindings.append(.text(providerID.uuidString))
        }
        if let effectiveModelID = query.effectiveModelID {
            clauses.append("effective_model_id = ?")
            bindings.append(.text(effectiveModelID))
        }
        if let purpose = query.purpose {
            clauses.append("purpose = ?")
            bindings.append(.text(purpose.rawValue))
        }

        let statement = try prepare("""
        SELECT \(Self.selectedColumns)
        FROM usage_records
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY occurred_at ASC, id ASC;
        """)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            try bind(value, to: statement, at: Int32(offset + 1))
        }

        var total = UsageAccumulator()
        var days: [Date: UsageAccumulator] = [:]
        var providers: [BreakdownKey: UsageAccumulator] = [:]
        var models: [BreakdownKey: UsageAccumulator] = [:]
        var purposes: [BreakdownKey: UsageAccumulator] = [:]
        let recentLimit = min(500, max(0, query.recentLimit))
        var recent: [RequestUsage] = []

        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError() }
            let usage = try decodeRecord(statement)
            total.add(usage)
            days[calendar.startOfDay(for: usage.occurredAt), default: UsageAccumulator()].add(usage)
            providers[BreakdownKey(usage.providerID?.uuidString), default: UsageAccumulator()].add(usage)
            models[BreakdownKey(usage.effectiveModelID), default: UsageAccumulator()].add(usage)
            purposes[BreakdownKey(usage.purpose.rawValue), default: UsageAccumulator()].add(usage)

            if recentLimit > 0 {
                recent.append(usage)
                if recent.count > recentLimit { recent.removeFirst() }
            }
        }

        return UsageReport(
            query: query,
            startDate: startDate,
            aggregate: total.value,
            trend: days
                .map { UsageTrendPoint(day: $0.key, aggregate: $0.value.value) }
                .sorted { $0.day < $1.day },
            providers: Self.breakdowns(providers, dimension: .provider),
            models: Self.breakdowns(models, dimension: .model),
            purposes: Self.breakdowns(purposes, dimension: .purpose),
            recent: recent.reversed()
        )
    }

    /// Most recent numeric quota observation for a provider, independent of
    /// the currently selected usage period.
    public func latestQuota(providerID: UUID) throws -> UsageQuotaEvidence? {
        try ensureOpen()
        let statement = try prepare("""
        SELECT \(Self.selectedColumns)
        FROM usage_records
        WHERE provider_id = ? AND quota_provenance IS NOT NULL
        ORDER BY occurred_at DESC, id DESC
        LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, providerID.uuidString)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw databaseError() }
        return try decodeRecord(statement).quota
    }

    // MARK: - Validation

    private func validate(_ usage: RequestUsage) throws {
        guard usage.occurredAt.timeIntervalSince1970.isFinite else {
            throw UsageLedgerError.invalidRecord("occurredAt must be finite")
        }
        guard usage.requestCount > 0 else {
            throw UsageLedgerError.invalidRecord("requestCount must be positive")
        }
        if usage.source != .legacyAggregate, usage.requestCount != 1 {
            throw UsageLedgerError.invalidRecord("only legacy aggregates may represent multiple requests")
        }
        if usage.source == .legacyAggregate, usage.purpose != .legacyAggregate {
            throw UsageLedgerError.invalidRecord("legacy aggregate rows must use the legacyAggregate purpose")
        }
        if usage.source == .messageBackfill, usage.sourceID == nil {
            throw UsageLedgerError.invalidRecord("message backfill rows require a message source ID")
        }
        for model in [usage.requestedModelID, usage.effectiveModelID].compactMap({ $0 }) {
            guard !model.isEmpty, model.utf8.count <= 1_024 else {
                throw UsageLedgerError.invalidRecord("model identifiers must contain 1...1024 UTF-8 bytes")
            }
        }

        let tokenValues = [
            usage.inputTokens, usage.outputTokens, usage.reasoningTokens,
            usage.cacheReadTokens, usage.cacheWrite5mTokens, usage.cacheWrite1hTokens,
            usage.latencyMilliseconds,
        ]
        guard tokenValues.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw UsageLedgerError.invalidRecord("token counts and latency cannot be negative")
        }
        try validateReporting(usage.usageReporting, requestCount: usage.requestCount, label: "usage")
        try validateReporting(usage.costReporting, requestCount: usage.requestCount, label: "cost")

        let hasUsage = [
            usage.inputTokens, usage.outputTokens, usage.reasoningTokens,
            usage.cacheReadTokens, usage.cacheWrite5mTokens, usage.cacheWrite1hTokens,
        ].contains { $0 != nil }
        if case .exact(let reported) = usage.usageReporting, hasUsage != (reported > 0) {
            throw UsageLedgerError.invalidRecord("usage reporting count conflicts with the stored token metrics")
        }
        if case .exact(let reported) = usage.costReporting, (usage.cost != nil) != (reported > 0) {
            throw UsageLedgerError.invalidRecord("cost reporting count conflicts with the stored cost")
        }

        if let provenance = usage.metricProvenance, !hasUsage, provenance != .legacyAggregate {
            throw UsageLedgerError.invalidRecord("metric provenance requires at least one token metric")
        }
        if let cost = usage.cost {
            try validateFiniteNonnegative(cost.amountUSD, label: "cost")
            for (value, label) in [
                (cost.inputPerMillion, "input price"),
                (cost.outputPerMillion, "output price"),
                (cost.reasoningPerMillion, "reasoning price"),
                (cost.cacheReadPerMillion, "cache read price"),
                (cost.cacheWrite5mPerMillion, "5-minute cache write price"),
                (cost.cacheWrite1hPerMillion, "1-hour cache write price"),
                (cost.longContextInputPerMillion, "long-context input price"),
                (cost.longContextOutputPerMillion, "long-context output price"),
            ] {
                if let value { try validateFiniteNonnegative(value, label: label) }
            }
            if let threshold = cost.longContextThresholdTokens, threshold < 0 {
                throw UsageLedgerError.invalidRecord("long-context threshold cannot be negative")
            }
            if let captured = cost.pricingCapturedAt, !captured.timeIntervalSince1970.isFinite {
                throw UsageLedgerError.invalidRecord("pricing capture date must be finite")
            }
        }
        if let quota = usage.quota {
            guard quota.observedAt.timeIntervalSince1970.isFinite,
                  quota.resetAt?.timeIntervalSince1970.isFinite != false else {
                throw UsageLedgerError.invalidRecord("quota dates must be finite")
            }
            let values = [quota.requestsRemaining, quota.requestsLimit, quota.tokensRemaining, quota.tokensLimit]
            guard values.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
                throw UsageLedgerError.invalidRecord("quota counts cannot be negative")
            }
        }
    }

    private func validateReporting(
        _ evidence: UsageReportingEvidence,
        requestCount: Int,
        label: String
    ) throws {
        if case .exact(let value) = evidence, !(0...requestCount).contains(value) {
            throw UsageLedgerError.invalidRecord("\(label) reporting count must be between zero and requestCount")
        }
    }

    private func validateFiniteNonnegative(_ value: Double, label: String) throws {
        guard value.isFinite, value >= 0 else {
            throw UsageLedgerError.invalidRecord("\(label) must be finite and nonnegative")
        }
    }

    // MARK: - SQLite record mapping

    private static let selectedColumns = """
    id, occurred_at, provider_id, requested_model_id, effective_model_id,
    purpose, outcome, request_count,
    input_tokens, output_tokens, reasoning_tokens, cache_read_tokens,
    cache_write_5m_tokens, cache_write_1h_tokens, latency_ms,
    metric_provenance, usage_reported_requests,
    cost_usd, cost_provenance, input_price_per_million,
    output_price_per_million, reasoning_price_per_million,
    cache_read_price_per_million, cache_write_5m_price_per_million,
    cache_write_1h_price_per_million, long_context_input_price_per_million,
    long_context_output_price_per_million, long_context_threshold_tokens,
    pricing_captured_at, cost_reported_requests,
    quota_provenance, quota_observed_at, quota_requests_remaining,
    quota_requests_limit, quota_tokens_remaining, quota_tokens_limit,
    quota_reset_at, source, source_id
    """

    private static let insertSQL = """
    INSERT INTO usage_records (\(selectedColumns))
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT DO NOTHING;
    """

    private func insert(_ usage: RequestUsage) throws -> UsageInsertResult {
        let statement = try prepare(Self.insertSQL)
        defer { sqlite3_finalize(statement) }

        let cost = usage.cost
        let quota = usage.quota
        let values: [SQLValue] = [
            .text(usage.id.uuidString),
            .double(usage.occurredAt.timeIntervalSince1970),
            usage.providerID.map { .text($0.uuidString) } ?? .null,
            usage.requestedModelID.map(SQLValue.text) ?? .null,
            usage.effectiveModelID.map(SQLValue.text) ?? .null,
            .text(usage.purpose.rawValue),
            .text(usage.outcome.rawValue),
            .integer(usage.requestCount),
            usage.inputTokens.map(SQLValue.integer) ?? .null,
            usage.outputTokens.map(SQLValue.integer) ?? .null,
            usage.reasoningTokens.map(SQLValue.integer) ?? .null,
            usage.cacheReadTokens.map(SQLValue.integer) ?? .null,
            usage.cacheWrite5mTokens.map(SQLValue.integer) ?? .null,
            usage.cacheWrite1hTokens.map(SQLValue.integer) ?? .null,
            usage.latencyMilliseconds.map(SQLValue.integer) ?? .null,
            usage.metricProvenance.map { .text($0.rawValue) } ?? .null,
            usage.usageReporting.reportedRequests.map(SQLValue.integer) ?? .null,
            cost.map { .double($0.amountUSD) } ?? .null,
            cost.map { .text($0.provenance.rawValue) } ?? .null,
            cost?.inputPerMillion.map(SQLValue.double) ?? .null,
            cost?.outputPerMillion.map(SQLValue.double) ?? .null,
            cost?.reasoningPerMillion.map(SQLValue.double) ?? .null,
            cost?.cacheReadPerMillion.map(SQLValue.double) ?? .null,
            cost?.cacheWrite5mPerMillion.map(SQLValue.double) ?? .null,
            cost?.cacheWrite1hPerMillion.map(SQLValue.double) ?? .null,
            cost?.longContextInputPerMillion.map(SQLValue.double) ?? .null,
            cost?.longContextOutputPerMillion.map(SQLValue.double) ?? .null,
            cost?.longContextThresholdTokens.map(SQLValue.integer) ?? .null,
            cost?.pricingCapturedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            usage.costReporting.reportedRequests.map(SQLValue.integer) ?? .null,
            quota.map { .text($0.provenance.rawValue) } ?? .null,
            quota.map { .double($0.observedAt.timeIntervalSince1970) } ?? .null,
            quota?.requestsRemaining.map(SQLValue.integer) ?? .null,
            quota?.requestsLimit.map(SQLValue.integer) ?? .null,
            quota?.tokensRemaining.map(SQLValue.integer) ?? .null,
            quota?.tokensLimit.map(SQLValue.integer) ?? .null,
            quota?.resetAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .text(usage.source.rawValue),
            usage.sourceID.map { .text($0.uuidString) } ?? .null,
        ]
        precondition(values.count == 39)
        for (offset, value) in values.enumerated() {
            try bind(value, to: statement, at: Int32(offset + 1))
        }

        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        guard let database else { throw UsageLedgerError.database("connection closed during insert") }
        return sqlite3_changes(database) == 0 ? .duplicate : .inserted
    }

    private func decodeRecord(_ statement: OpaquePointer?) throws -> RequestUsage {
        guard let idString = text(statement, 0), let id = UUID(uuidString: idString) else {
            throw UsageLedgerError.corruptRecord("invalid request ID")
        }
        guard let purposeRaw = text(statement, 5), let purpose = UsagePurpose(rawValue: purposeRaw) else {
            throw UsageLedgerError.corruptRecord("invalid usage purpose")
        }
        guard let outcomeRaw = text(statement, 6), let outcome = UsageOutcome(rawValue: outcomeRaw) else {
            throw UsageLedgerError.corruptRecord("invalid request outcome")
        }
        guard let sourceRaw = text(statement, 37), let source = UsageRecordSource(rawValue: sourceRaw) else {
            throw UsageLedgerError.corruptRecord("invalid record source")
        }

        let metricProvenance: UsageMetricProvenance?
        if let raw = text(statement, 15) {
            guard let value = UsageMetricProvenance(rawValue: raw) else {
                throw UsageLedgerError.corruptRecord("invalid metric provenance")
            }
            metricProvenance = value
        } else {
            metricProvenance = nil
        }

        let cost: CostEvidence?
        if let amount = optionalDouble(statement, 17) {
            guard let raw = text(statement, 18), let provenance = CostProvenance(rawValue: raw) else {
                throw UsageLedgerError.corruptRecord("cost amount has no valid provenance")
            }
            cost = CostEvidence(
                amountUSD: amount,
                provenance: provenance,
                inputPerMillion: optionalDouble(statement, 19),
                outputPerMillion: optionalDouble(statement, 20),
                reasoningPerMillion: optionalDouble(statement, 21),
                cacheReadPerMillion: optionalDouble(statement, 22),
                cacheWrite5mPerMillion: optionalDouble(statement, 23),
                cacheWrite1hPerMillion: optionalDouble(statement, 24),
                longContextInputPerMillion: optionalDouble(statement, 25),
                longContextOutputPerMillion: optionalDouble(statement, 26),
                longContextThresholdTokens: optionalInt(statement, 27),
                pricingCapturedAt: optionalDate(statement, 28)
            )
        } else {
            cost = nil
        }

        let quota: UsageQuotaEvidence?
        if let raw = text(statement, 30) {
            guard let provenance = UsageQuotaEvidence.Provenance(rawValue: raw),
                  let observedAt = optionalDate(statement, 31) else {
                throw UsageLedgerError.corruptRecord("quota evidence is incomplete")
            }
            quota = UsageQuotaEvidence(
                provenance: provenance,
                observedAt: observedAt,
                requestsRemaining: optionalInt(statement, 32),
                requestsLimit: optionalInt(statement, 33),
                tokensRemaining: optionalInt(statement, 34),
                tokensLimit: optionalInt(statement, 35),
                resetAt: optionalDate(statement, 36)
            )
        } else {
            quota = nil
        }

        let providerID: UUID?
        if let raw = text(statement, 2) {
            guard let value = UUID(uuidString: raw) else {
                throw UsageLedgerError.corruptRecord("invalid provider ID")
            }
            providerID = value
        } else {
            providerID = nil
        }
        let sourceID: UUID?
        if let raw = text(statement, 38) {
            guard let value = UUID(uuidString: raw) else {
                throw UsageLedgerError.corruptRecord("invalid source ID")
            }
            sourceID = value
        } else {
            sourceID = nil
        }

        let requestCount = Int(sqlite3_column_int64(statement, 7))
        let usageReporting = optionalInt(statement, 16)
            .map { UsageReportingEvidence.exact(reportedRequests: $0) } ?? .indeterminate
        let costReporting = optionalInt(statement, 29)
            .map { UsageReportingEvidence.exact(reportedRequests: $0) } ?? .indeterminate
        let usage = RequestUsage(
            id: id,
            occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            providerID: providerID,
            requestedModelID: text(statement, 3),
            effectiveModelID: text(statement, 4),
            purpose: purpose,
            outcome: outcome,
            inputTokens: optionalInt(statement, 8),
            outputTokens: optionalInt(statement, 9),
            reasoningTokens: optionalInt(statement, 10),
            cacheReadTokens: optionalInt(statement, 11),
            cacheWrite5mTokens: optionalInt(statement, 12),
            cacheWrite1hTokens: optionalInt(statement, 13),
            latencyMilliseconds: optionalInt(statement, 14),
            metricProvenance: metricProvenance,
            cost: cost,
            quota: quota,
            requestCount: requestCount,
            usageReporting: usageReporting,
            costReporting: costReporting,
            source: source,
            sourceID: sourceID
        )
        try validate(usage)
        return usage
    }

    // MARK: - SQLite plumbing

    private enum SQLValue {
        case null
        case integer(Int)
        case double(Double)
        case text(String)
    }

    private func ensureOpen() throws {
        if database == nil { try open() }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw UsageLedgerError.database("connection is closed") }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw UsageLedgerError.database(detail)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let database else { throw UsageLedgerError.database("connection is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError()
        }
        return statement
    }

    private func bind(_ value: SQLValue, to statement: OpaquePointer?, at index: Int32) throws {
        let status: Int32
        switch value {
        case .null:
            status = sqlite3_bind_null(statement, index)
        case .integer(let value):
            status = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case .double(let value):
            status = sqlite3_bind_double(statement, index, value)
        case .text(let value):
            status = sqlite3_bind_text(
                statement,
                index,
                value,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard status == SQLITE_OK else { throw databaseError() }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) throws {
        try bind(.text(value), to: statement, at: index)
    }

    private func bindDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double) throws {
        try bind(.double(value), to: statement, at: index)
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func optionalInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func optionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func optionalDate(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
        optionalDouble(statement, index).map(Date.init(timeIntervalSince1970:))
    }

    private func databaseError() -> UsageLedgerError {
        guard let database else { return .database("connection is closed") }
        return .database(String(cString: sqlite3_errmsg(database)))
    }

    private static func startOfUnixHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3_600) * 3_600)
    }

    private struct BreakdownKey: Hashable {
        var value: String?
        init(_ value: String?) { self.value = value }
    }

    private static func breakdowns(
        _ values: [BreakdownKey: UsageAccumulator],
        dimension: UsageBreakdownDimension
    ) -> [UsageBreakdown] {
        values.map { UsageBreakdown(dimension: dimension, key: $0.key.value, aggregate: $0.value.value) }
            .sorted {
                if $0.aggregate.requestCount != $1.aggregate.requestCount {
                    return $0.aggregate.requestCount > $1.aggregate.requestCount
                }
                return ($0.key ?? "") < ($1.key ?? "")
            }
    }
}

// MARK: - Aggregate math

private struct UsageAccumulator {
    var value = UsageAggregate()

    mutating func add(_ usage: RequestUsage) {
        value.recordCount += 1
        value.requestCount += usage.requestCount
        if usage.purpose == .chat { value.turnCount += usage.requestCount }
        switch usage.outcome {
        case .succeeded: value.succeededRequests += usage.requestCount
        case .failed: value.failedRequests += usage.requestCount
        case .cancelled: value.cancelledRequests += usage.requestCount
        case .refused: value.refusedRequests += usage.requestCount
        case .unknown: value.unknownOutcomeRequests += usage.requestCount
        }

        addMetric(usage.inputTokens, reporting: usage.usageReporting, requests: usage.requestCount, to: &value.inputTokens)
        addMetric(usage.outputTokens, reporting: usage.usageReporting, requests: usage.requestCount, to: &value.outputTokens)
        addMetric(usage.reasoningTokens, reporting: usage.usageReporting, requests: usage.requestCount, to: &value.reasoningTokens)
        addMetric(usage.cacheReadTokens, reporting: usage.usageReporting, requests: usage.requestCount, to: &value.cacheReadTokens)
        addMetric(usage.cacheWrite5mTokens, reporting: usage.usageReporting, requests: usage.requestCount, to: &value.cacheWrite5mTokens)
        addMetric(usage.cacheWrite1hTokens, reporting: usage.usageReporting, requests: usage.requestCount, to: &value.cacheWrite1hTokens)
        addCoverage(usage.usageReporting, requests: usage.requestCount, to: &value.usageReporting)

        if let cost = usage.cost {
            value.cost.amountUSD = (value.cost.amountUSD ?? 0) + cost.amountUSD
            let priced = usage.costReporting.reportedRequests ?? usage.requestCount
            switch cost.provenance {
            case .providerReported: value.cost.providerReportedRequests += priced
            case .publishedPricingSnapshot: value.cost.pricingSnapshotRequests += priced
            case .legacyAggregate: value.cost.legacyAggregateRequests += priced
            }
        }
        addCoverage(usage.costReporting, requests: usage.requestCount, to: &value.cost.coverage)

        if let latency = usage.latencyMilliseconds {
            value.totalLatencyMilliseconds += latency
            value.latencyReportedRequests += usage.requestCount
        }
    }

    private func addMetric(
        _ metric: Int?,
        reporting: UsageReportingEvidence,
        requests: Int,
        to total: inout UsageTokenTotal
    ) {
        if let metric { total.value = (total.value ?? 0) + metric }
        switch reporting {
        case .exact(let reported) where metric != nil:
            total.coverage.reportedRequests += reported
            total.coverage.unreportedRequests += requests - reported
        case .exact:
            total.coverage.unreportedRequests += requests
        case .indeterminate:
            total.coverage.indeterminateRequests += requests
        }
    }

    private func addCoverage(
        _ reporting: UsageReportingEvidence,
        requests: Int,
        to coverage: inout UsageReportingCoverage
    ) {
        switch reporting {
        case .exact(let reported):
            coverage.reportedRequests += reported
            coverage.unreportedRequests += requests - reported
        case .indeterminate:
            coverage.indeterminateRequests += requests
        }
    }
}
