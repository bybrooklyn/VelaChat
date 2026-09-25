import XCTest
@testable import VelaCore

/// Anthropic OAuth usage endpoint shapes, pinned against the documented
/// responses the community monitors parse (flat keys and the newer
/// `limits` array). Fixtures are hand-built in the documented shape —
/// the endpoint needs the user's live Claude OAuth token, so no test
/// here touches the network.
final class ClaudeUsageProbeTests: XCTestCase {
    func testFlatKeysMapToFiveHourAndWeeklyWindows() throws {
        let json = """
        {"five_hour":{"utilization":33.0,"resets_at":"2026-04-11T07:00:00.528743+00:00"},"seven_day":{"utilization":13.0,"resets_at":"2026-04-17T00:59:59+00:00"},"seven_day_opus":null,"seven_day_sonnet":{"utilization":1.0,"resets_at":"2026-04-16T00:59:59+00:00"},"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
        """
        let payload = try JSONDecoder().decode(
            ClaudeUsageProbe.UsageResponse.self, from: Data(json.utf8)
        )
        let snapshot = try XCTUnwrap(payload.quotaSnapshot())
        XCTAssertEqual(snapshot.primaryWindow?.usedPercent, 33.0)
        XCTAssertEqual(snapshot.primaryWindow?.windowMinutes, 300)
        XCTAssertNotNil(snapshot.primaryWindow?.resetAt)
        XCTAssertEqual(snapshot.secondaryWindow?.usedPercent, 13.0)
        XCTAssertEqual(snapshot.secondaryWindow?.windowMinutes, 10_080)
    }

    func testLimitsArrayTakesPrecedenceOverFlatKeys() throws {
        let json = """
        {"five_hour":null,"seven_day":null,"limits":[{"kind":"session","percent":42.0,"resets_at":"2026-04-11T07:00:00+00:00"},{"kind":"weekly_all","percent":7.0,"resets_at":"2026-04-17T00:59:59+00:00"}]}
        """
        let payload = try JSONDecoder().decode(
            ClaudeUsageProbe.UsageResponse.self, from: Data(json.utf8)
        )
        let snapshot = try XCTUnwrap(payload.quotaSnapshot())
        XCTAssertEqual(snapshot.primaryWindow?.usedPercent, 42.0)
        XCTAssertEqual(snapshot.secondaryWindow?.usedPercent, 7.0)
    }

    func testEmptyPayloadYieldsNil() throws {
        let payload = try JSONDecoder().decode(
            ClaudeUsageProbe.UsageResponse.self, from: Data("{}".utf8)
        )
        XCTAssertNil(payload.quotaSnapshot())
    }
}
