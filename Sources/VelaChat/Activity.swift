import Foundation

/// What kind of work an activity line describes — drives the SF Symbol and
/// the present/past-tense phrasing in the transcript.
enum ActivityKind: String, Codable, Sendable {
    case webSearch, conversationSearch, fetchURL, fileRead, fileWrite, fileList
    case datetime, calculation, attachment, note
    case schedule, clipboard, mcp
    case memory, memorySave, memorySearch, memoryEdit
    case fileEdit, fileSearch, command, plan, subagent

    static func from(toolName: String) -> ActivityKind {
        switch toolName {
        case ToolCatalog.webSearch.name: .webSearch
        case ToolCatalog.searchConversations.name: .conversationSearch
        case ToolCatalog.fetchURL.name: .fetchURL
        case ToolCatalog.readFile.name: .fileRead
        case ToolCatalog.writeFile.name: .fileWrite
        case ToolCatalog.listWorkspaceFiles.name: .fileList
        case ToolCatalog.editFile.name: .fileEdit
        case ToolCatalog.searchFiles.name: .fileSearch
        case ToolCatalog.runCommand.name: .command
        case ToolCatalog.updatePlan.name: .plan
        case "spawn_agents": .subagent
        case "current_datetime": .datetime  // retired tool; old transcripts still map
        case ToolCatalog.calculator.name: .calculation
        case ToolCatalog.readAttachment.name: .attachment
        case ToolCatalog.getSchedule.name: .schedule
        case ToolCatalog.readClipboard.name: .clipboard
        case let name where name.hasPrefix("mcp_"): .mcp
        case "save_memory": .memorySave
        case "search_memory": .memorySearch
        case "edit_memory": .memoryEdit
        default: .note
        }
    }

    /// Display form for an mcp_-prefixed label argument.
    static func mcpDisplayName(_ argument: String) -> String {
        argument.isEmpty ? "an MCP tool" : "“\(argument)”"
    }

    var symbol: String {
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
        case .note: "info.circle"
        }
    }

    /// Present tense, shown while the call runs — "Searching the web".
    func runningLabel(argument: String) -> String {
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
        case .note: return argument
        }
    }

    /// Past tense, once the call finished — "Searched the web".
    func finishedLabel(argument: String) -> String {
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
        case .note: return argument
        }
    }

    /// The noun used when several calls of this kind collapse into one
    /// aggregated line — "Searched the web **3** times" reads worse than
    /// "Ran **3** web searches", so each kind names its own unit.
    func aggregateUnit(count: Int) -> String {
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
        case .note: return "\(count) note\(plural)"
        }
    }
}

/// One executed (or executing) tool call, as it appears in the transcript
/// timeline. `argument` is always the human-readable form (a query, a path)
/// — never raw JSON.
struct ActivityRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var kind: ActivityKind
    var toolName: String
    var argument: String
    var result: String = ""
    var isError: Bool = false
    var isRunning: Bool = false
}

/// The ordered render timeline of an assistant message: text runs with
/// activity lines between them, exactly where the model paused to act.
/// `ChatMessage.content` stays the canonical full text — the concatenation
/// of the text segments always equals it.
enum MessageSegment: Identifiable, Codable, Equatable {
    case text(id: UUID, content: String)
    case activity(ActivityRecord)

    var id: UUID {
        switch self {
        case .text(let id, _): id
        case .activity(let record): record.id
        }
    }

    private enum CodingKeys: String, CodingKey { case type, id, content, record }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "activity":
            self = .activity(try container.decode(ActivityRecord.self, forKey: .record))
        default:
            self = .text(
                id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                content: try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let id, let content):
            try container.encode("text", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(content, forKey: .content)
        case .activity(let record):
            try container.encode("activity", forKey: .type)
            try container.encode(record, forKey: .record)
        }
    }
}

extension ChatMessage {
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

    mutating func appendActivity(_ record: ActivityRecord) {
        segments.append(.activity(record))
    }

    mutating func updateActivity(id: UUID, result: String, isError: Bool) {
        for index in segments.indices.reversed() {
            if case .activity(var record) = segments[index], record.id == id {
                record.result = result
                record.isError = isError
                record.isRunning = false
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
