import XCTest
@testable import VelaChat
import VelaCore

@MainActor
final class UsageDashboardModelTests: XCTestCase {
    func testRefreshAndClearUseInjectedLedger() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-usage-dashboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = UsageLedger(databaseURL: directory.appendingPathComponent("usage.sqlite"))
        _ = try await ledger.record(RequestUsage(
            purpose: .chat,
            outcome: .succeeded,
            inputTokens: 100,
            outputTokens: 20,
            metricProvenance: .providerReported
        ))

        let model = UsageDashboardModel(ledger: ledger)
        model.refresh()
        try await waitUntil { model.report?.aggregate.requestCount == 1 }
        XCTAssertNil(model.errorMessage)

        model.clearHistory()
        try await waitUntil { model.report?.aggregate.requestCount == 0 && !model.isLoading }
        let clearedCount = try await ledger.count()
        XCTAssertEqual(clearedCount, 0)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for dashboard state", file: file, line: line)
    }
}
