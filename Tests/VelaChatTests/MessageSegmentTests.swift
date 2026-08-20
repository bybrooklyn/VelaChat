import XCTest
@testable import VelaChat

/// `MessageSegment` is persisted with every conversation, so adding a case
/// to it is a storage-format change. These pin the two halves of that: the
/// new `.reasoning` case survives a save/load, and transcripts written
/// before it existed keep decoding exactly as they did — the cached history
/// in `UserDefaults` is real user data, not a disposable cache like the
/// model catalog.
final class MessageSegmentTests: XCTestCase {
    private func roundTrip(_ segments: [MessageSegment]) throws -> [MessageSegment] {
        let data = try JSONEncoder().encode(segments)
        return try JSONDecoder().decode([MessageSegment].self, from: data)
    }

    // MARK: - The new case

    func testReasoningSegmentRoundTrips() throws {
        let id = UUID()
        let decoded = try roundTrip([.reasoning(id: id, content: "Let me check the file first.")])
        guard case .reasoning(let decodedID, let content) = decoded.first else {
            return XCTFail("expected a reasoning segment, got \(String(describing: decoded.first))")
        }
        XCTAssertEqual(decodedID, id)
        XCTAssertEqual(content, "Let me check the file first.")
    }

    /// Order is the entire point of the timeline — a reasoning run that
    /// happened between two tool calls has to come back between them.
    func testInterleavedTimelineKeepsItsOrder() throws {
        let record = ActivityRecord(kind: .fileRead, toolName: "read_file", argument: "notes.md")
        let original: [MessageSegment] = [
            .reasoning(id: UUID(), content: "First I should look."),
            .activity(record),
            .text(id: UUID(), content: "The file says…"),
            .reasoning(id: UUID(), content: "Now let me double-check.")
        ]
        XCTAssertEqual(try roundTrip(original), original)
    }

    // MARK: - Transcripts saved before reasoning segments existed

    func testTranscriptWithoutReasoningSegmentsStillDecodes() throws {
        let id = UUID()
        let json = """
            [{"type":"text","id":"\(id.uuidString)","content":"Hello."}]
            """
        let decoded = try JSONDecoder().decode([MessageSegment].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, [.text(id: id, content: "Hello.")])
    }

    func testActivitySegmentWithoutTimestampsStillDecodes() throws {
        // Exactly the shape `ActivityRecord` encoded before `startedAt` /
        // `finishedAt` existed. They are optional so this decodes untouched,
        // and so a record with no observed duration renders none rather than
        // claiming "0.0s".
        let id = UUID()
        let json = """
            [{"type":"activity","record":{"id":"\(id.uuidString)","kind":"webSearch",\
            "toolName":"web_search","argument":"swiftui","result":"…","isError":false,\
            "isRunning":false}}]
            """
        let decoded = try JSONDecoder().decode([MessageSegment].self, from: Data(json.utf8))
        guard case .activity(let record) = decoded.first else {
            return XCTFail("expected an activity segment, got \(String(describing: decoded.first))")
        }
        XCTAssertEqual(record.id, id)
        XCTAssertNil(record.startedAt)
        XCTAssertNil(record.finishedAt)
        XCTAssertNil(record.duration)
        XCTAssertNil(record.durationLabel)
    }

    /// The catch-all in `init(from:)` is deliberate: a type written by a
    /// newer build must degrade to a text run rather than throw and take the
    /// whole conversation's decode down with it.
    func testUnknownSegmentTypeDegradesToText() throws {
        let json = #"[{"type":"hologram","content":"who knows"}]"#
        let decoded = try JSONDecoder().decode([MessageSegment].self, from: Data(json.utf8))
        guard case .text(_, let content) = decoded.first else {
            return XCTFail("expected a text segment, got \(String(describing: decoded.first))")
        }
        XCTAssertEqual(content, "who knows")
    }

    // MARK: - `reasoning` stays canonical

    /// `ChatMessage.reasoning` relates to the reasoning segments exactly as
    /// `content` relates to the text segments. Everything downstream still
    /// reads `reasoning` directly, so this equality is a contract.
    func testAppendTimelineReasoningKeepsTheCanonicalStringInSync() {
        var message = ChatMessage(role: "assistant", content: "")
        message.appendTimelineReasoning("Let me ")
        message.appendTimelineReasoning("think about this. ")
        message.appendTimelineText("Here goes.")
        message.appendTimelineReasoning("Actually, one more thing.")

        let fromSegments = message.segments.compactMap { segment -> String? in
            if case .reasoning(_, let content) = segment { return content }
            return nil
        }.joined()
        XCTAssertEqual(message.reasoning, fromSegments)
        XCTAssertEqual(message.reasoning, "Let me think about this. Actually, one more thing.")
        XCTAssertEqual(message.content, "Here goes.")
    }

    /// Consecutive reasoning deltas grow one segment; anything in between
    /// starts a new one — otherwise every revealed word would become its own
    /// disclosure row.
    func testConsecutiveReasoningDeltasCoalesceIntoOneSegment() {
        var message = ChatMessage(role: "assistant", content: "")
        message.appendTimelineReasoning("a")
        message.appendTimelineReasoning("b")
        XCTAssertEqual(message.segments.count, 1)

        message.appendTimelineText("text")
        message.appendTimelineReasoning("c")
        XCTAssertEqual(message.segments.count, 3)
    }

    func testHasTimelineReasoningOnlyReportsSegmentBorneReasoning() {
        // The pre-segment shape: `reasoning` set, nothing on the timeline.
        // The top-of-message fallback block keys off this, so a message like
        // this one must still be reported as *not* having timeline
        // reasoning or the chain would vanish from old transcripts.
        var legacy = ChatMessage(role: "assistant", content: "Hi")
        legacy.reasoning = "thought hard"
        XCTAssertFalse(legacy.hasTimelineReasoning)

        var current = ChatMessage(role: "assistant", content: "")
        current.appendTimelineReasoning("thought hard")
        XCTAssertTrue(current.hasTimelineReasoning)
    }

    // MARK: - Duration

    func testDurationIsOnlyReportedWhenBothEndsWereObserved() {
        var record = ActivityRecord(kind: .command, toolName: "run_command", argument: "ls")
        XCTAssertNil(record.durationLabel)

        record.startedAt = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertNil(record.durationLabel, "one end alone must never imply a duration")

        record.finishedAt = Date(timeIntervalSinceReferenceDate: 0.42)
        XCTAssertEqual(record.durationLabel, "0.4s")

        record.finishedAt = Date(timeIntervalSinceReferenceDate: 12.4)
        XCTAssertEqual(record.durationLabel, "12s")

        record.finishedAt = Date(timeIntervalSinceReferenceDate: 64)
        XCTAssertEqual(record.durationLabel, "1m 04s")
    }

    /// A clock adjustment mid-call is the only way this happens, and
    /// "-2.1s" is worse than saying nothing.
    func testNegativeDurationIsSuppressed() {
        var record = ActivityRecord(kind: .command, toolName: "run_command", argument: "ls")
        record.startedAt = Date(timeIntervalSinceReferenceDate: 10)
        record.finishedAt = Date(timeIntervalSinceReferenceDate: 5)
        XCTAssertNil(record.duration)
        XCTAssertNil(record.durationLabel)
    }

    func testUpdateActivityStampsTheFinishTimeItWasGiven() {
        var message = ChatMessage(role: "assistant", content: "")
        var record = ActivityRecord(kind: .webSearch, toolName: "web_search", argument: "swift")
        record.isRunning = true
        record.startedAt = Date(timeIntervalSinceReferenceDate: 100)
        message.appendActivity(record)

        message.updateActivity(
            id: record.id,
            result: "3 results",
            isError: false,
            finishedAt: Date(timeIntervalSinceReferenceDate: 101.5)
        )

        guard case .activity(let updated) = message.segments.first else {
            return XCTFail("expected the activity segment to survive the update")
        }
        XCTAssertFalse(updated.isRunning)
        XCTAssertEqual(updated.durationLabel, "1.5s")
    }
}
