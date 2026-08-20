import Foundation

/// Cache breakpoint placement for Anthropic's `/v1/messages`.
///
/// A tool-using reply resends the entire conversation on every round, so
/// an eight-round reply pays for the transcript eight times over. Prompt
/// caching is the fix: the unchanged prefix bills at 0.1× on a read
/// instead of 1× fresh.
///
/// Two hard constraints from Anthropic's documentation shape this:
///
/// 1. **At most four blocks in a request may carry `cache_control`**, and
///    that budget is shared across `system`, `tools` and `messages`
///    combined. A fifth is an HTTP 400, not a degraded response — so the
///    count is asserted here rather than hoped for.
/// 2. **A breakpoint only looks about 20 content blocks behind itself**
///    for a hit. A marker parked at the head of a long tool loop therefore
///    stops matching once enough rounds pile up behind it, and silently
///    stops earning anything.
///
/// So: exactly two, never more. One on the system block, which also covers
/// `tools` because those are rendered ahead of it in Anthropic's own
/// request order — one marker for the whole static head, not one per
/// section. One that *moves*, re-placed on the newest turn before every
/// round, which is what keeps it inside the 20-block lookback as the loop
/// grows. Two leaves headroom under the limit of four; it is not an
/// accident that it is not four.
enum AnthropicPromptCache {
    /// Anthropic's hard cap, counted across system + tools + messages.
    static let maxBreakpoints = 4

    /// What this app actually places: the static head, and the moving
    /// marker on the newest turn.
    static let breakpointsUsed = 2

    static let control: [String: Any] = ["type": "ephemeral"]

    /// Re-places the moving breakpoint on the last content block of the
    /// last turn, removing any previous one first.
    ///
    /// Stripping before adding is the whole reason the count can't drift:
    /// the turns array only ever holds one marker, no matter how many
    /// rounds have appended to it.
    static func markLatestTurn(_ turns: inout [[String: Any]]) {
        stripBreakpoints(&turns)
        guard let lastIndex = turns.indices.last else { return }
        var turn = turns[lastIndex]

        // `content` is either a plain string (the common text turn) or an
        // array of blocks (anything with images or tool results). Only a
        // block can carry `cache_control`, so a string turn is promoted to
        // a single text block — a shape Anthropic accepts identically.
        var blocks: [[String: Any]]
        if let existing = turn["content"] as? [[String: Any]] {
            blocks = existing
        } else if let text = turn["content"] as? String, !text.isEmpty {
            blocks = [["type": "text", "text": text]]
        } else {
            return
        }
        guard let blockIndex = blocks.indices.last else { return }
        blocks[blockIndex]["cache_control"] = control
        turn["content"] = blocks
        turns[lastIndex] = turn
    }

    /// Removes every `cache_control` in the turns array.
    static func stripBreakpoints(_ turns: inout [[String: Any]]) {
        for index in turns.indices {
            guard var blocks = turns[index]["content"] as? [[String: Any]] else { continue }
            var changed = false
            for blockIndex in blocks.indices where blocks[blockIndex]["cache_control"] != nil {
                blocks[blockIndex].removeValue(forKey: "cache_control")
                changed = true
            }
            if changed { turns[index]["content"] = blocks }
        }
    }

    /// Every `cache_control` in a finished request body, counted the way
    /// Anthropic counts them: across `system`, `tools` and `messages`
    /// together. The whole point of a single traversal is that a future
    /// breakpoint added in any of the three sections shows up here.
    static func breakpointCount(inBody body: [String: Any]) -> Int {
        ["system", "tools", "messages"].reduce(0) { $0 + count(in: body[$1]) }
    }

    private static func count(in value: Any?) -> Int {
        switch value {
        case let dictionary as [String: Any]:
            var total = dictionary["cache_control"] != nil ? 1 : 0
            for (key, nested) in dictionary where key != "cache_control" {
                total += count(in: nested)
            }
            return total
        case let array as [Any]:
            return array.reduce(0) { $0 + count(in: $1) }
        default:
            return 0
        }
    }
}

/// How much of an older round's tool result gets replayed into later
/// rounds of the same reply.
///
/// Every round of a tool loop resends the whole exchange, so a 40 KB page
/// fetch in round 2 is paid for again in rounds 3 through 10. That is the
/// quadratic term behind an 82,000-token reply that never even finished
/// its work.
///
/// The model has already *seen* every one of those results in full, at the
/// round where it asked for them; what later rounds need is enough to
/// remember what happened, not the bytes again. Recent rounds stay
/// verbatim because those are the ones still being reasoned about.
///
/// Nothing is ever shortened invisibly: a condensed result carries an
/// explicit marker naming the original size, so the model can tell the
/// difference between "this tool returned little" and "this was trimmed",
/// and can re-run the call if it genuinely needs the rest.
///
/// There is a real tension with prompt caching, and it is deliberate:
/// rewriting a turn in the middle of the history invalidates every cached
/// block after it, so the cache hit shrinks to "everything older than the
/// rounds still being condensed". That trade is worth taking — a cache
/// read still costs 0.1× of a large result on every remaining round,
/// whereas condensing removes those bytes outright and permanently. The
/// stable head (system prompt, tool schemas, the original conversation) is
/// never touched, so the largest cacheable chunk keeps hitting either way.
/// Each result is condensed exactly once, so the rewrite is not a moving
/// target that could thrash the cache round after round.
enum ToolResultReplay {
    /// True when a result produced in `round` should be condensed for a
    /// request being built for `currentRound`.
    static func shouldCondense(round: Int, currentRound: Int) -> Bool {
        currentRound - round > Limits.toolResultReplayRounds
    }

    /// The short form of a result, or the result unchanged when it is
    /// already small enough to be cheap.
    static func condensed(_ result: String) -> String {
        let bytes = result.utf8.count
        guard bytes > Limits.replayedToolResultBytes else { return result }
        return head(of: result, bytes: Limits.replayedToolResultBytes)
            + "\n\n[earlier result truncated, \(bytes) bytes]"
    }

    /// A byte-bounded prefix that never splits a character — truncating
    /// the UTF-8 view directly would hand the provider a replacement
    /// character in the middle of any non-ASCII result.
    private static func head(of text: String, bytes limit: Int) -> String {
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let size = String(text[index]).utf8.count
            if used + size > limit { break }
            used += size
            end = text.index(after: index)
        }
        return String(text[text.startIndex..<end])
    }
}
