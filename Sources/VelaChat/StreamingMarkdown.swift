import Foundation

/// Splits a still-arriving reply into the Markdown blocks that are already
/// settled and the one trailing block that is not.
///
/// Why this exists: the transcript used to render the whole streaming tail
/// as plain `Text` and only became Markdown once the reply finished, because
/// handing the entire growing string to `Markdown(_:)` on every reveal tick
/// re-parsed the full document ~30 times a second and was the single biggest
/// source of streaming lag. Deleting that guard outright brings the lag back.
///
/// The middle ground is a stable prefix. A block ends at a blank line, so
/// everything before the last blank line can never change again no matter
/// what arrives next — it can be parsed **once**, kept, and reused. Only the
/// trailing fragment stays plain text. Re-parsing then costs once per
/// completed block instead of once per token, and the finish-time swap to
/// full Markdown is nearly invisible because most of the reply is already
/// formatted.
///
/// Two properties this must never break, both pinned by tests:
///
/// 1. **Exact reconstruction.** `blocks.joined() + tail == input`, always.
///    Anything else silently drops or duplicates the user's text.
/// 2. **Prefix stability.** Once a block is emitted, appending more input
///    never changes it, splits it differently, or reorders it. That is what
///    lets the view identify blocks by index and lets SwiftUI rebuild only
///    the newly completed one.
///
/// Stability is why two rules look more conservative than they need to: a
/// blank line inside an open code fence is not a boundary at all (otherwise
/// a half-written fence flickers as garbage mid-stream), and a boundary
/// whose following line is a half-typed list marker waits one tick (a bare
/// `-` becomes a list item the moment its space arrives, which would
/// retroactively un-split a block already on screen).
enum StreamingMarkdown {
    struct Split: Equatable {
        /// Settled blocks, in order, each still carrying its own trailing
        /// blank line(s) so concatenation reproduces the input byte for byte.
        var blocks: [String]
        /// The still-growing fragment. Renders as plain text.
        var tail: String
    }

    static func split(_ text: String) -> Split {
        guard !text.isEmpty else { return Split(blocks: [], tail: "") }

        var blocks: [String] = []
        var current = ""
        /// The fence character and run length that opened the code block we
        /// are inside, or `nil` outside one. CommonMark closes a fence with
        /// the same character and *at least* as many of them.
        var openFence: (character: Character, count: Int)?
        /// A blank line has been seen outside a fence; the next real line
        /// decides whether it was a block boundary or a loose-list gap.
        var pendingBoundary = false

        func closeCurrent() {
            // A whitespace-only accumulation isn't a block — it belongs to
            // the front of whatever comes next, so it keeps accumulating.
            guard current.contains(where: { !$0.isWhitespace }) else { return }
            blocks.append(current)
            current = ""
        }

        for line in lines(of: text) {
            let body = line.body

            if let fence = openFence {
                current += line.raw
                if closesFence(body, fence) { openFence = nil }
                continue
            }

            if body.trimmingCharacters(in: .whitespaces).isEmpty {
                current += line.raw
                pendingBoundary = true
                continue
            }

            if pendingBoundary {
                // A half-typed line whose next character could turn it into
                // a list marker ("-" becoming "- item") would answer
                // `continuesBlock` differently one tick later, retroactively
                // un-splitting a block that was already on screen. That is
                // the only way the judgement below is not yet final, so it
                // is the only case that waits.
                let undecided = !line.isTerminated && mayBecomeListItem(body)
                if !undecided {
                    pendingBoundary = false
                    if !continuesBlock(current, next: body) { closeCurrent() }
                }
            }

            if let fence = openingFence(body) { openFence = fence }
            current += line.raw
        }

        return Split(blocks: blocks, tail: current)
    }

    // MARK: - Line scanning

    private struct Line {
        /// The line including its terminator, so the pieces re-join exactly.
        let raw: String
        /// The line without its terminator.
        let body: String
        let isTerminated: Bool
    }

    /// Newline-preserving line split. `String.components(separatedBy:)`
    /// loses which lines were terminated, and that distinction is exactly
    /// what keeps the split stable across ticks.
    private static func lines(of text: String) -> [Line] {
        var result: [Line] = []
        var body = ""
        for character in text {
            if character == "\n" {
                result.append(Line(raw: body + "\n", body: body, isTerminated: true))
                body = ""
            } else {
                body.append(character)
            }
        }
        if !body.isEmpty {
            result.append(Line(raw: body, body: body, isTerminated: false))
        }
        return result
    }

    // MARK: - Fences

    /// The fence a line opens, if it opens one. Up to three leading spaces
    /// are allowed before the run, per CommonMark.
    private static func openingFence(_ body: String) -> (character: Character, count: Int)? {
        let indent = leadingSpaces(body)
        guard indent <= 3 else { return nil }
        let rest = body.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let count = rest.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        // A backtick fence's info string may not itself contain a backtick
        // — that's how ```` ``code`` ```` inline spans stay inline.
        if marker == "`", rest.dropFirst(count).contains("`") { return nil }
        return (marker, count)
    }

    private static func closesFence(_ body: String, _ fence: (character: Character, count: Int)) -> Bool {
        let indent = leadingSpaces(body)
        guard indent <= 3 else { return false }
        let rest = body.dropFirst(indent)
        let run = rest.prefix { $0 == fence.character }.count
        guard run >= fence.count else { return false }
        // A closing fence carries nothing but the run itself.
        return rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - Boundary judgement

    /// Whether the line after a blank line continues the block before it
    /// rather than starting a new one.
    ///
    /// Loose lists are the case that matters: a list whose items are
    /// separated by blank lines is *one* list in Markdown, and splitting it
    /// at every gap would render a run of single-item lists mid-stream and
    /// then re-flow into one list at the end — the exact layout jump this
    /// whole design exists to avoid. Indented code blocks and blockquotes
    /// have the same shape.
    private static func continuesBlock(_ current: String, next: String) -> Bool {
        guard let last = lastNonBlankLine(of: current) else { return false }
        let nextIndent = leadingSpaces(next)

        if isListItem(last) || leadingSpaces(last) >= 2 {
            // A following list item, or anything indented under one.
            if isListItem(next) || nextIndent >= 2 { return true }
        }
        // Indented (four-space) code keeps its blank lines.
        if leadingSpaces(last) >= 4, nextIndent >= 4 { return true }
        // A blockquote survives a blank line between its paragraphs.
        if last.drop(while: { $0 == " " }).first == ">", next.drop(while: { $0 == " " }).first == ">" {
            return true
        }
        return false
    }

    private static func isListItem(_ body: String) -> Bool {
        var rest = Substring(body).drop { $0 == " " || $0 == "\t" }
        guard let marker = rest.first else { return false }
        if marker == "-" || marker == "*" || marker == "+" {
            rest = rest.dropFirst()
        } else if marker.isNumber {
            let digits = rest.prefix { $0.isNumber }
            rest = rest.dropFirst(digits.count)
            guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return false }
            rest = rest.dropFirst()
        } else {
            return false
        }
        // The marker must be followed by whitespace — "-" alone is a line of
        // prose (or a half-typed marker), not a list item.
        guard let following = rest.first else { return false }
        return following == " " || following == "\t"
    }

    /// Whether a not-yet-terminated line is a possible prefix of a list
    /// item — `-`, `*`, `+`, `3`, `3.` — and so could still flip
    /// `isListItem` when its next character lands. Everything else about a
    /// non-blank line (its indent, a leading `>`) is already settled by its
    /// first non-space character, so nothing else needs to wait.
    private static func mayBecomeListItem(_ body: String) -> Bool {
        guard !isListItem(body) else { return false }
        var rest = Substring(body).drop { $0 == " " || $0 == "\t" }
        guard let marker = rest.first else { return false }
        if marker == "-" || marker == "*" || marker == "+" {
            return rest.count == 1
        }
        guard marker.isNumber else { return false }
        rest = rest.drop { $0.isNumber }
        if rest.isEmpty { return true }
        return rest.count == 1 && (rest.first == "." || rest.first == ")")
    }

    private static func lastNonBlankLine(of text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { return String(line) }
        }
        return nil
    }

    private static func leadingSpaces(_ body: String) -> Int {
        var count = 0
        for character in body {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }
}
