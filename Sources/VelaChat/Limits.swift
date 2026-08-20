import Foundation

/// The app's operational limits, in one place.
///
/// These were spread across a dozen files as bare numbers — 4_096 here,
/// 8_000 there, three different request timeouts — which made two things
/// hard: knowing whether two limits were deliberately different or just
/// drifted apart, and changing any of them with confidence. Naming them
/// also documents what each one is protecting against.
enum Limits {
    // MARK: - Truncation

    /// A single tool result persisted into history. The model already saw
    /// the full text; this only bounds what gets stored and re-sent.
    static let toolResultBytes = 4_096
    /// Clipboard and schedule reads — enough to be useful, bounded so one
    /// enormous paste can't dominate the context.
    static let systemReadBytes = 8_192
    /// One subagent's returned report.
    static let subagentOutputBytes = 8_000
    /// A skill's body, and the total across all active skills.
    static let skillBodyBytes = 8_000
    static let skillTotalBytes = 20_000
    /// Command output surfaced to the model.
    static let commandOutputBytes = 20_000
    /// Conversation titles, and exported filenames derived from them.
    static let titleCharacters = 60

    /// An older round's tool result, as replayed into *later* rounds of
    /// the same reply. Distinct from `toolResultBytes` above, which bounds
    /// what gets stored: this bounds what gets re-sent and re-billed on
    /// every subsequent round. Generous enough that a condensed result
    /// still says what it found.
    static let replayedToolResultBytes = 1_024
    /// How many of the most recent tool rounds replay their results in
    /// full. Two, because the round just finished and the one before it are
    /// what the model is still actually reasoning over; anything older it
    /// has already folded into its plan.
    static let toolResultReplayRounds = 2

    /// Attachment bytes above this go to the blob store instead of into
    /// the conversation history (see `AttachmentStore`).
    static let inlineAttachmentBytes = 8_192

    // MARK: - Timeouts (seconds)

    /// Streaming requests: an idle timeout, reset by every received byte.
    /// Not a total budget — long replies are normal.
    /// How often a still-streaming reply is written to history, so a hard
    /// quit mid-stream doesn't lose the turn. Low enough to keep the loss
    /// window small, high enough that encoding every conversation doesn't
    /// compete with the stream itself.
    static let streamingPersistInterval: TimeInterval = 4

    static let streamIdleTimeout: TimeInterval = 180
    /// Ordinary JSON round trips.
    static let requestTimeout: TimeInterval = 60
    /// Auth and discovery calls, where waiting long is worse than failing.
    static let authTimeout: TimeInterval = 30
    /// Cheap probes whose failure is never fatal (quota headers, warm-up).
    static let probeTimeout: TimeInterval = 15
    /// One tool call. Bounds a hung tool without cutting off slow-but-real
    /// work like a large fetch.
    static let toolTimeout: TimeInterval = 120
    /// An MCP server's tools/list at send time — a dead server should cost
    /// seconds, not half a minute of stalled reply.
    static let mcpListTimeout: TimeInterval = 10

    // MARK: - Loops

    /// Tool-calling rounds per reply before the model is told to answer.
    ///
    /// Was 10, and a real reply hit that ceiling mid-task at 82,000 tokens.
    /// Raising it was only safe *after* the two changes that flattened the
    /// per-round cost — Anthropic prompt caching (`AnthropicPromptCache`)
    /// and condensed replay of older tool results (`ToolResultReplay`).
    /// Before those, every extra round re-sent and re-billed the entire
    /// growing exchange at full price, so a higher budget would have made
    /// the quadratic blow-up worse rather than buying more work done.
    static let maxToolRounds = 16
    /// Concurrent subagents.
    static let maxSubagents = 3
    /// Silent continuations after a provider truncates at its output cap.
    static let maxAutoContinues = 2
    /// Automatic retries for transient failures before the error surfaces.
    static let maxTransientRetries = 2

    // MARK: - Retry backoff (seconds)

    /// Delay before the first automatic retry. The old schedule was
    /// `attempt² * 2` (≈2s then ≈8s, ≈11s total for two retries) — long
    /// enough that a failing provider read as a hung app rather than one
    /// that was trying again. This is short enough that a human waits
    /// through it rather than assuming it's broken, while still giving a
    /// blip (a dropped packet, a momentary 503) a real chance to clear.
    static let transientRetryFirstDelay: TimeInterval = 1.0
    /// Delay before the second automatic retry — longer than the first
    /// because a failure that survived one retry is more likely to need
    /// real recovery time (e.g. a provider mid-restart), not just a blip.
    static let transientRetryFollowupDelay: TimeInterval = 3.0
    /// Random spread added to each retry delay so many concurrent tabs
    /// hitting the same flaky provider don't all retry in lockstep.
    static let transientRetryJitter: TimeInterval = 0.5
}
