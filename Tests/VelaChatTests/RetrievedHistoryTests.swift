import XCTest
@testable import VelaCore

/// Retrieved history is data, not instructions. Memory recall can surface
/// chunks of prior assistant replies — raw ```ask-user fences included —
/// and a weak model parrots what it's handed, producing stale JSON that
/// looks like a live artifact. These cases pin the neutralizer (a past
/// question returns as "(asked a question)", never the raw fence) and the
/// lenient retry-parse + typed-failure detection for malformed live blocks.
final class RetrievedHistoryTests: XCTestCase {
    private let validPayload = #"{"questions":[{"header":"Scope","question":"How far?","multiSelect":false,"options":[{"label":"Small"},{"label":"Big"}]}],"allowNotes":false}"#

    // MARK: - Neutralizing retrieved turns

    func testCompleteFenceIsReplaced() {
        let text = "Earlier we discussed it.\n\n```ask-user\n\(validPayload)\n```\n\nAnd then more prose."
        let result = AskUserQuestionPayload.neutralizingToolCallSyntax(in: text)
        XCTAssertFalse(result.contains("ask-user"))
        XCTAssertTrue(result.contains("Earlier we discussed it."))
        XCTAssertTrue(result.contains("And then more prose."))
        XCTAssertTrue(result.contains("(asked a question)"))
    }

    func testUnterminatedFenceIsReplacedThroughEnd() {
        let text = "Reply start.\n\n```ask-user\n{\"questions\":[{\"question\":\"Cut"
        let result = AskUserQuestionPayload.neutralizingToolCallSyntax(in: text)
        XCTAssertEqual(result, "Reply start.\n\n(asked a question)")
    }

    func testProseMentioningTheConventionSurvives() {
        let text = "Use ```ask-user to signal a question in this app."
        let result = AskUserQuestionPayload.neutralizingToolCallSyntax(in: text)
        XCTAssertEqual(result, text)
    }

    func testPlainTextPassesThroughUnchanged() {
        let text = "Just an ordinary memory excerpt with no syntax."
        XCTAssertEqual(AskUserQuestionPayload.neutralizingToolCallSyntax(in: text), text)
    }

    func testMultipleFencesAreAllNeutralized() {
        let text = "```ask-user\n\(validPayload)\n```\nmiddle\n```ask-user\n\(validPayload)\n```"
        let result = AskUserQuestionPayload.neutralizingToolCallSyntax(in: text)
        XCTAssertEqual(result.components(separatedBy: "(asked a question)").count - 1, 2)
    }

    // MARK: - Lenient retry-parse for malformed live blocks

    func testCurlyQuotesAreRepairedAndParseSucceeds() {
        // Hand-build a curly-quoted variant of the JSON.
        var curly = ""
        var insideString = false
        for character in validPayload {
            if character == "\"" { curly += insideString ? "\u{201D}" : "\u{201C}"; insideString.toggle() }
            else { curly.append(character) }
        }
        let content = "```ask-user\n\(curly)\n```"
        let parsed = AskUserQuestionPayload.parse(from: content)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.payload.questions.first?.options.count, 2)
    }

    func testTrailingCommasAreRepairedAndParseSucceeds() {
        let trailing = #"{"questions":[{"header":"Scope","question":"How far?","multiSelect":false,"options":[{"label":"Small"},{"label":"Big"},]}],}"#
        let content = "```ask-user\n\(trailing)\n```"
        let parsed = AskUserQuestionPayload.parse(from: content)
        XCTAssertEqual(parsed?.payload.questions.first?.options.count, 2)
    }

    // MARK: - Typed failure detection (the fallback row)

    func testUnparseableCompleteFenceIsDetected() {
        let broken = "```ask-user\nthis is not json at all\n```"
        XCTAssertNil(AskUserQuestionPayload.parse(from: broken))
        XCTAssertTrue(AskUserQuestionPayload.hasCompleteAskUserFence(in: broken))
    }

    func testUnterminatedFenceIsNotCompleteFence() {
        let open = "```ask-user\n{"
        XCTAssertFalse(AskUserQuestionPayload.hasCompleteAskUserFence(in: open))
        XCTAssertTrue(AskUserQuestionPayload.hasUnterminatedFence(in: open))
    }

    func testNoFenceIsNothingSpecial() {
        XCTAssertFalse(AskUserQuestionPayload.hasCompleteAskUserFence(in: "plain prose"))
        XCTAssertFalse(AskUserQuestionPayload.hasUnterminatedFence(in: "plain prose"))
    }
}
