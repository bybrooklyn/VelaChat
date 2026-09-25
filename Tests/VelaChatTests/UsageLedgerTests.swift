import XCTest
import SQLite3
@testable import VelaCore

final class UsageLedgerTests: XCTestCase {
    private func makeLedger() -> (UsageLedger, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velachat-usage-ledger-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("usage.sqlite")
        return (UsageLedger(databaseURL: url), directory)
    }

    private func cleanup(_ ledger: UsageLedger, directory: URL) async {
        await ledger.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testUnknownAndReportedZeroStayDistinctAndIDsDedupe() async throws {
        let (ledger, directory) = makeLedger()
        let provider = UUID()
        let unknown = RequestUsage(
            occurredAt: Date(timeIntervalSince1970: 1_000),
            providerID: provider,
            effectiveModelID: "unknown-usage-model",
            purpose: .chat,
            outcome: .failed
        )
        let zero = RequestUsage(
            occurredAt: Date(timeIntervalSince1970: 2_000),
            providerID: provider,
            effectiveModelID: "zero-usage-model",
            purpose: .toolRound,
            outcome: .succeeded,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            metricProvenance: .providerReported,
            cost: .providerReported(0)
        )

        let unknownInsert = try await ledger.record(unknown)
        let zeroInsert = try await ledger.record(zero)
        let duplicateInsert = try await ledger.record(zero)
        let rowCount = try await ledger.count()
        XCTAssertEqual(unknownInsert, .inserted)
        XCTAssertEqual(zeroInsert, .inserted)
        XCTAssertEqual(duplicateInsert, .duplicate)
        XCTAssertEqual(rowCount, 2)

        let report = try await ledger.query(
            UsageQuery(period: .allTime, endingAt: Date(timeIntervalSince1970: 3_000))
        )
        XCTAssertEqual(report.aggregate.requestCount, 2)
        XCTAssertEqual(report.aggregate.inputTokens.value, 0)
        XCTAssertEqual(report.aggregate.inputTokens.coverage.reportedRequests, 1)
        XCTAssertEqual(report.aggregate.inputTokens.coverage.unreportedRequests, 1)
        XCTAssertEqual(report.aggregate.usageReporting.reportedRequests, 1)
        XCTAssertEqual(report.aggregate.usageReporting.unreportedRequests, 1)
        XCTAssertEqual(report.aggregate.cost.amountUSD, 0)
        XCTAssertEqual(report.aggregate.cost.coverage.reportedRequests, 1)
        XCTAssertEqual(report.aggregate.cost.coverage.unreportedRequests, 1)
        XCTAssertEqual(report.aggregate.cost.providerReportedRequests, 1)
        XCTAssertEqual(report.recent.map(\.id), [zero.id, unknown.id])
        XCTAssertEqual(report.recent[0].inputTokens, 0)
        XCTAssertNil(report.recent[1].inputTokens)
        XCTAssertEqual(report.recent[0].cost?.amountUSD, 0)
        XCTAssertNil(report.recent[1].cost)

        await cleanup(ledger, directory: directory)
    }

    func testPeriodsFiltersBreakdownsTrendAndRecentOrdering() async throws {
        let (ledger, directory) = makeLedger()
        let calendar = utcCalendar()
        let end = Date(timeIntervalSince1970: 1_777_200_000) // 2026-04-27T12:00:00Z
        let providerA = UUID()
        let providerB = UUID()

        func usage(daysAgo: Int, provider: UUID, model: String, purpose: UsagePurpose, tokens: Int) -> RequestUsage {
            RequestUsage(
                occurredAt: calendar.date(byAdding: .day, value: -daysAgo, to: end)!,
                providerID: provider,
                effectiveModelID: model,
                purpose: purpose,
                outcome: .succeeded,
                inputTokens: tokens,
                outputTokens: 1,
                metricProvenance: .providerReported
            )
        }

        let today = usage(daysAgo: 0, provider: providerA, model: "model-a", purpose: .chat, tokens: 10)
        let threeDays = usage(daysAgo: 3, provider: providerA, model: "model-a", purpose: .toolRound, tokens: 20)
        let tenDays = usage(daysAgo: 10, provider: providerB, model: "model-b", purpose: .chat, tokens: 30)
        let fortyDays = usage(daysAgo: 40, provider: providerB, model: "model-b", purpose: .compaction, tokens: 40)
        let batch = try await ledger.record([today, threeDays, tenDays, fortyDays])
        XCTAssertEqual(batch.inserted, 4)
        XCTAssertEqual(batch.duplicates, 0)

        let todayReport = try await ledger.query(UsageQuery(period: .today, endingAt: end), calendar: calendar)
        let weekReport = try await ledger.query(UsageQuery(period: .sevenDays, endingAt: end), calendar: calendar)
        let monthReport = try await ledger.query(UsageQuery(period: .thirtyDays, endingAt: end), calendar: calendar)
        let allReport = try await ledger.query(UsageQuery(period: .allTime, endingAt: end), calendar: calendar)
        XCTAssertEqual(todayReport.aggregate.requestCount, 1)
        XCTAssertEqual(weekReport.aggregate.requestCount, 2)
        XCTAssertEqual(monthReport.aggregate.requestCount, 3)
        XCTAssertEqual(allReport.aggregate.requestCount, 4)
        XCTAssertEqual(allReport.aggregate.turnCount, 2)
        XCTAssertEqual(allReport.trend.count, 4)
        XCTAssertEqual(allReport.recent.map(\.id), [today.id, threeDays.id, tenDays.id, fortyDays.id])

        XCTAssertEqual(allReport.providers.count, 2)
        XCTAssertEqual(allReport.providers.first?.aggregate.requestCount, 2)
        XCTAssertEqual(allReport.models.map(\.key), ["model-a", "model-b"])
        XCTAssertEqual(Set(allReport.purposes.compactMap(\.key)), Set(["chat", "tool_round", "compaction"]))

        let filtered = try await ledger.query(
            UsageQuery(period: .allTime, endingAt: end, providerID: providerA, purpose: .toolRound),
            calendar: calendar
        )
        XCTAssertEqual(filtered.aggregate.requestCount, 1)
        XCTAssertEqual(filtered.aggregate.inputTokens.value, 20)
        XCTAssertEqual(filtered.recent.first?.id, threeDays.id)

        await cleanup(ledger, directory: directory)
    }

    func testLegacyMigrationIsAtomicRangeAwareAndIdempotent() async throws {
        let (ledger, directory) = makeLedger()
        let providerA = UUID()
        let providerB = UUID()
        let baseHour = Date(timeIntervalSince1970: 1_800_000_000)
        let aggregateA = LegacyUsageAggregate(
            providerID: providerA,
            hourStartingAt: baseHour,
            requestCount: 3,
            inputTokens: 300,
            outputTokens: 30,
            cost: CostEvidence(amountUSD: 0.30, provenance: .legacyAggregate),
            usageReportedRequests: nil,
            costReportedRequests: 2
        )
        let aggregateB = LegacyUsageAggregate(
            providerID: providerA,
            hourStartingAt: baseHour.addingTimeInterval(2 * 3_600),
            requestCount: 4,
            inputTokens: 400,
            outputTokens: 40
        )

        func backfill(provider: UUID, at date: Date, input: Int) -> MessageUsageBackfill {
            let messageID = UUID()
            return MessageUsageBackfill(
                messageID: messageID,
                usage: RequestUsage(
                    occurredAt: date,
                    providerID: provider,
                    effectiveModelID: "backfilled-model",
                    purpose: .chat,
                    outcome: .succeeded,
                    inputTokens: input,
                    outputTokens: 1,
                    metricProvenance: .persistedMessage
                )
            )
        }

        // Inside provider A's min...max bucket span (including the empty hour),
        // so this message must not duplicate the old aggregates.
        let inside = backfill(provider: providerA, at: baseHour.addingTimeInterval(3_600 + 10), input: 999)
        let before = backfill(provider: providerA, at: baseHour.addingTimeInterval(-10), input: 10)
        let otherProvider = backfill(provider: providerB, at: baseHour.addingTimeInterval(10), input: 20)

        let result = try await ledger.migrateLegacy(
            identifier: "usage-ledger-v1-test",
            aggregates: [aggregateA, aggregateB],
            messageBackfill: [inside, before, otherProvider]
        )
        XCTAssertEqual(result.status, .applied)
        XCTAssertTrue(result.mayClearLegacySource)
        XCTAssertEqual(result.importedLegacyRows, 2)
        XCTAssertEqual(result.backfilledMessages, 2)
        XCTAssertEqual(result.skippedMessagesInsideLegacyRange, 1)
        XCTAssertEqual(result.duplicateRows, 0)
        let migratedRowCount = try await ledger.count()
        XCTAssertEqual(migratedRowCount, 4)

        let report = try await ledger.query(
            UsageQuery(period: .allTime, endingAt: baseHour.addingTimeInterval(4 * 3_600))
        )
        XCTAssertEqual(report.aggregate.requestCount, 9)
        XCTAssertEqual(report.aggregate.inputTokens.value, 730)
        XCTAssertEqual(report.aggregate.usageReporting.reportedRequests, 2)
        XCTAssertEqual(report.aggregate.usageReporting.indeterminateRequests, 7)
        XCTAssertNil(report.aggregate.usageReporting.exactFraction)
        XCTAssertEqual(
            try XCTUnwrap(report.aggregate.usageReporting.minimumFraction),
            2.0 / 9.0,
            accuracy: 1e-12
        )
        XCTAssertEqual(report.aggregate.cost.amountUSD, 0.30)
        XCTAssertEqual(report.aggregate.cost.coverage.reportedRequests, 2)
        XCTAssertEqual(report.aggregate.cost.coverage.indeterminateRequests, 4)

        let repeated = try await ledger.migrateLegacy(
            identifier: "usage-ledger-v1-test",
            aggregates: [aggregateA, aggregateB],
            messageBackfill: [inside, before, otherProvider]
        )
        XCTAssertEqual(repeated.status, .alreadyApplied)
        XCTAssertTrue(repeated.mayClearLegacySource)
        let repeatedRowCount = try await ledger.count()
        XCTAssertEqual(repeatedRowCount, 4)

        try await ledger.clear()
        let clearedRowCount = try await ledger.count()
        let migrationStillComplete = try await ledger.hasCompletedMigration("usage-ledger-v1-test")
        XCTAssertEqual(clearedRowCount, 0)
        XCTAssertTrue(migrationStillComplete)
        let afterClear = try await ledger.migrateLegacy(
            identifier: "usage-ledger-v1-test",
            aggregates: [aggregateA],
            messageBackfill: []
        )
        XCTAssertEqual(afterClear.status, .alreadyApplied)
        let finalRowCount = try await ledger.count()
        XCTAssertEqual(finalRowCount, 0)

        await cleanup(ledger, directory: directory)
    }

    func testLegacyBucketAdapterDoesNotTurnAmbiguousTokenZerosIntoObservedZeros() {
        var bucket = UsageBucket()
        bucket.requests = 2
        bucket.promptTokens = 0
        bucket.completionTokens = 15
        bucket.costUSD = 0
        bucket.pricedRequests = 1

        let aggregate = LegacyUsageAggregate(
            providerID: UUID(),
            hourIndex: 42,
            bucket: bucket
        )
        XCTAssertEqual(aggregate.requestCount, 2)
        XCTAssertNil(aggregate.inputTokens)
        XCTAssertEqual(aggregate.outputTokens, 15)
        XCTAssertEqual(aggregate.cost?.amountUSD, 0)
        XCTAssertEqual(aggregate.cost?.provenance, .legacyAggregate)
        XCTAssertNil(aggregate.usageReportedRequests)
        XCTAssertEqual(aggregate.costReportedRequests, 1)
    }

    func testMessageBackfillUsesMessageIDAsCrossMigrationDedupeKey() async throws {
        let (ledger, directory) = makeLedger()
        let messageID = UUID()
        let backfill = MessageUsageBackfill(
            messageID: messageID,
            usage: RequestUsage(
                occurredAt: Date(timeIntervalSince1970: 100),
                purpose: .chat,
                outcome: .succeeded,
                inputTokens: 1,
                outputTokens: 1,
                metricProvenance: .persistedMessage
            )
        )
        let first = try await ledger.migrateLegacy(identifier: "migration-a", aggregates: [], messageBackfill: [backfill])
        let second = try await ledger.migrateLegacy(identifier: "migration-b", aggregates: [], messageBackfill: [backfill])
        XCTAssertEqual(first.backfilledMessages, 1)
        XCTAssertEqual(second.backfilledMessages, 0)
        XCTAssertEqual(second.duplicateRows, 1)
        let rowCount = try await ledger.count()
        XCTAssertEqual(rowCount, 1)

        await cleanup(ledger, directory: directory)
    }

    func testLatestQuotaAndPricingSnapshotRoundTrip() async throws {
        let (ledger, directory) = makeLedger()
        let provider = UUID()
        let pricingDate = Date(timeIntervalSince1970: 5_000)
        let quotaDate = Date(timeIntervalSince1970: 5_001)
        let resetDate = Date(timeIntervalSince1970: 8_000)
        let usage = RequestUsage(
            occurredAt: Date(timeIntervalSince1970: 5_010),
            providerID: provider,
            effectiveModelID: "priced-model",
            purpose: .autoContinue,
            outcome: .succeeded,
            inputTokens: 2_000,
            outputTokens: 100,
            cacheReadTokens: 1_000,
            cacheWrite5mTokens: 200,
            metricProvenance: .providerReported,
            cost: CostEvidence(
                amountUSD: 0.0123,
                provenance: .publishedPricingSnapshot,
                inputPerMillion: 3,
                outputPerMillion: 15,
                cacheReadPerMillion: 0.3,
                cacheWrite5mPerMillion: 3.75,
                longContextInputPerMillion: 6,
                longContextOutputPerMillion: 22.5,
                longContextThresholdTokens: 200_000,
                pricingCapturedAt: pricingDate
            ),
            quota: UsageQuotaEvidence(
                provenance: .responseHeaders,
                observedAt: quotaDate,
                requestsRemaining: 9,
                requestsLimit: 10,
                tokensRemaining: 1_000,
                tokensLimit: 2_000,
                resetAt: resetDate
            ),
            latencyMilliseconds: 250
        )
        try await ledger.record(usage)

        let report = try await ledger.query(
            UsageQuery(period: .allTime, endingAt: Date(timeIntervalSince1970: 6_000))
        )
        XCTAssertEqual(report.recent.first, usage)
        XCTAssertEqual(report.aggregate.cacheReadTokens.value, 1_000)
        XCTAssertEqual(report.aggregate.cacheWrite5mTokens.value, 200)
        XCTAssertEqual(report.aggregate.cost.pricingSnapshotRequests, 1)
        XCTAssertEqual(report.aggregate.averageLatencyMilliseconds, 250)
        let latestQuota = try await ledger.latestQuota(providerID: provider)
        XCTAssertEqual(latestQuota, usage.quota)

        await cleanup(ledger, directory: directory)
    }

    func testValidationRejectsImpossibleOrNegativeRecords() async throws {
        let (ledger, directory) = makeLedger()
        let negative = RequestUsage(
            purpose: .chat,
            outcome: .succeeded,
            inputTokens: -1,
            metricProvenance: .providerReported
        )
        do {
            _ = try await ledger.record(negative)
            XCTFail("negative usage should be rejected")
        } catch let error as UsageLedgerError {
            XCTAssertNotNil(error.errorDescription)
        }

        let aggregateDisguisedAsLive = RequestUsage(
            purpose: .chat,
            outcome: .succeeded,
            inputTokens: 10,
            requestCount: 2
        )
        do {
            _ = try await ledger.record(aggregateDisguisedAsLive)
            XCTFail("non-legacy rows cannot represent multiple requests")
        } catch is UsageLedgerError {
            // Expected.
        }
        let rowCount = try await ledger.count()
        XCTAssertEqual(rowCount, 0)

        await cleanup(ledger, directory: directory)
    }

    func testSchemaContainsNoConversationOrPayloadColumns() async throws {
        let (ledger, directory) = makeLedger()
        try await ledger.open()
        let databaseURL = ledger.databaseURL
        await ledger.close()

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA table_info(usage_records);", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 1) {
                columns.append(String(cString: pointer))
            }
        }

        XCTAssertFalse(columns.isEmpty)
        for forbidden in ["prompt", "response", "content", "attachment", "conversation", "title"] {
            XCTAssertFalse(columns.contains { $0.contains(forbidden) }, "schema leaked a \(forbidden) column")
        }
        XCTAssertTrue(columns.contains("input_tokens"))
        XCTAssertTrue(columns.contains("cost_usd"))
        XCTAssertTrue(columns.contains("source_id"))

        try? FileManager.default.removeItem(at: directory)
    }
}
