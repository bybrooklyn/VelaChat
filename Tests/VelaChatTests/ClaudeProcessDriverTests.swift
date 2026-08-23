import XCTest
@testable import VelaCore

/// The Claude bridge process driver's pure decision points: the composed
/// single-turn transcript, permission-ask summaries, the rate-limit frame
/// mapping (which must refuse to invent a utilization percent), and the
/// load-bearing shape of the launch arguments.
final class ClaudeProcessDriverTests: XCTestCase {

    // MARK: - Frame helpers

    /// Decodes a control_request frame through the real wire path.
    private func permissionRequest(_ inputJSON: String) throws -> ClaudeControlRequest {
        let json = """
        {"type":"control_request","subtype":"can_use_tool","request_id":"r1","request":{"tool_name":"Bash","input":\(inputJSON)}}
        """
        let frame = try XCTUnwrap(ClaudeStreamFrame.decode(line: json))
        return try XCTUnwrap({
            if case .controlRequest(let request) = frame { return request }
            return nil
        }())
    }

    /// Decodes a rate_limit frame; fails the test when it can't.
    private func decodedRateLimit(status: String?, resetsAt: Double?) throws -> ClaudeRateLimitEvent {
        let reset = resetsAt.map { String($0) } ?? "null"
        let statusJSON = status.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"type":"rate_limit_event","rate_limit_info":{"status":\(statusJSON),"resets_at":\(reset),"rate_limit_type":"five_hour"}}
        """
        let frame = try XCTUnwrap(ClaudeStreamFrame.decode(line: json))
        return try XCTUnwrap({
            if case .rateLimit(let event) = frame { return event }
            return nil
        }())
    }

    private func message(_ role: String, _ content: String) -> ChatMessage {
        ChatMessage(
            id: UUID(), role: role, content: content, reasoning: nil, error: nil,
            isStreaming: false, createdAt: Date(), providerName: nil, modelID: nil,
            isPinned: false, attachments: [], usage: nil, alternates: [],
            segments: [], noticeKind: nil
        )
    }

    // MARK: - Turn composition (one process per turn)

    func testFreshConversationSendsRawMessage() {
        let turn = CompatibleChatClient.composedClaudeTurn([message("user", "Fix the failing test.")])
        XCTAssertEqual(turn, "Fix the failing test.")
    }

    func testLongerConversationComposesLabeledTranscript() {
        let turn = CompatibleChatClient.composedClaudeTurn([
            message("user", "First question."),
            message("assistant", "First answer."),
            message("user", "Follow-up?"),
        ])
        XCTAssertTrue(turn.contains("conversation so far"))
        XCTAssertTrue(turn.contains("--- Assistant ---"))
        XCTAssertTrue(turn.contains("First answer."))
        XCTAssertTrue(turn.contains("respond to this"))
        XCTAssertTrue(turn.hasSuffix("Follow-up?"))
    }

    func testSyntheticNoticesNeverEnterTheWire() {
        let composed = CompatibleChatClient.composedClaudeTurn([
            message("user", "hi"),
            message("notice", "system card text"),
            message("user", "again"),
        ])
        XCTAssertFalse(composed.contains("system card text"))
    }

    func testEmptyConversationStillProducesATurn() {
        XCTAssertFalse(CompatibleChatClient.composedClaudeTurn([]).isEmpty)
    }

    // MARK: - Permission summaries

    func testPermissionSummaryPrefersCommandThenPaths() throws {
        let bash = try permissionRequest(#"{"command":"cargo test --lib"}"#)
        XCTAssertEqual(CompatibleChatClient.permissionSummary(bash), "cargo test --lib")

        let write = try permissionRequest(#"{"file_path":"/tmp/x.swift","content":"irrelevant"}"#)
        XCTAssertEqual(CompatibleChatClient.permissionSummary(write), "/tmp/x.swift")
    }

    // MARK: - Rate-limit mapping

    func testRateLimitOnlyMapsDefiniteExhaustion() throws {
        let exhausted = CompatibleChatClient.quotaSnapshot(
            fromRateLimit: try decodedRateLimit(status: "rate_limited", resetsAt: 1_800_000_000)
        )
        XCTAssertEqual(exhausted?.primaryWindow?.usedPercent, 100)
        XCTAssertEqual(exhausted?.primaryWindow?.windowMinutes, 300)

        // Healthy → nothing: no percent exists to report honestly.
        XCTAssertNil(CompatibleChatClient.quotaSnapshot(
            fromRateLimit: try decodedRateLimit(status: "allowed", resetsAt: 1_800_000_000)
        ))
        // No reset time → nothing to act on.
        XCTAssertNil(CompatibleChatClient.quotaSnapshot(
            fromRateLimit: try decodedRateLimit(status: "rate_limited", resetsAt: nil)
        ))
    }

    // MARK: - Launch argument invariants (Appendix B)

    func testLaunchArgumentsCarryTheSafetyCriticalFlags() {
        var args = ["--print"] + ClaudeExecutableLocator.arguments(includePartialMessages: false)
        args += ["--permission-prompt-tool", "stdio", "--model", "claude-sonnet-5"]

        // The empty setting-sources string must be a REAL argv element.
        let sourcesIndex = args.firstIndex(of: "--setting-sources")
        XCTAssertNotNil(sourcesIndex, "--setting-sources missing")
        if let index = sourcesIndex {
            XCTAssertEqual(args[args.index(after: index)], "")
        }
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(args.contains("--disable-slash-commands"))

        // The mechanism and its reserved sentinel value.
        let promptToolIndex = args.firstIndex(of: "--permission-prompt-tool")
        XCTAssertNotNil(promptToolIndex)
        if let index = promptToolIndex {
            XCTAssertEqual(args[args.index(after: index)], "stdio")
        }

        // Explicit model (empty setting-sources drops the configured one).
        let modelIndex = args.firstIndex(of: "--model")
        XCTAssertNotNil(modelIndex)
        if let index = modelIndex {
            XCTAssertEqual(args[args.index(after: index)], "claude-sonnet-5")
        }

        // Never the bypass / forced-API-key modes.
        XCTAssertFalse(args.contains("--bare"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(args.contains("--permission-mode"))
    }

    // MARK: - Outbound frames

    func testDenyFrameAlwaysCarriesAMessage() throws {
        let deny = ClaudeOutboundFrame.permissionDeny(requestID: "req-1", reason: "timed out")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: deny.encoded()) as? [String: Any])
        let response = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertEqual(response["behavior"] as? String, "deny")
        // Omitting the message makes claude retry forever — mandatory.
        let denialMessage = try XCTUnwrap(response["message"] as? String)
        XCTAssertFalse(denialMessage.isEmpty)
    }

    func testAllowFrameOmitsUpdatedInputWhenAbsent() throws {
        let allow = ClaudeOutboundFrame.permissionAllow(requestID: "req-2", updatedInput: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: allow.encoded()) as? [String: Any])
        let response = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertEqual(response["behavior"] as? String, "allow")
        XCTAssertNil(response["updatedInput"])
    }
}
