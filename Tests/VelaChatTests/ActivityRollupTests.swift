import XCTest
@testable import VelaChat
@testable import VelaCore

/// The one-line-per-reply rollup and the chips under it.
///
/// A reply used to grow a row per tool call, each repeating what the prose
/// was about to say, every one stamped with a duration like "<0.1s". These
/// assertions pin the replacement: what the single line says, when it says
/// a duration at all, what the expanded detail drops as redundant, and
/// which files become chips.
final class ActivityRollupTests: XCTestCase {

    private func record(
        _ kind: ActivityKind,
        _ argument: String = "",
        result: String = "",
        isError: Bool = false,
        started: Double? = nil,
        finished: Double? = nil
    ) -> ActivityRecord {
        ActivityRecord(
            kind: kind,
            toolName: "t",
            argument: argument,
            result: result,
            isError: isError,
            isRunning: false,
            startedAt: started.map { Date(timeIntervalSinceReferenceDate: $0) },
            finishedAt: finished.map { Date(timeIntervalSinceReferenceDate: $0) }
        )
    }

    // MARK: - The summary line

    func testSummaryGroupsByKindInFirstAppearanceOrder() {
        XCTAssertEqual(ActivitySummary.label(for: []), "")
        XCTAssertEqual(ActivitySummary.label(for: [record(.fileWrite, "a.md")]), "Wrote 1 file")
        XCTAssertEqual(
            ActivitySummary.label(for: [record(.webSearch), record(.webSearch), record(.fetchURL), record(.fileWrite, "a.md")]),
            "2 web searches · read 1 page · wrote 1 file"
        )
        // Only the line's first character is capitalized — not every part.
        XCTAssertEqual(
            ActivitySummary.label(for: [record(.fetchURL), record(.webSearch)]),
            "Read 1 page · 1 web search"
        )
    }

    func testSummaryCountsFailures() {
        XCTAssertEqual(
            ActivitySummary.label(for: [record(.fetchURL), record(.fetchURL, isError: true)]),
            "Read 2 pages · 1 failed"
        )
    }

    func testDurationIsASpanAndOnlyWhenItMeansSomething() {
        // Sub-second work says nothing rather than "<0.1s" — that stamp on
        // every row was most of what made the old presentation noisy.
        XCTAssertNil(ActivitySummary.durationLabel(for: [record(.fileWrite, started: 0, finished: 0.4)]))
        XCTAssertEqual(ActivitySummary.durationLabel(for: [record(.fileWrite, started: 0, finished: 2.4)]), "2s")
        XCTAssertEqual(ActivitySummary.durationLabel(for: [record(.command, started: 0, finished: 95)]), "1m 35s")
        // Overlapping calls: wall clock, not the sum of the parts.
        XCTAssertEqual(
            ActivitySummary.durationLabel(for: [
                record(.fetchURL, started: 0, finished: 4),
                record(.fetchURL, started: 1, finished: 5),
            ]),
            "5s"
        )
        // A transcript saved before timestamps existed implies no number.
        XCTAssertNil(ActivitySummary.durationLabel(for: [record(.fileWrite, "a.md")]))
    }

    func testRedundantResultsAreDropped() {
        XCTAssertFalse(ActivitySummary.resultAddsInformation("Wrote 956 bytes to notes.md.", beyond: "Wrote notes.md"))
        XCTAssertFalse(ActivitySummary.resultAddsInformation("", beyond: "Wrote notes.md"))
        XCTAssertTrue(ActivitySummary.resultAddsInformation("No matches.", beyond: "Searched files for “handle”"))
        XCTAssertTrue(ActivitySummary.resultAddsInformation("a.swift:1: x\na.swift:9: y", beyond: "Searched files"))
        // An error still shows even when it echoes the label's filename.
        XCTAssertTrue(ActivitySummary.resultAddsInformation("Error: the file wasn't found", beyond: "Read notes.md"))
    }

    func testCreateDocumentHasItsOwnKind() {
        XCTAssertEqual(ActivityKind.from(toolName: ToolCatalog.createDocument.name), .document)
        XCTAssertEqual(ActivityKind.document.finishedLabel(argument: "q3.xlsx"), "Created q3.xlsx")
        XCTAssertEqual(ActivityKind.document.aggregateUnit(count: 2), "created 2 documents")
    }

    func testActivityRecordsReadsTheTimelineInOrder() {
        var message = ChatMessage(role: "assistant", content: "")
        message.segments = [
            .text(id: UUID(), content: "hi"),
            .activity(record(.fileWrite, "a.md")),
            .reasoning(id: UUID(), content: "think"),
            .activity(record(.document, "b.xlsx")),
        ]
        XCTAssertEqual(message.activityRecords.map(\.argument), ["a.md", "b.xlsx"])
    }

    // MARK: - Chips

    private func makeWorkspace(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-chip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return root
    }

    func testChipsCoverWritesEditsAndDocumentsButNotReads() throws {
        let root = try makeWorkspace(["a.md", "b.xlsx", "src/c.swift", "read-only.txt"])
        defer { try? FileManager.default.removeItem(at: root) }

        let chips = ProducedFile.chips(
            from: [
                record(.fileWrite, "a.md"),
                record(.fileRead, "read-only.txt"),
                record(.document, "b.xlsx"),
                record(.fileEdit, "src/c.swift"),
            ],
            root: root
        )
        XCTAssertEqual(chips.map(\.relativePath), ["a.md", "b.xlsx", "src/c.swift"])
        XCTAssertEqual(chips.map(\.displayName), ["a.md", "b.xlsx", "c.swift"])
        XCTAssertEqual(chips.map(\.typeLabel), ["Markdown", "Spreadsheet", "Swift"])
    }

    func testChipsDedupeAndSkipFailures() throws {
        let root = try makeWorkspace(["a.md"])
        defer { try? FileManager.default.removeItem(at: root) }

        let chips = ProducedFile.chips(
            from: [
                record(.fileWrite, "a.md"),
                record(.fileEdit, "a.md"),
                record(.fileWrite, "never-written.md", isError: true),
                record(.fileWrite, ""),
            ],
            root: root
        )
        XCTAssertEqual(chips.count, 1, "a file written then edited is one chip, not two")
        XCTAssertEqual(chips[0].relativePath, "a.md")
    }

    func testChipResolvesTheExtensionCreateDocumentAppends() throws {
        // The model asked for "report"; the tool saved "report.xlsx". A chip
        // pointing at the name as typed would open nothing.
        let root = try makeWorkspace(["report.xlsx"])
        defer { try? FileManager.default.removeItem(at: root) }

        let chips = ProducedFile.chips(from: [record(.document, "report")], root: root)
        XCTAssertEqual(chips.map(\.relativePath), ["report.xlsx"])
        XCTAssertEqual(chips.first?.typeLabel, "Spreadsheet")
    }

    func testFileThatIsNotThereProducesNoChip() throws {
        let root = try makeWorkspace([])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(ProducedFile.chips(from: [record(.fileWrite, "ghost.md")], root: root).isEmpty)
    }
}
