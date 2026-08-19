import XCTest
@testable import VelaChat

/// `AskUserQuestionPayload.parse` turns a ````ask-user` fenced block into an
/// interactive card. A real payload was once rejected outright — silently
/// falling through to the generic Markdown code-block renderer, so the user
/// saw raw JSON in a box titled "Ask-User" instead of a picker — because a
/// single wrong-shaped field (a boolean sent as the string `"true"`) failed
/// `JSONDecoder`'s all-or-nothing `decode` call. These cases pin the fix
/// (found and confirmed with a standalone `swiftc` harness before touching
/// `Models.swift`) and the closing-fence/validation gaps found alongside it,
/// while also pinning that the original false-positive guard — prose that
/// merely *mentions* the convention must never open a card — still holds.
final class AskUserQuestionPayloadTests: XCTestCase {
    private let baseSingleLine = #"{"questions":[{"header":"Timeline","question":"When is your trip?","multiSelect":false,"options":[{"label":"Next week","description":"Soon","recommended":true},{"label":"Next month","description":"Later"}]}],"allowNotes":true}"#

    // MARK: - Baseline shapes that must keep working

    func testCanonicalShapeParses() {
        let content = "```ask-user\n\(baseSingleLine)\n```"
        XCTAssertNotNil(AskUserQuestionPayload.parse(from: content))
    }

    func testPrefixAndSuffixAreSplitAndTrimmed() {
        let content = "Sure thing.\n\n```ask-user\n\(baseSingleLine)\n```\n\nThanks!"
        let result = AskUserQuestionPayload.parse(from: content)
        XCTAssertEqual(result?.prefix, "Sure thing.")
        XCTAssertEqual(result?.suffix, "Thanks!")
    }

    func testLegacyTopLevelShapeStillDecodes() {
        let legacy = #"{"question":"Pick one","options":[{"label":"A"},{"label":"B"}]}"#
        let content = "```ask-user\n\(legacy)\n```"
        let result = AskUserQuestionPayload.parse(from: content)
        XCTAssertEqual(result?.payload.questions.count, 1)
    }

    /// The false-positive guard this format depends on: a message that only
    /// *talks about* the convention, with no real block, must never open a
    /// card — even though it contains the exact opening tag text.
    func testProseMerelyMentioningTheConventionDoesNotOpenACard() {
        let content = """
            The assistant can use a fenced block that starts with ```ask-user to pose
            a multiple-choice question, followed by JSON, then a closing ``` on its own
            line.
            """
        XCTAssertNil(AskUserQuestionPayload.parse(from: content))
    }

    /// Same guard, but the prose is immediately followed by a real block —
    /// the mention must not consume the fence that legitimately opens next.
    func testProseMentioningConventionFollowedByRealBlockStillParses() {
        let content = """
            When you want to ask me something, use a fenced block starting with \
            ```ask-user on its own line.

            ```ask-user
            \(baseSingleLine)
            ```
            """
        XCTAssertNotNil(AskUserQuestionPayload.parse(from: content))
    }

    // MARK: - The root cause: JSONDecoder's all-or-nothing strictness

    /// The actual observed failure: a model emitted `"recommended": "true"`
    /// (a JSON string) instead of a real boolean. `JSONDecoder.decode` fails
    /// the entire payload on one such mismatch — confirmed against the
    /// original code with a standalone harness before this fix existed.
    func testRecommendedAsJSONStringInsteadOfBoolStillParses() {
        let json = #"{"questions":[{"header":"Timeline","question":"When?","options":[{"label":"Soon","recommended":"true"},{"label":"Later"}]}]}"#
        let content = "```ask-user\n\(json)\n```"
        let result = AskUserQuestionPayload.parse(from: content)
        XCTAssertEqual(result?.payload.questions.first?.options.first?.recommended, true)
    }

    func testMultiSelectAsJSONStringInsteadOfBoolStillParses() {
        let json = #"{"questions":[{"header":"Timeline","question":"When?","multiSelect":"false","options":[{"label":"Soon"},{"label":"Later"}]}]}"#
        let content = "```ask-user\n\(json)\n```"
        let result = AskUserQuestionPayload.parse(from: content)
        XCTAssertEqual(result?.payload.questions.first?.multiSelect, false)
    }

    func testRecommendedAsIntInsteadOfBoolStillParses() {
        let json = #"{"questions":[{"header":"Timeline","question":"When?","options":[{"label":"Soon","recommended":1},{"label":"Later"}]}]}"#
        let content = "```ask-user\n\(json)\n```"
        let result = AskUserQuestionPayload.parse(from: content)
        XCTAssertEqual(result?.payload.questions.first?.options.first?.recommended, true)
    }

    func testOptionLabelAsJSONNumberStillParses() {
        let json = #"{"questions":[{"header":"Count","question":"How many?","options":[{"label":1},{"label":2}]}]}"#
        let content = "```ask-user\n\(json)\n```"
        let result = AskUserQuestionPayload.parse(from: content)
        XCTAssertEqual(result?.payload.questions.first?.options.map(\.label), ["1", "2"])
    }

    // MARK: - Closing-fence strictness

    /// A model that continues its sentence right after the closing fence,
    /// with no blank line, used to leave the fence-search with no match at
    /// all (the old pattern required the fence to be alone on its line).
    func testClosingFenceGluedToTrailingProseStillParses() {
        let content = "```ask-user\n\(baseSingleLine)\n```Thanks for your patience!"
        let result = AskUserQuestionPayload.parse(from: content)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.suffix, "Thanks for your patience!")
    }

    /// No newline at all between the JSON's closing brace and the fence —
    /// the closing backticks aren't even at the start of a line.
    func testJSONGluedDirectlyToClosingFenceStillParses() {
        let content = "```ask-user\n\(baseSingleLine)```"
        XCTAssertNotNil(AskUserQuestionPayload.parse(from: content))
    }

    func testCaseInsensitiveLanguageTagStillParses() {
        let content = "```Ask-User\n\(baseSingleLine)\n```"
        XCTAssertNotNil(AskUserQuestionPayload.parse(from: content))
    }

    func testFourBacktickFenceStillParses() {
        let content = "````ask-user\n\(baseSingleLine)\n````"
        XCTAssertNotNil(AskUserQuestionPayload.parse(from: content))
    }

    /// A fully single-line block (open fence, JSON, and close fence with no
    /// line breaks anywhere) is intentionally still rejected: relaxing the
    /// *opening* fence to tolerate trailing content on its own line would
    /// let ordinary prose like "use ```ask-user to ask a question" open a
    /// card, which is exactly what the line-start anchor exists to prevent.
    func testFullySingleLineBlockIsStillNotParsed() {
        let content = "```ask-user\(baseSingleLine)```"
        XCTAssertNil(AskUserQuestionPayload.parse(from: content))
    }

    // MARK: - Per-question validation no longer sinks the whole card

    /// One malformed question (too few options) used to reject the entire
    /// multi-question payload. It should now just be dropped, keeping the
    /// rest of an otherwise well-formed card usable.
    func testOneBadQuestionAmongGoodOnesIsDroppedNotFatal() {
        let json = #"{"questions":[{"header":"Scope","question":"Which scope?","options":[{"label":"Small"},{"label":"Large"}]},{"header":"Confirm","question":"Proceed?","options":[{"label":"Yes"}]},{"header":"Auth","question":"Which auth?","options":[{"label":"OAuth"},{"label":"API key"}]}],"allowNotes":true}"#
        let content = "```ask-user\n\(json)\n```"
        let result = AskUserQuestionPayload.parse(from: content)
        XCTAssertEqual(result?.payload.questions.count, 2)
        XCTAssertEqual(result?.payload.questions.map(\.header), ["Scope", "Auth"])
    }

    /// When *every* question is malformed, there's nothing usable left, so
    /// this must still fall through to the raw-JSON renderer rather than
    /// show an empty card.
    func testAllQuestionsMalformedStillRejectsWholePayload() {
        let json = #"{"questions":[{"header":"Confirm","question":"Proceed with deletion?","options":[{"label":"Yes, delete"}]}]}"#
        let content = "```ask-user\n\(json)\n```"
        XCTAssertNil(AskUserQuestionPayload.parse(from: content))
    }

    func testMissingOptionsFieldEntirelyStillRejects() {
        let json = #"{"questions":[{"header":"Timeline","question":"When?"}]}"#
        let content = "```ask-user\n\(json)\n```"
        XCTAssertNil(AskUserQuestionPayload.parse(from: content))
    }

    /// Options as a plain array of strings (rather than option objects) is a
    /// real shape change, not a type slip — still correctly rejected rather
    /// than guessed at.
    func testOptionsAsPlainStringArrayStillRejects() {
        let json = #"{"questions":[{"header":"Timeline","question":"When?","options":["Soon","Later"]}]}"#
        let content = "```ask-user\n\(json)\n```"
        XCTAssertNil(AskUserQuestionPayload.parse(from: content))
    }

    // MARK: - Streaming placeholder helpers stay consistent with parse

    func testUnterminatedFenceIsDetectedMidStream() {
        let content = "Let me ask you something.\n\n```ask-user\n{\"questions\":[{\"question\":\"When?\""
        XCTAssertTrue(AskUserQuestionPayload.hasUnterminatedFence(in: content))
        XCTAssertEqual(AskUserQuestionPayload.prefixBeforeUnterminatedFence(in: content), "Let me ask you something.")
    }

    func testTerminatedFenceIsNotFlaggedAsUnterminated() {
        let content = "```ask-user\n\(baseSingleLine)\n```"
        XCTAssertFalse(AskUserQuestionPayload.hasUnterminatedFence(in: content))
    }
}
