import XCTest
@testable import VelaCore

/// Anthropic allows **at most four** `cache_control` blocks per request,
/// counted across `system`, `tools` and `messages` together. A fifth is an
/// HTTP 400 — the whole reply fails, it doesn't merely cache less. So the
/// count is a hard invariant, not a preference, and it has to hold at
/// every round of a tool loop that keeps appending turns.
final class AnthropicPromptCacheTests: XCTestCase {

    // MARK: Fixtures

    private func systemBlocks() -> [[String: Any]] {
        [["type": "text", "text": "You are VelaChat.", "cache_control": ["type": "ephemeral"]]]
    }

    private func toolObjects(count: Int) -> [[String: Any]] {
        (0..<count).map { ["name": "tool_\($0)", "description": "d", "input_schema": ["type": "object"]] }
    }

    private func body(system: [[String: Any]], tools: [[String: Any]], turns: [[String: Any]]) -> [String: Any] {
        ["model": "claude-sonnet-4-5", "max_tokens": 8_192, "system": system, "tools": tools, "messages": turns]
    }

    /// One assistant/user pair as a tool round really appends them.
    private func toolRound(_ index: Int) -> [[String: Any]] {
        [
            ["role": "assistant", "content": [
                ["type": "text", "text": "Looking that up."],
                ["type": "tool_use", "id": "call_\(index)", "name": "fetch_url", "input": ["url": "https://example.com"]]
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "call_\(index)", "content": "…result \(index)…"]
            ]]
        ]
    }

    // MARK: The invariant

    /// The stated design: exactly two. One on the static head (system,
    /// which also covers `tools` — they render ahead of it), one that moves
    /// to the newest turn.
    func testExactlyTwoBreakpointsOnAPlainRequest() {
        var turns: [[String: Any]] = [["role": "user", "content": "Hello"]]
        AnthropicPromptCache.markLatestTurn(&turns)

        let request = body(system: systemBlocks(), tools: toolObjects(count: 12), turns: turns)
        XCTAssertEqual(AnthropicPromptCache.breakpointCount(inBody: request), AnthropicPromptCache.breakpointsUsed)
        XCTAssertLessThanOrEqual(AnthropicPromptCache.breakpointCount(inBody: request), AnthropicPromptCache.maxBreakpoints)
    }

    /// The failure this exists to prevent: a loop that adds a breakpoint
    /// per round hits five on round four and 400s. Marking must strip
    /// before it adds, so the count is flat no matter how long the loop
    /// runs — including well past the raised `Limits.maxToolRounds`.
    func testBreakpointsNeverExceedFourAcrossALongToolLoop() {
        var turns: [[String: Any]] = [["role": "user", "content": "Research this thoroughly."]]

        for round in 0..<(Limits.maxToolRounds * 3) {
            AnthropicPromptCache.markLatestTurn(&turns)
            let request = body(system: systemBlocks(), tools: toolObjects(count: 20), turns: turns)
            let count = AnthropicPromptCache.breakpointCount(inBody: request)
            XCTAssertLessThanOrEqual(count, AnthropicPromptCache.maxBreakpoints, "round \(round)")
            XCTAssertEqual(count, AnthropicPromptCache.breakpointsUsed, "round \(round)")
            turns.append(contentsOf: toolRound(round))
        }
    }

    /// Even if a stray marker were left behind by some other code path,
    /// marking must return the turns array to exactly one.
    func testMarkingRemovesPreviousBreakpoints() {
        var turns: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": "a", "cache_control": ["type": "ephemeral"]]]],
            ["role": "assistant", "content": [["type": "text", "text": "b", "cache_control": ["type": "ephemeral"]]]],
            ["role": "user", "content": [["type": "text", "text": "c", "cache_control": ["type": "ephemeral"]]]],
            ["role": "assistant", "content": [["type": "text", "text": "d", "cache_control": ["type": "ephemeral"]]]],
        ]
        XCTAssertEqual(AnthropicPromptCache.breakpointCount(inBody: ["messages": turns]), 4)

        AnthropicPromptCache.markLatestTurn(&turns)
        XCTAssertEqual(AnthropicPromptCache.breakpointCount(inBody: ["messages": turns]), 1)
    }

    // MARK: Placement

    /// A plain-string turn has no block to mark, so it is promoted to a
    /// single text block — a shape Anthropic accepts identically.
    func testStringContentIsPromotedToABlock() {
        var turns: [[String: Any]] = [["role": "user", "content": "Hello"]]
        AnthropicPromptCache.markLatestTurn(&turns)

        guard let blocks = turns[0]["content"] as? [[String: Any]] else {
            return XCTFail("content should have been promoted to a block array")
        }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(blocks[0]["text"] as? String, "Hello")
        XCTAssertNotNil(blocks[0]["cache_control"])
    }

    /// The marker belongs on the *last* block of the *last* turn: that is
    /// what keeps it inside Anthropic's ~20-block lookback as the loop
    /// grows, which a marker pinned near the head would fall out of.
    func testMarkerLandsOnTheFinalBlockOfTheFinalTurn() {
        var turns: [[String: Any]] = [["role": "user", "content": "First"]]
        turns.append(contentsOf: toolRound(0))
        AnthropicPromptCache.markLatestTurn(&turns)

        guard let lastTurn = turns.last, let blocks = lastTurn["content"] as? [[String: Any]] else {
            return XCTFail("expected block content")
        }
        XCTAssertNotNil(blocks.last?["cache_control"])
        XCTAssertEqual(blocks.last?["type"] as? String, "tool_result")
        XCTAssertEqual(
            AnthropicPromptCache.breakpointCount(inBody: ["messages": Array(turns.dropLast())]),
            0,
            "earlier turns keep no marker"
        )
    }

    func testEmptyTurnsAreLeftAlone() {
        var turns: [[String: Any]] = []
        AnthropicPromptCache.markLatestTurn(&turns)
        XCTAssertTrue(turns.isEmpty)
    }

    /// The counter has to see a marker wherever it hides, or the invariant
    /// it guards is worthless.
    func testCounterFindsBreakpointsInEverySection() {
        let request: [String: Any] = [
            "system": [["type": "text", "text": "s", "cache_control": ["type": "ephemeral"]]],
            "tools": [["name": "t", "cache_control": ["type": "ephemeral"]]],
            "messages": [
                ["role": "user", "content": [["type": "text", "text": "m", "cache_control": ["type": "ephemeral"]]]]
            ],
            // Not one of the three counted sections, and not a block.
            "metadata": ["user_id": "cache_control"]
        ]
        XCTAssertEqual(AnthropicPromptCache.breakpointCount(inBody: request), 3)
    }
}

/// Every round of a tool loop resends the whole exchange, so a 40 KB page
/// fetch in round 2 is re-billed in every round after it. That is the
/// quadratic term behind a reply that reached 82,000 tokens without
/// finishing its work.
final class ToolResultReplayTests: XCTestCase {

    func testRecentRoundsReplayInFull() {
        // With `Limits.toolResultReplayRounds` rounds kept verbatim, a
        // result is only condensed once it is older than that.
        for age in 0...Limits.toolResultReplayRounds {
            XCTAssertFalse(
                ToolResultReplay.shouldCondense(round: 5, currentRound: 5 + age),
                "a result \(age) rounds old is still being reasoned about"
            )
        }
        XCTAssertTrue(ToolResultReplay.shouldCondense(round: 5, currentRound: 5 + Limits.toolResultReplayRounds + 1))
    }

    func testSmallResultsAreLeftExactlyAsTheyAre() {
        let result = "42"
        XCTAssertEqual(ToolResultReplay.condensed(result), result)
    }

    /// Never silently: the model must be able to tell "this tool returned
    /// little" from "this was trimmed", and to re-run the call if it needs
    /// the rest.
    func testLargeResultsCarryAnExplicitMarkerNamingTheOriginalSize() {
        let result = String(repeating: "x", count: 40_000)
        let condensed = ToolResultReplay.condensed(result)

        XCTAssertTrue(condensed.hasSuffix("[earlier result truncated, 40000 bytes]"), condensed.suffix(60).description)
        XCTAssertTrue(condensed.hasPrefix(String(repeating: "x", count: Limits.replayedToolResultBytes)))
        XCTAssertLessThan(condensed.utf8.count, result.utf8.count / 10)
    }

    /// Truncating the UTF-8 view directly would hand the provider a
    /// replacement character mid-word on any non-ASCII result.
    func testMultibyteResultsAreNotSplitMidCharacter() {
        let result = String(repeating: "日", count: 5_000)   // 15,000 bytes
        let condensed = ToolResultReplay.condensed(result)

        XCTAssertFalse(condensed.contains("\u{FFFD}"), "no replacement characters")
        XCTAssertTrue(condensed.hasSuffix("[earlier result truncated, 15000 bytes]"))
        XCTAssertTrue(condensed.hasPrefix("日日日"))
    }

    /// The head has to stay inside the byte budget even when every
    /// character costs three bytes.
    func testHeadRespectsTheByteBudget() {
        let result = String(repeating: "日", count: 5_000)
        let condensed = ToolResultReplay.condensed(result)
        let head = condensed.replacingOccurrences(of: "\n\n[earlier result truncated, 15000 bytes]", with: "")
        XCTAssertLessThanOrEqual(head.utf8.count, Limits.replayedToolResultBytes)
    }
}
