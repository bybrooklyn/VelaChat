import XCTest
@testable import VelaChat

/// `StreamingMarkdown.split` is what lets a reply format itself as it types
/// without re-parsing the whole document on every reveal tick — the cost
/// that made the transcript render its streaming tail as plain `Text` in the
/// first place. Two properties carry the whole design, and both are the kind
/// that break silently, so they are pinned here:
///
/// 1. **Exact reconstruction** — `blocks.joined() + tail == input`. Anything
///    else drops or duplicates the model's words on screen.
/// 2. **Prefix stability** — a block, once emitted, never changes as more
///    text arrives. That is what makes identifying blocks by position safe
///    and what stops already-rendered paragraphs re-flowing mid-stream.
///
/// (These were also run against a standalone `swiftc` harness while the
/// splitter was being written, since XCTest can't run on the dev machine —
/// see `Tests/VelaChatTests/README.md`.)
final class StreamingMarkdownTests: XCTestCase {

    // MARK: - Splitting

    func testClosedBlockSplitsOffTheStablePrefix() {
        let split = StreamingMarkdown.split("# Title\n\nSome text\n")
        XCTAssertEqual(split.blocks, ["# Title\n\n"])
        XCTAssertEqual(split.tail, "Some text\n")
    }

    /// The mandatory case: a blank line inside a code fence that hasn't been
    /// closed yet is not a block boundary. Without this a half-written
    /// ```` ``` ```` block flickers as garbage — the fence markers and the
    /// code render as loose prose until the closing fence lands.
    func testBlankLineInsideAnOpenFenceDoesNotSplit() {
        let input = "intro\n\n```swift\nlet a = 1\n\nlet b = 2\n"
        let split = StreamingMarkdown.split(input)
        XCTAssertEqual(split.blocks, ["intro\n\n"])
        XCTAssertEqual(split.tail, "```swift\nlet a = 1\n\nlet b = 2\n")
    }

    func testClosedFenceIsAllowedToSplit() {
        let split = StreamingMarkdown.split("```swift\nlet a = 1\n```\n\nAfter\n")
        XCTAssertEqual(split.blocks, ["```swift\nlet a = 1\n```\n\n"])
        XCTAssertEqual(split.tail, "After\n")
    }

    func testTildeFenceIsHonoredToo() {
        let input = "~~~\nfenced\n\nwith a blank line\n"
        XCTAssertEqual(StreamingMarkdown.split(input).blocks, [])
    }

    /// A list whose items are separated by blank lines is one loose list in
    /// Markdown. Splitting at every gap would render a run of single-item
    /// lists mid-stream and then re-flow into one list at the end — exactly
    /// the layout jump this design exists to avoid.
    func testLooseListStaysOneBlock() {
        let split = StreamingMarkdown.split("- one\n\n- two\n\n- three\n\nAfter the list\n")
        XCTAssertEqual(split.blocks, ["- one\n\n- two\n\n- three\n\n"])
        XCTAssertEqual(split.tail, "After the list\n")
    }

    // MARK: - Degenerate input

    func testEmptyInput() {
        let split = StreamingMarkdown.split("")
        XCTAssertEqual(split.blocks, [])
        XCTAssertEqual(split.tail, "")
    }

    func testTextWithNoBlankLinesIsAllTail() {
        let input = "one line\nanother line\nthird"
        let split = StreamingMarkdown.split(input)
        XCTAssertEqual(split.blocks, [])
        XCTAssertEqual(split.tail, input)
    }

    /// Whitespace alone is never a block — it belongs to the front of
    /// whatever arrives next, or it stays in the tail.
    func testWhitespaceOnlyInputProducesNoBlocks() {
        XCTAssertEqual(StreamingMarkdown.split("\n\n\n").blocks, [])
    }

    // MARK: - Reconstruction

    func testBlocksAndTailAlwaysReconstructTheInput() {
        let corpus = [
            "",
            "hello",
            "hello\n",
            "a\n\nb\n\nc",
            "# H\n\n- one\n- two\n\npara\n",
            "```\ncode\n\nmore\n```\n\nafter\n",
            "  indented\n\n    code block\n\n    still code\n\ntext\n",
            "> quote\n>\n> more\n\nafter it\n",
            "1. one\n\n2. two\n\n3. three\n",
            "\n\n\n",
            "text\n\n\n\nmore text\n",
            "~~~\nfenced\n\nwith blank\n~~~\n\ndone\n",
            "para\n\n-",
            "para\n\n- item\n"
        ]
        for input in corpus {
            let split = StreamingMarkdown.split(input)
            XCTAssertEqual(
                split.blocks.joined() + split.tail,
                input,
                "round trip lost or duplicated text for \(input.debugDescription)"
            )
        }
    }

    // MARK: - Prefix stability

    /// Replays a realistic reply one character at a time — the way the
    /// reveal queue actually delivers it — and asserts that no block ever
    /// changes, disappears, or reorders once emitted, and that every
    /// intermediate state still reconstructs exactly.
    ///
    /// The bare `-` at a boundary is the specific hazard this guards: it is
    /// not a list item until its space arrives, so a splitter that judged it
    /// immediately would close a block and then have to un-close it one
    /// character later, visibly re-flowing text already on screen.
    func testAlreadyEmittedBlocksNeverChangeAsMoreTextArrives() {
        let document = """
            # Report

            Here is a **summary** of what happened.

            - first item
            - second item

            ```swift
            let x = 1

            let y = 2
            ```

            1. one

            2. two

            Done.
            """

        var previous: [String] = []
        var mostBlocksSeen = 0
        for length in 0...document.count {
            let prefix = String(document.prefix(length))
            let split = StreamingMarkdown.split(prefix)

            XCTAssertGreaterThanOrEqual(
                split.blocks.count, previous.count,
                "a completed block was withdrawn at length \(length)"
            )
            for (index, block) in previous.enumerated() where index < split.blocks.count {
                XCTAssertEqual(
                    split.blocks[index], block,
                    "block \(index) changed after it was already rendered, at length \(length)"
                )
            }
            XCTAssertEqual(
                split.blocks.joined() + split.tail, prefix,
                "round trip failed at length \(length)"
            )

            previous = split.blocks
            mostBlocksSeen = max(mostBlocksSeen, split.blocks.count)
        }

        // The whole point is that this document formats progressively rather
        // than sitting in one plain-text tail until the reply ends.
        XCTAssertGreaterThanOrEqual(mostBlocksSeen, 4)
    }
}
