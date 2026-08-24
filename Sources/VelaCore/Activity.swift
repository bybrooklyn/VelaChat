import Foundation

/// What kind of work an activity line describes — drives the SF Symbol and
/// the present/past-tense phrasing in the transcript.
public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case webSearch, conversationSearch, fetchURL, fileRead, fileWrite, fileList
    case datetime, calculation, attachment, note
    case schedule, clipboard, mcp
    case memory, memorySave, memorySearch, memoryEdit
    case fileEdit, fileSearch, command, plan, subagent
    case systemStatus, imageAnalysis, dataQuery
    /// §9.1 `create_document` — a real .xlsx/.docx/.pptx/.pdf, not a text
    /// file. Distinct from `fileWrite` because the transcript treats the
    /// two differently: a document is opened by the app that owns its
    /// format, where a text file renders in the inspector.
    case document

    public static func from(toolName: String) -> ActivityKind {
        switch toolName {
        case ToolCatalog.webSearch.name: .webSearch
        case ToolCatalog.searchConversations.name: .conversationSearch
        case ToolCatalog.fetchURL.name: .fetchURL
        case ToolCatalog.readFile.name: .fileRead
        case ToolCatalog.writeFile.name: .fileWrite
        case ToolCatalog.listWorkspaceFiles.name: .fileList
        case ToolCatalog.editFile.name: .fileEdit
        case ToolCatalog.searchFiles.name: .fileSearch
        case ToolCatalog.queryData.name: .dataQuery
        case ToolCatalog.createDocument.name: .document
        case ToolCatalog.runCommand.name: .command
        case ToolCatalog.updatePlan.name: .plan
        case Subagents.definition.name: .subagent
        case "current_datetime": .datetime  // retired tool; old transcripts still map
        case ToolCatalog.calculator.name: .calculation
        case ToolCatalog.readAttachment.name: .attachment
        case ToolCatalog.getSchedule.name, ToolCatalog.createScheduleItem.name: .schedule
        case ToolCatalog.systemStatus.name: .systemStatus
        case ToolCatalog.analyzeImage.name: .imageAnalysis
        case ToolCatalog.readClipboard.name: .clipboard
        case let name where name.hasPrefix("mcp_"): .mcp
        case "save_memory": .memorySave
        case "search_memory": .memorySearch
        case "edit_memory": .memoryEdit
        default: .note
        }
    }

    /// Display form for an mcp_-prefixed label argument.
    public static func mcpDisplayName(_ argument: String) -> String {
        argument.isEmpty ? "an MCP tool" : "“\(argument)”"
    }

    public var symbol: String {
        switch self {
        case .webSearch: "globe"
        case .conversationSearch: "magnifyingglass"
        case .fetchURL: "doc.richtext"
        case .fileRead: "doc.text"
        case .fileWrite: "square.and.pencil"
        case .fileList: "folder"
        case .datetime: "clock"
        case .calculation: "plus.forwardslash.minus"
        case .attachment: "paperclip"
        case .schedule: "calendar"
        case .clipboard: "doc.on.clipboard"
        case .mcp: "puzzlepiece.extension"
        case .memory, .memorySave, .memorySearch, .memoryEdit: "brain"
        case .fileEdit: "pencil.and.outline"
        case .fileSearch: "text.magnifyingglass"
        case .command: "terminal"
        case .plan: "checklist"
        case .subagent: "person.2"
        case .systemStatus: "gauge.with.dots.needle.bottom.50percent"
        case .imageAnalysis: "text.viewfinder"
        case .dataQuery: "tablecells"
        // Not "doc.richtext" — that one is already fetchURL's.
        case .document: "doc.badge.plus"
        case .note: "info.circle"
        }
    }

    /// Present tense, shown while the call runs — "Searching the web".
    public func runningLabel(argument: String) -> String {
        let detail = argument.isEmpty ? "" : " for “\(argument)”"
        switch self {
        case .webSearch: return "Searching the web\(detail)"
        case .conversationSearch: return "Searching past conversations\(detail)"
        case .fetchURL: return "Reading \(argument.isEmpty ? "a page" : argument)"
        case .fileRead: return "Reading \(argument.isEmpty ? "a file" : argument)"
        case .fileWrite: return "Writing \(argument.isEmpty ? "a file" : argument)"
        case .fileList: return "Listing workspace files"
        case .datetime: return "Checking the time"
        case .calculation: return "Calculating"
        case .attachment: return "Reading \(argument.isEmpty ? "an attachment" : argument)"
        case .schedule: return "Checking the calendar"
        case .clipboard: return "Reading the clipboard"
        case .mcp: return "Using \(Self.mcpDisplayName(argument))"
        case .memory: return "Working with memory"
        case .memorySave: return "Saving a memory"
        case .memorySearch: return "Searching memory"
        case .memoryEdit: return "Updating memory"
        case .fileEdit: return "Editing \(argument.isEmpty ? "a file" : argument)"
        case .fileSearch: return "Searching files\(detail)"
        case .command: return "Running \(argument.isEmpty ? "a command" : "`\(argument)`")"
        case .plan: return "Planning"
        case .subagent: return "Running subagents"
        case .systemStatus: return "Checking this Mac"
        case .imageAnalysis: return "Reading \(argument.isEmpty ? "an image" : argument)"
        case .dataQuery: return "Querying the data"
        case .document: return "Creating \(argument.isEmpty ? "a document" : argument)"
        case .note: return argument
        }
    }

    /// Past tense, once the call finished — "Searched the web".
    public func finishedLabel(argument: String) -> String {
        let detail = argument.isEmpty ? "" : " for “\(argument)”"
        switch self {
        case .webSearch: return "Searched the web\(detail)"
        case .conversationSearch: return "Searched past conversations\(detail)"
        case .fetchURL: return "Read \(argument.isEmpty ? "a page" : argument)"
        case .fileRead: return "Read \(argument.isEmpty ? "a file" : argument)"
        case .fileWrite: return "Wrote \(argument.isEmpty ? "a file" : argument)"
        case .fileList: return "Listed workspace files"
        case .datetime: return "Checked the time"
        case .calculation: return "Calculated \(argument)"
        case .attachment: return "Read \(argument.isEmpty ? "an attachment" : argument)"
        case .schedule: return "Checked the calendar"
        case .clipboard: return "Read the clipboard"
        case .mcp: return "Used \(Self.mcpDisplayName(argument))"
        case .memory: return "Updated memory"
        case .memorySave: return "Saved a memory"
        case .memorySearch: return "Recalled from memory"
        case .memoryEdit: return "Updated a memory"
        case .fileEdit: return "Edited \(argument.isEmpty ? "a file" : argument)"
        case .fileSearch: return "Searched files\(detail)"
        case .command: return "Ran \(argument.isEmpty ? "a command" : "`\(argument)`")"
        case .plan: return "Updated the plan"
        case .subagent: return "Ran subagents"
        case .systemStatus: return "Checked this Mac"
        case .imageAnalysis: return "Read \(argument.isEmpty ? "an image" : argument)"
        case .dataQuery: return "Queried the data"
        case .document: return "Created \(argument.isEmpty ? "a document" : argument)"
        case .note: return argument
        }
    }

    /// The noun used when several calls of this kind collapse into one
    /// aggregated line — "Searched the web **3** times" reads worse than
    /// "Ran **3** web searches", so each kind names its own unit.
    public func aggregateUnit(count: Int) -> String {
        let plural = count == 1 ? "" : "s"
        switch self {
        case .webSearch: return "\(count) web search\(count == 1 ? "" : "es")"
        case .conversationSearch: return "\(count) conversation search\(count == 1 ? "" : "es")"
        case .fetchURL: return "read \(count) page\(plural)"
        case .fileRead: return "read \(count) file\(plural)"
        case .fileWrite: return "wrote \(count) file\(plural)"
        case .fileList: return "listed files"
        case .datetime: return "checked the time"
        case .calculation: return "\(count) calculation\(plural)"
        case .attachment: return "read \(count) attachment\(plural)"
        case .schedule: return "checked the calendar"
        case .clipboard: return "read the clipboard"
        case .mcp: return "\(count) MCP tool call\(plural)"
        case .memory, .memorySave, .memoryEdit: return "\(count) memory update\(plural)"
        case .memorySearch: return "\(count) memory lookup\(plural)"
        case .fileEdit: return "edited \(count) file\(plural)"
        case .fileSearch: return "\(count) file search\(count == 1 ? "" : "es")"
        case .command: return "ran \(count) command\(plural)"
        case .plan: return "planned \(count) step update\(plural)"
        case .subagent: return "\(count) subagent run\(plural)"
        case .systemStatus: return "checked this Mac"
        case .imageAnalysis: return "read \(count) image\(plural)"
        case .dataQuery: return "\(count) data quer\(count == 1 ? "y" : "ies")"
        case .document: return "created \(count) document\(plural)"
        case .note: return "\(count) note\(plural)"
        }
    }
}

/// One executed (or executing) tool call, as it appears in the transcript
/// timeline. `argument` is always the human-readable form (a query, a path)
/// — never raw JSON.
public struct ActivityRecord: Identifiable, Codable, Equatable, Sendable {

    public init(
        id: UUID = UUID(),
        kind: ActivityKind,
        toolName: String,
        argument: String,
        result: String = "",
        isError: Bool = false,
        isRunning: Bool = false,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.argument = argument
        self.result = result
        self.isError = isError
        self.isRunning = isRunning
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
    public var id: UUID = UUID()
    public var kind: ActivityKind
    public var toolName: String
    public var argument: String
    public var result: String = ""
    public var isError: Bool = false
    public var isRunning: Bool = false
    /// Wall-clock bounds of the call, stamped where the stream event
    /// actually arrived — not where the paced reveal drained it, which
    /// would report the typewriter's backlog as the tool's runtime.
    ///
    /// Both are optional on purpose. Transcripts saved before this field
    /// existed decode untouched, and a record missing either end renders no
    /// duration at all rather than an invented `0s`: an unobserved number is
    /// never implied.
    public var startedAt: Date?
    public var finishedAt: Date?

    /// How long the call took, or `nil` when either end wasn't observed.
    public var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        let elapsed = finishedAt.timeIntervalSince(startedAt)
        // A clock adjustment mid-call is the only way this goes negative,
        // and "-2.1s" is worse than saying nothing.
        return elapsed >= 0 ? elapsed : nil
    }

    /// `"0.4s"` / `"12s"` / `"1m 04s"` — sub-second precision only where it
    /// carries information, so a fast call doesn't read as "0s".
    public var durationLabel: String? {
        guard let duration else { return nil }
        if duration < 0.1 { return "<0.1s" }
        if duration < 10 { return String(format: "%.1fs", duration) }
        if duration < 60 { return "\(Int(duration.rounded()))s" }
        let total = Int(duration.rounded())
        return String(format: "%dm %02ds", total / 60, total % 60)
    }
}

/// How a whole reply's tool work reads as one line.
///
/// The transcript used to show a row per call, and the same fact could
/// appear four times over: the row label, the expanded label, the tool
/// result restating it, and the model's own prose saying it again. One
/// summary line per reply replaces that; this is the text on it, kept in
/// VelaCore so the phrasing is testable without a view.
public enum ActivitySummary {

    /// `"2 web searches · wrote 1 file"` — per-kind units in the order the
    /// kinds first appeared, which is the order the work happened in.
    /// Reuses each kind's own `aggregateUnit`, since "searched the web 3
    /// times" and "read 3 files" want different nouns.
    public static func label(for records: [ActivityRecord]) -> String {
        guard !records.isEmpty else { return "" }
        var order: [ActivityKind] = []
        var counts: [ActivityKind: Int] = [:]
        for record in records {
            if counts[record.kind] == nil { order.append(record.kind) }
            counts[record.kind, default: 0] += 1
        }
        var parts = order.map { kind in kind.aggregateUnit(count: counts[kind] ?? 0) }
        let failures = records.filter(\.isError).count
        if failures > 0 {
            parts.append("\(failures) failed")
        }
        let joined = parts.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Wall-clock span of the whole run — first start to last finish, not
    /// the sum, since calls can overlap.
    ///
    /// `nil` below a second: a reply that spent 40ms in a tool learns the
    /// reader nothing by saying so, and "<0.1s" on every row was most of
    /// what made the old presentation noisy. Also `nil` when either end
    /// went unobserved, so an old transcript never implies a number it
    /// doesn't have.
    public static func durationLabel(for records: [ActivityRecord]) -> String? {
        let starts = records.compactMap(\.startedAt)
        let finishes = records.compactMap(\.finishedAt)
        guard let first = starts.min(), let last = finishes.max() else { return nil }
        let elapsed = last.timeIntervalSince(first)
        guard elapsed >= 1 else { return nil }
        if elapsed < 60 { return "\(Int(elapsed.rounded()))s" }
        let total = Int(elapsed.rounded())
        return String(format: "%dm %02ds", total / 60, total % 60)
    }

    /// Whether an expanded row's result text still says something the label
    /// didn't. `write_file` answers "Wrote 956 bytes to notes.md" to a row
    /// already reading "Wrote notes.md" — printing both is how one action
    /// took three lines to report itself.
    public static func resultAddsInformation(_ result: String, beyond label: String) -> Bool {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Multi-line results are always worth showing: search hits, command
        // output, a query's table.
        guard !trimmed.contains("\n") else { return true }
        let normalize: (String) -> String = { text in
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        let normalizedResult = normalize(trimmed)
        let normalizedLabel = normalize(label)
        guard !normalizedLabel.isEmpty else { return true }
        // The label's words all present in a one-line result that is not
        // much longer than the label = the same sentence twice.
        let labelWords = normalizedLabel.split(separator: " ")
        let restates = labelWords.allSatisfy { normalizedResult.contains($0) }
        return !(restates && normalizedResult.count < normalizedLabel.count * 3)
    }
}

/// The ordered render timeline of an assistant message: text runs with
/// activity lines and reasoning between them, exactly where the model
/// paused to act or to think. `ChatMessage.content` stays the canonical
/// full text — the concatenation of the text segments always equals it —
/// and `ChatMessage.reasoning` relates to the reasoning segments the same
/// way.
public enum MessageSegment: Identifiable, Codable, Equatable {
    case text(id: UUID, content: String)
    /// A reasoning run, placed where the model actually thought. Reasoning
    /// used to render only as one block pinned above the whole message,
    /// which put a chain of thought produced *between* two tool rounds
    /// above the text it followed.
    case reasoning(id: UUID, content: String)
    case activity(ActivityRecord)

    public var id: UUID {
        switch self {
        case .text(let id, _): id
        case .reasoning(let id, _): id
        case .activity(let record): record.id
        }
    }

    private enum CodingKeys: String, CodingKey { case type, id, content, record }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "activity":
            self = .activity(try container.decode(ActivityRecord.self, forKey: .record))
        case "reasoning":
            self = .reasoning(
                id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                content: try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            )
        default:
            // Still a catch-all rather than a hard failure: an unknown type
            // written by a newer build degrades to a text run instead of
            // sinking the whole conversation's decode.
            self = .text(
                id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                content: try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let id, let content):
            try container.encode("text", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(content, forKey: .content)
        case .reasoning(let id, let content):
            try container.encode("reasoning", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(content, forKey: .content)
        case .activity(let record):
            try container.encode("activity", forKey: .type)
            try container.encode(record, forKey: .record)
        }
    }
}

public extension ChatMessage {
    /// Appends revealed text to both the canonical `content` and the
    /// trailing text segment, creating one if the timeline's tail is an
    /// activity (or empty).
    mutating func appendTimelineText(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        content += chunk
        if case .text(let id, let existing) = segments.last {
            segments[segments.count - 1] = .text(id: id, content: existing + chunk)
        } else {
            segments.append(.text(id: UUID(), content: chunk))
        }
    }

    /// The reasoning counterpart of `appendTimelineText`, with the same
    /// contract: `reasoning` stays the canonical concatenation, the trailing
    /// reasoning segment grows, and anything else at the tail (text, a tool
    /// call, nothing at all) starts a new one. Everything downstream that
    /// reads `reasoning` — export, alternates, the pre-segment fallback
    /// view — keeps working without knowing segments carry it now.
    mutating func appendTimelineReasoning(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        reasoning = (reasoning ?? "") + chunk
        if case .reasoning(let id, let existing) = segments.last {
            segments[segments.count - 1] = .reasoning(id: id, content: existing + chunk)
        } else {
            segments.append(.reasoning(id: UUID(), content: chunk))
        }
    }

    /// True once any reasoning sits on the timeline. The top-of-message
    /// reasoning block is the fallback for transcripts saved before that was
    /// possible, so it keys off this rather than off `reasoning` being
    /// non-empty — otherwise both would render the same chain twice.
    var hasTimelineReasoning: Bool {
        segments.contains { if case .reasoning = $0 { return true } else { return false } }
    }

    /// Every tool call on this message's timeline, in the order it ran.
    var activityRecords: [ActivityRecord] {
        segments.compactMap { if case .activity(let record) = $0 { return record } else { return nil } }
    }

    mutating func appendActivity(_ record: ActivityRecord) {
        segments.append(.activity(record))
    }

    mutating func updateActivity(id: UUID, result: String, isError: Bool, finishedAt: Date? = nil) {
        for index in segments.indices.reversed() {
            if case .activity(var record) = segments[index], record.id == id {
                record.result = result
                record.isError = isError
                record.isRunning = false
                record.finishedAt = finishedAt
                segments[index] = .activity(record)
                return
            }
        }
    }

    /// Flips any still-running activity to an interrupted error — used when
    /// restoring a session that died mid-stream.
    mutating func reconcileRunningActivities() {
        for index in segments.indices {
            if case .activity(var record) = segments[index], record.isRunning {
                record.isRunning = false
                record.isError = true
                record.result = "Interrupted."
                segments[index] = .activity(record)
            }
        }
    }
}
