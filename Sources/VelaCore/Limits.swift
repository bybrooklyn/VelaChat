import Foundation

/// The app's operational limits, in one place.
///
/// These were spread across a dozen files as bare numbers — 4_096 here,
/// 8_000 there, three different request timeouts — which made two things
/// hard: knowing whether two limits were deliberately different or just
/// drifted apart, and changing any of them with confidence. Naming them
/// also documents what each one is protecting against.
public enum Limits {
    // MARK: - Truncation

    /// A single tool result persisted into history. The model already saw
    /// the full text; this only bounds what gets stored and re-sent.
    public static let toolResultBytes = 4_096
    /// Clipboard and schedule reads — enough to be useful, bounded so one
    /// enormous paste can't dominate the context.
    public static let systemReadBytes = 8_192
    /// One subagent's returned report.
    public static let subagentOutputBytes = 8_000
    /// A skill's body, and the total across all active skills.
    public static let skillBodyBytes = 8_000
    public static let skillTotalBytes = 20_000
    /// Command output surfaced to the model.
    public static let commandOutputBytes = 20_000
    /// Remembered run_command prefix rules (and denials) kept per attached
    /// folder. A ceiling, not a target: this list is written one deliberate
    /// button press at a time, and an unbounded one would grow forever in
    /// preferences.
    public static let commandRulesPerFolder = 50
    /// Conversation titles, and exported filenames derived from them.
    public static let titleCharacters = 60
    /// One stored memory. A durable fact about a person is a sentence;
    /// anything past this is a summary of a conversation wearing a fact's
    /// clothes, and `MemoryCapture` refuses it rather than truncating —
    /// half a fact is worse than none.
    public static let memoryFactCharacters = 240

    /// An older round's tool result, as replayed into *later* rounds of
    /// the same reply. Distinct from `toolResultBytes` above, which bounds
    /// what gets stored: this bounds what gets re-sent and re-billed on
    /// every subsequent round. Generous enough that a condensed result
    /// still says what it found.
    public static let replayedToolResultBytes = 1_024
    /// How many of the most recent tool rounds replay their results in
    /// full. Two, because the round just finished and the one before it are
    /// what the model is still actually reasoning over; anything older it
    /// has already folded into its plan.
    public static let toolResultReplayRounds = 2

    /// Attachment bytes above this go to the blob store instead of into
    /// the conversation history (see `AttachmentStore`).
    public static let inlineAttachmentBytes = 8_192

    // MARK: - Timeouts (seconds)

    /// Streaming requests: an idle timeout, reset by every received byte.
    /// Not a total budget — long replies are normal.
    /// How often a still-streaming reply is written to history, so a hard
    /// quit mid-stream doesn't lose the turn. Low enough to keep the loss
    /// window small, high enough that encoding every conversation doesn't
    /// compete with the stream itself.
    public static let streamingPersistInterval: TimeInterval = 4

    public static let streamIdleTimeout: TimeInterval = 180
    /// Ordinary JSON round trips.
    public static let requestTimeout: TimeInterval = 60
    /// Auth and discovery calls, where waiting long is worse than failing.
    public static let authTimeout: TimeInterval = 30
    /// Cheap probes whose failure is never fatal (quota headers, warm-up).
    public static let probeTimeout: TimeInterval = 15
    /// One tool call. Bounds a hung tool without cutting off slow-but-real
    /// work like a large fetch.
    public static let toolTimeout: TimeInterval = 120
    /// An MCP server's tools/list at send time — a dead server should cost
    /// seconds, not half a minute of stalled reply.
    public static let mcpListTimeout: TimeInterval = 10

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
    public static let maxToolRounds = 16
    /// Concurrent subagents.
    public static let maxSubagents = 3
    /// Silent continuations after a provider truncates at its output cap.
    public static let maxAutoContinues = 2
    /// Automatic retries for transient failures before the error surfaces.
    public static let maxTransientRetries = 2

    // MARK: - Retry backoff (seconds)

    /// Delay before the first automatic retry. The old schedule was
    /// `attempt² * 2` (≈2s then ≈8s, ≈11s total for two retries) — long
    /// enough that a failing provider read as a hung app rather than one
    /// that was trying again. This is short enough that a human waits
    /// through it rather than assuming it's broken, while still giving a
    /// blip (a dropped packet, a momentary 503) a real chance to clear.
    public static let transientRetryFirstDelay: TimeInterval = 1.0
    /// Delay before the second automatic retry — longer than the first
    /// because a failure that survived one retry is more likely to need
    /// real recovery time (e.g. a provider mid-restart), not just a blip.
    public static let transientRetryFollowupDelay: TimeInterval = 3.0
    /// Random spread added to each retry delay so many concurrent tabs
    /// hitting the same flaky provider don't all retry in lockstep.
    public static let transientRetryJitter: TimeInterval = 0.5
    /// A subscription plan window exhausted mid-reply queues the turn until
    /// the provider's own reset moment — but never longer than this. Past
    /// it, silently sleeping would be worse than reporting the failure and
    /// letting the user decide.
    public static let quotaWindowResumeMaxDelay: TimeInterval = 6 * 3_600
    /// The bridge's own permission timeout. An unanswered control request
    /// hangs `claude` indefinitely (verified: >75s with no self-cancel), so
    /// the HOST imposes the deadline and auto-denies with a message.
    public static let claudePermissionTimeout: TimeInterval = 120

    // MARK: - Generated documents (§9.1)

    /// `create_document`: cells across all sheets of one workbook, and
    /// slides in one deck. Both are "far past anything a legitimate ask
    /// produces" ceilings that stop a runaway model from emitting an
    /// enormous file into the workspace, not targets.
    public static let documentMaxCells = 100_000
    public static let documentMaxSlides = 60

    // MARK: - Data analysis (§9.2)

    /// Rows one `query_data` call returns. The result is read by a model
    /// and rendered as a table, and both stop learning anything new well
    /// before this — a query that wants more rows than this wants an
    /// aggregate instead, which is what the truncation notice says.
    public static let dataQueryRows = 200
    /// Rows loaded from one attached source. A ceiling against a runaway
    /// file, not a target: the in-memory database holds every loaded row.
    public static let dataMaxRowsLoaded = 250_000
    /// Bytes of one attached data file. Well past a spreadsheet a person
    /// made, well short of something that would be loaded into memory
    /// twice (raw bytes plus parsed rows) at a cost the app would feel.
    public static let dataSourceBytes = 25_000_000
    /// Real rows shown per table in the schema handed to the model —
    /// enough to see the shape of the values, not enough to be the data.
    public static let dataSampleRows = 3
    /// One query's wall-clock budget, enforced by SQLite's own progress
    /// handler. Deliberately far below `toolTimeout`: a query this slow is
    /// a query to rewrite, and the model gets told so while there is still
    /// time in the round to do it.
    public static let dataQueryTimeout: TimeInterval = 15
}
