import XCTest
@testable import VelaChat

/// Decodes `Fixtures/claude-stream.jsonl`, which was **recorded from real
/// `claude` 2.1.236 sessions**, not hand-authored from a specification.
/// That distinction is the point: the stream-json format is undocumented,
/// so a fixture written from a document would only ever prove that the
/// code matches the document.
///
/// When Claude Code updates and this fails, re-record rather than
/// loosening the assertions.
final class ClaudeControlProtocolTests: XCTestCase {

    private func fixtureLines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-stream.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func frames() throws -> [ClaudeStreamFrame] {
        try fixtureLines().compactMap { ClaudeStreamFrame.decode(line: $0) }
    }

    func testEveryRecordedLineDecodes() throws {
        let lines = try fixtureLines()
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(try frames().count, lines.count, "a recorded frame failed to decode")
    }

    /// No frame may decode as `.unknown` — the fixture only contains types
    /// this file claims to model.
    func testNoRecordedFrameIsUnknown() throws {
        for frame in try frames() {
            if case .unknown(let type) = frame {
                XCTFail("unmodelled frame type: \(type)")
            }
        }
    }

    // MARK: init handshake

    func testInitEventCarriesCapabilitiesAndSession() throws {
        guard case .system(let event)? = try frames().first else {
            return XCTFail("first frame should be system/init")
        }
        XCTAssertEqual(event.subtype, "init")
        XCTAssertNotNil(event.sessionID)
        XCTAssertEqual(event.claudeCodeVersion, "2.1.236")
        XCTAssertEqual(event.apiKeySource, "none", "the bridge must be running on the user's own login, not an API key")

        let capabilities = ClaudeCapabilities(event.capabilities)
        XCTAssertTrue(capabilities.has(.interruptReceipt))
        XCTAssertTrue(capabilities.has(.messageLifecycle))
        // Unknown capability names are ignored, never rejected.
        XCTAssertFalse(capabilities.has("some_future_capability_v9"))
    }

    /// The recorded session was launched with the isolation flags, so it
    /// must show no inherited MCP servers, skills, or slash commands. This
    /// is the empirical check the plan asked for — `--setting-sources ""`
    /// alone was verified NOT to be sufficient.
    func testIsolatedSessionInheritsNothing() throws {
        guard case .system(let event)? = try frames().first else {
            return XCTFail("first frame should be system/init")
        }
        XCTAssertEqual(event.mcpServers, [])
        XCTAssertEqual(event.skills, [])
        XCTAssertEqual(event.slashCommands, [])
        XCTAssertTrue(event.isIsolated)
    }

    // MARK: assistant turns and tool use

    func testAssistantTextIsExtracted() throws {
        let texts = try frames().compactMap { frame -> String? in
            guard case .assistant(let event) = frame else { return nil }
            let text = event.message.text
            return text.isEmpty ? nil : text
        }
        XCTAssertTrue(texts.contains { $0.contains("hello from the fixture") },
                      "expected the recorded reply text")
    }

    func testToolUseDecodesWithItsInput() throws {
        let uses = try frames().flatMap { frame -> [ClaudeToolUse] in
            guard case .assistant(let event) = frame else { return [] }
            return event.message.toolUses
        }
        XCTAssertFalse(uses.isEmpty, "the fixture records real tool calls")
        guard let read = uses.first(where: { $0.name == "Read" }) else {
            return XCTFail("expected a Read tool call")
        }
        XCTAssertTrue(read.id.hasPrefix("toolu_"))
        XCTAssertTrue(read.summary.hasSuffix("note.txt"), "summary should surface the file path")
    }

    /// A `user` frame in this stream is a tool *result* being replayed,
    /// not something a human typed. Confusing the two would put tool
    /// output into the transcript as user messages.
    func testUserFrameCarriesToolResults() throws {
        let results = try frames().flatMap { frame -> [ClaudeToolResult] in
            guard case .user(let event) = frame else { return [] }
            return event.toolResults
        }
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.contains { $0.text.contains("hello from the fixture") })
        XCTAssertTrue(results.allSatisfy { $0.toolUseID.hasPrefix("toolu_") })
    }

    // MARK: result frame and usage

    func testResultCarriesCacheSplitAndCost() throws {
        let results = try frames().compactMap { frame -> ClaudeResultEvent? in
            guard case .result(let event) = frame else { return nil }
            return event
        }
        guard let result = results.first else { return XCTFail("expected a result frame") }
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertNotNil(result.totalCostUSD)

        let usage = try XCTUnwrap(result.usage)
        // The TTL-split cache fields Phase 2's cost math depends on. No
        // OpenAI-compatible provider reports these; Anthropic does.
        let creation = try XCTUnwrap(usage.cacheCreation)
        XCTAssertNotNil(creation.ephemeral1h)
        XCTAssertNotNil(creation.ephemeral5m)
        XCTAssertEqual(
            (creation.ephemeral1h ?? 0) + (creation.ephemeral5m ?? 0),
            usage.cacheCreationInputTokens ?? -1,
            "the TTL split must add up to the reported creation total"
        )
        XCTAssertNotNil(usage.cacheReadInputTokens)
    }

    /// Arrives unprompted and carries a real reset time — a free quota
    /// signal that costs no extra request and cannot itself be throttled.
    func testRateLimitEventDecodes() throws {
        let events = try frames().compactMap { frame -> ClaudeRateLimitEvent.Info? in
            guard case .rateLimit(let event) = frame else { return nil }
            return event.info
        }
        guard let info = events.first else { return XCTFail("expected a rate_limit_event") }
        XCTAssertEqual(info.status, "allowed")
        XCTAssertEqual(info.rateLimitType, "five_hour")
        XCTAssertEqual(info.windowMinutes, 300)
        XCTAssertNotNil(info.resetDate)
    }

    // MARK: forgiving decode

    func testUnknownFrameTypeDoesNotThrow() {
        let frame = ClaudeStreamFrame.decode(line: #"{"type":"something_new_in_a_later_release","x":1}"#)
        guard case .unknown(let type)? = frame else {
            return XCTFail("an unmodelled type must decode as .unknown, not fail")
        }
        XCTAssertEqual(type, "something_new_in_a_later_release")
    }

    func testNonJSONLineIsSkipped() {
        XCTAssertNil(ClaudeStreamFrame.decode(line: "warning: something human-readable"))
        XCTAssertNil(ClaudeStreamFrame.decode(line: "   "))
    }

    // MARK: outbound frames

    func testOutboundUserTurnIsNDJSON() throws {
        let data = try ClaudeOutboundFrame.userTurn(text: "hello").encoded()
        XCTAssertEqual(data.last, 0x0A, "frames must be newline-terminated")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "user")
    }

    func testPermissionResponsesCarryTheRequestID() throws {
        let allow = try ClaudeOutboundFrame.permissionAllow(requestID: "req-1", updatedInput: nil).encoded()
        let allowObject = try JSONSerialization.jsonObject(with: allow) as? [String: Any]
        XCTAssertEqual(allowObject?["request_id"] as? String, "req-1")
        XCTAssertEqual((allowObject?["response"] as? [String: Any])?["behavior"] as? String, "allow")

        let deny = try ClaudeOutboundFrame.permissionDeny(requestID: "req-2", reason: "no").encoded()
        let denyObject = try JSONSerialization.jsonObject(with: deny) as? [String: Any]
        XCTAssertEqual(denyObject?["request_id"] as? String, "req-2")
        XCTAssertEqual((denyObject?["response"] as? [String: Any])?["behavior"] as? String, "deny")
    }
}
