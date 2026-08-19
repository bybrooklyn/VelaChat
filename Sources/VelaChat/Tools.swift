import Foundation

/// Real tool calling, not the pre-fetch trick the old "web search" used —
/// tool definitions go in the request, the model decides whether to call
/// one, VelaChat executes it locally and feeds the result back, looping
/// until the model has enough to answer for real. The loop lives entirely
/// inside `CompatibleChatClient`'s streaming functions (see
/// `streamChat`/`streamAnthropic` in ChatAPI.swift) — callers just see a
/// normal event stream plus `.toolUse` events for UI transparency, never
/// the raw multi-round exchange.
enum ToolCatalog {
    struct Definition {
        let name: String
        /// Goes on the wire as the tool's description — written for the
        /// model, rich enough that it knows when and how to use the tool.
        let description: String
        /// A JSON Schema `properties` object, hand-built per tool rather
        /// than reflected from Swift types — a tiny hand-written schema is
        /// far less risk than a general schema generator for this scope.
        let parametersJSON: String
        /// One line for the system-prompt tool inventory.
        let summary: String
        /// Usage guidance for the inventory — when to reach for it, when
        /// not to, what comes back.
        let guidance: String
    }

    static let searchConversations = Definition(
        name: "search_conversations",
        description: "Search the user's past conversations in this app for relevant context — names, decisions, preferences, or details mentioned before. Returns only matching excerpts with conversation titles, never whole transcripts. Case-insensitive substring match.",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"A short, specific phrase to search for — a name, project, or keyword. Prefer several narrow searches over one broad one."}},"required":["query"]}"#,
        summary: "search the user's past conversations in this app",
        guidance: "Use when the user references something from before (\"like we discussed\", a name or project you don't know). Prefer several narrow queries over one broad one. Returns up to 8 excerpts."
    )

    static let webSearch = Definition(
        name: "web_search",
        description: "Search the live web. Returns real results with titles, URLs, and snippets. Use for anything after your knowledge cutoff: current events, prices, versions, releases, weather, scores. Issue multiple targeted searches rather than one broad one, and cite result URLs in your answer.",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"The search query — specific and keyword-focused, like a good search-engine query"}},"required":["query"]}"#,
        summary: "search the live web",
        guidance: "You DO have live web access through this tool. Use it for anything recent or uncertain instead of claiming you cannot browse. Follow up promising results with fetch_url to read the page."
    )

    static let fetchURL = Definition(
        name: "fetch_url",
        description: "Fetch a web page and return its readable text content (HTML stripped, truncated if very long). Use after web_search to actually read a promising result, or when the user gives you a URL.",
        parametersJSON: #"{"type":"object","properties":{"url":{"type":"string","description":"The full http(s) URL to fetch"}},"required":["url"]}"#,
        summary: "read the text content of a web page",
        guidance: "Search results only give snippets — fetch the page when you need the substance. Quote or summarize what you actually read, citing the URL."
    )

    // current_datetime was retired: the system prompt's Environment
    // section stamps the live date/time on every request, which is both
    // cheaper and always present. (ActivityKind.datetime remains so old
    // transcripts still render their activity lines.)

    static let calculator = Definition(
        name: "calculator",
        description: "Evaluate an arithmetic expression exactly: + - * / ^ %, parentheses, decimal numbers. Use for any nontrivial arithmetic instead of computing it in your head.",
        parametersJSON: #"{"type":"object","properties":{"expression":{"type":"string","description":"The expression, e.g. \"(1234.5 * 12) / 7\""}},"required":["expression"]}"#,
        summary: "evaluate arithmetic exactly",
        guidance: "Mental arithmetic on large or precise numbers is error-prone — use this instead. Numbers only; no variables or units."
    )

    static let readAttachment = Definition(
        name: "read_attachment",
        description: "Read the full text of a file the user attached to this conversation, by filename. Attached files may have been truncated in the prompt — this returns the complete content.",
        parametersJSON: #"{"type":"object","properties":{"filename":{"type":"string","description":"The attachment's filename as shown in the conversation"}},"required":["filename"]}"#,
        summary: "read the full content of an attached file",
        guidance: "If an attachment looks cut off in the prompt, fetch the whole thing here before answering questions about it."
    )

    /// A real, private, per-conversation folder on disk — not a general
    /// filesystem. See `SandboxManager` for the actual safety boundary
    /// (path validation, not process sandboxing) and why a shell-execution
    /// tool isn't offered alongside these.
    static let writeFile = Definition(
        name: "write_file",
        description: "Write a text file into this conversation's private workspace folder (a real, isolated folder on disk, separate for every conversation). Overwrites the file if it already exists. Use relative paths only.",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Relative path within the workspace, e.g. \"notes.txt\" or \"src/main.py\""},"content":{"type":"string","description":"The full file content to write"}},"required":["path","content"]}"#,
        summary: "write a file in this conversation's private workspace",
        guidance: "Good for drafts, code, and notes the user may want to keep — the user can reveal the folder in Finder. Relative paths only; writes overwrite."
    )
    static let readFile = Definition(
        name: "read_file",
        description: "Read a text file from this conversation's private workspace folder.",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Relative path within the workspace"}},"required":["path"]}"#,
        summary: "read a file from the private workspace",
        guidance: "Use list_workspace_files first if unsure what exists."
    )
    static let listWorkspaceFiles = Definition(
        name: "list_workspace_files",
        description: "List the files currently in this conversation's private workspace folder.",
        parametersJSON: #"{"type":"object","properties":{}}"#,
        summary: "list the private workspace's files",
        guidance: "Cheap — call it rather than guessing filenames."
    )

    static let editFile = Definition(
        name: "edit_file",
        description: "Replace an exact substring in a workspace file with new text — the surgical way to iterate on a file instead of rewriting it whole. The old_string must match the file exactly once (include enough surrounding context to be unique), unless replace_all is true.",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative file path"},"old_string":{"type":"string","description":"Exact text to find"},"new_string":{"type":"string","description":"Replacement text"},"replace_all":{"type":"boolean","description":"Replace every occurrence (default false)"}},"required":["path","old_string","new_string"]}"#,
        summary: "make a surgical find/replace edit in a workspace file",
        guidance: "Prefer this over write_file when changing part of an existing file. If old_string isn't unique, add surrounding lines until it is."
    )
    static let searchFiles = Definition(
        name: "search_files",
        description: "Search the workspace for files by name pattern and/or content. glob filters filenames (e.g. \"*.swift\"); query is a regular expression matched against file contents. Returns matching paths with line numbers for content matches.",
        parametersJSON: #"{"type":"object","properties":{"glob":{"type":"string","description":"Filename glob, e.g. \"*.md\" or \"src/*.ts\""},"query":{"type":"string","description":"Regex to search file contents for"}}}"#,
        summary: "find workspace files by name pattern and/or content",
        guidance: "Use before editing a codebase you didn't create — locate the right file instead of guessing paths."
    )
    static let runCommand = Definition(
        name: "run_command",
        description: "Run a shell command in the conversation's workspace directory and get its stdout/stderr and exit code. Read-only commands run immediately; anything that could modify the system pauses for the user's approval. Use for building, testing, git, and inspecting a real project.",
        parametersJSON: #"{"type":"object","properties":{"command":{"type":"string","description":"The exact shell command to run"}},"required":["command"]}"#,
        summary: "run a shell command in the workspace",
        guidance: "Prefer rg over grep and small, composable commands. The user may deny a command — if so, read their reason and adapt. Never assume a command ran; check the exit code in the result."
    )
    static let updatePlan = Definition(
        name: "update_plan",
        description: "Maintain a visible step-by-step plan for a multi-step task. Each step is a short phrase (5-7 words) with a status: pending, in_progress, or completed. Keep exactly one step in_progress until everything is done. Call again to advance the plan as you work.",
        parametersJSON: #"{"type":"object","properties":{"steps":{"type":"array","items":{"type":"object","properties":{"step":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["step","status"]}}},"required":["steps"]}"#,
        summary: "post or update the task plan",
        guidance: "Only for genuinely multi-step work — never pad a simple task with a plan. Update it as steps complete so the user can follow along."
    )

    static let getSchedule = Definition(
        name: "get_schedule",
        description: "Read the user's upcoming calendar events and open reminders (read-only, from the system Calendar and Reminders). The first call may trigger a one-time system permission prompt.",
        parametersJSON: #"{"type":"object","properties":{"days":{"type":"integer","description":"How many days ahead to look, 1-7 (default 7)"}}}"#,
        summary: "read the user's upcoming calendar events and reminders",
        guidance: "Use for anything about the user's schedule, availability, or todos. If access was denied, relay that honestly instead of guessing."
    )
    static let readClipboard = Definition(
        name: "read_clipboard",
        description: "Read the user's current clipboard (text or file names). Use when they reference what they just copied.",
        parametersJSON: #"{"type":"object","properties":{}}"#,
        summary: "read the current clipboard",
        guidance: "\"What do you think of this?\" right after a copy usually means the clipboard — read it instead of asking them to paste."
    )

    static let saveMemory = Definition(
        name: "save_memory",
        description: "Save a durable fact about the user to your persistent memory — it will be available in every future conversation. One short, standalone sentence per call, with a topic for grouping (reuse existing topics from search_memory when one fits).",
        parametersJSON: #"{"type":"object","properties":{"content":{"type":"string","description":"The fact, as one short standalone sentence"},"topic":{"type":"string","description":"A short grouping topic, e.g. a project name, \"Preferences\", \"Work\""}},"required":["content","topic"]}"#,
        summary: "save a durable fact to your persistent cross-conversation memory",
        guidance: "Save preferences, recurring projects, and facts the user states about themselves — proactively, without asking. Never save secrets, credentials, or trivia only relevant right now."
    )
    static let searchMemory = Definition(
        name: "search_memory",
        description: "Search your persistent memory for stored facts. Returns matching memories with their ids and topics — the id is what edit_memory needs.",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"A word or phrase to look for; empty returns the most recent memories"}},"required":["query"]}"#,
        summary: "search your persistent memory",
        guidance: "The prompt only carries the memories that look relevant — search before assuming you don't know something about the user."
    )
    static let editMemory = Definition(
        name: "edit_memory",
        description: "Update or delete one stored memory by id (get ids from search_memory). Use when a stored fact becomes wrong or obsolete.",
        parametersJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"The memory's id, from search_memory"},"action":{"type":"string","enum":["update","delete"]},"content":{"type":"string","description":"Replacement text (update only)"},"topic":{"type":"string","description":"Replacement topic (update only)"}},"required":["id","action"]}"#,
        summary: "update or delete a stored memory",
        guidance: "Keep memory truthful: when the user corrects something you had saved, update it rather than saving a contradicting duplicate."
    )



    /// What a tool call actually needs at execution time — read-only
    /// snapshots, not a live reference to `AppModel` (this runs from
    /// `CompatibleChatClient`, which has no knowledge of `AppModel`).
    struct ExecutionContext: Sendable {
        let conversationSummaries: [ConversationSearchSummary]
        let searchEndpoint: String
        let workspaceDirectory: URL
        /// Full text of the conversation's text-bearing attachments, keyed
        /// by filename — what `read_attachment` serves.
        var attachmentTexts: [String: String] = [:]
        /// The memory tools' window into `AppModel.memories` — a read
        /// snapshot plus a MainActor-hopping mutator.
        var memory: MemoryAccess? = nil
        /// System capabilities, injected as MainActor-hopping closures so
        /// EventKit/NSPasteboard stay out of this Sendable context. nil =
        /// disabled in Settings.
        var schedule: (@Sendable (Int) async -> String)? = nil
        var clipboard: (@Sendable () async -> String)? = nil
        /// Routes mcp_-prefixed tool names to the MCP manager.
        var mcpCall: (@Sendable (String, String) async -> String)? = nil
        /// run_command approval + execution, injected only when the agent
        /// abilities are enabled. Returns the command's combined output (or
        /// an "Error:"/denied message). nil = the tool is disabled.
        var runCommand: (@Sendable (String) async -> String)? = nil
        /// update_plan sink — hands the parsed steps to the UI layer.
        var updatePlan: (@Sendable ([PlanStep]) async -> String)? = nil
        /// spawn_agents runner (name, prompt) pairs → combined result.
        var spawnAgents: (@Sendable ([(name: String, prompt: String)]) async -> String)? = nil
    }

    struct PlanStep: Sendable, Equatable, Codable {
        var step: String
        var status: String  // pending | in_progress | completed
    }

    struct MemorySnapshot: Sendable {
        let id: UUID
        let content: String
        let topic: String?
    }

    enum MemoryMutation: Sendable {
        case save(content: String, topic: String?)
        case update(id: UUID, content: String?, topic: String?)
        case delete(id: UUID)
    }

    struct MemoryAccess: Sendable {
        let snapshot: [MemorySnapshot]
        let mutate: @Sendable (MemoryMutation) async -> String
    }

    /// The minimal slice of a conversation `search_conversations` needs —
    /// built once per request in `AppModel`, not a live `Conversation`
    /// reference (which is `@MainActor`-bound and not `Sendable`).
    struct ConversationSearchSummary: Sendable {
        let title: String
        let updatedAt: Date
        let messages: [(role: String, content: String)]
    }

    /// A short, human-readable stand-in for a tool call's arguments, for
    /// the `ToolUseDisclosure` card's title — "query" for search tools,
    /// "path" for file tools, the raw JSON as a last resort.
    static func displayArgument(from argumentsJSON: String) -> String {
        guard let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] else {
            return argumentsJSON
        }
        return (arguments["query"] as? String)
            ?? (arguments["path"] as? String)
            ?? (arguments["url"] as? String)
            ?? (arguments["expression"] as? String)
            ?? (arguments["filename"] as? String)
            ?? ""
    }

    /// Outer wrapper: repairs malformed argument JSON where possible and
    /// bounds every tool at 120s — one hung tool must not wedge the whole
    /// reply. ("Error" prefix remains load-bearing for activity tinting.)
    static func execute(name: String, argumentsJSON: String, context: ExecutionContext) async -> String {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await executeInner(name: name, argumentsJSON: argumentsJSON, context: context)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? "Error: the \(name) tool timed out after 120 seconds."
        }
    }

    /// Models sometimes emit almost-JSON arguments (trailing commas,
    /// smart quotes, prose around the object). Salvage the object rather
    /// than failing the call outright.
    static func parseArguments(_ argumentsJSON: String) -> [String: Any]? {
        if let parsed = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] {
            return parsed
        }
        var repaired = argumentsJSON
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        // Trailing commas before a closing brace/bracket.
        repaired = repaired.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        if let parsed = (try? JSONSerialization.jsonObject(with: Data(repaired.utf8))) as? [String: Any] {
            return parsed
        }
        // Extract the first balanced {...} span from surrounding prose.
        guard let start = repaired.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var previous: Character = " "
        for index in repaired[start...].indices {
            let character = repaired[index]
            if character == "\"" && previous != "\\" { inString.toggle() }
            if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(repaired[start...index])
                        return (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) as? [String: Any]
                    }
                }
            }
            previous = character
        }
        return nil
    }

    private static func executeInner(name: String, argumentsJSON: String, context: ExecutionContext) async -> String {
        let arguments = parseArguments(argumentsJSON)

        switch name {
        case searchConversations.name:
            guard let query = arguments?["query"] as? String, !query.isEmpty else { return "Error: no query provided." }
            return searchConversationsResult(query: query, context: context)
        case webSearch.name:
            guard let query = arguments?["query"] as? String, !query.isEmpty else { return "Error: no query provided." }
            return await webSearchResult(query: query, context: context)
        case writeFile.name:
            guard let path = arguments?["path"] as? String, let content = arguments?["content"] as? String else {
                return "Error: both \"path\" and \"content\" are required."
            }
            return writeFileResult(path: path, content: content, context: context)
        case editFile.name:
            guard let path = arguments?["path"] as? String,
                  let oldString = arguments?["old_string"] as? String,
                  let newString = arguments?["new_string"] as? String else {
                return "Error: \"path\", \"old_string\", and \"new_string\" are required."
            }
            return editFileResult(path: path, oldString: oldString, newString: newString, replaceAll: arguments?["replace_all"] as? Bool ?? false, context: context)
        case searchFiles.name:
            return searchFilesResult(glob: arguments?["glob"] as? String, query: arguments?["query"] as? String, context: context)
        case runCommand.name:
            guard let command = arguments?["command"] as? String, !command.isEmpty else { return "Error: \"command\" is required." }
            guard let runner = context.runCommand else { return "Error: running commands is disabled. The user can enable it in Settings → Agent abilities." }
            return await runner(command)
        case "spawn_agents":
            guard let rawTasks = arguments?["tasks"] as? [[String: Any]], !rawTasks.isEmpty else {
                return "Error: \"tasks\" is required and must contain at least one task."
            }
            let tasks = rawTasks.compactMap { entry -> (name: String, prompt: String)? in
                guard let prompt = entry["prompt"] as? String, !prompt.isEmpty else { return nil }
                return (name: (entry["name"] as? String) ?? "", prompt: prompt)
            }
            guard !tasks.isEmpty else { return "Error: every task needs a non-empty \"prompt\"." }
            guard let runner = context.spawnAgents else { return "Error: subagents are disabled. The user can enable them in Settings → Agent abilities." }
            return await runner(tasks)
        case updatePlan.name:
            guard let rawSteps = arguments?["steps"] as? [[String: Any]] else { return "Error: \"steps\" is required." }
            let steps = rawSteps.compactMap { entry -> PlanStep? in
                guard let step = entry["step"] as? String, let status = entry["status"] as? String else { return nil }
                return PlanStep(step: step, status: status)
            }
            guard !steps.isEmpty else { return "Error: no valid steps provided." }
            guard let sink = context.updatePlan else { return "Error: planning is unavailable." }
            return await sink(steps)
        case readFile.name:
            guard let path = arguments?["path"] as? String else { return "Error: \"path\" is required." }
            return readFileResult(path: path, context: context)
        case listWorkspaceFiles.name:
            return listWorkspaceFilesResult(context: context)
        case fetchURL.name:
            guard let urlString = arguments?["url"] as? String, !urlString.isEmpty else { return "Error: \"url\" is required." }
            return await fetchURLResult(urlString: urlString)
        case calculator.name:
            guard let expression = arguments?["expression"] as? String, !expression.isEmpty else { return "Error: \"expression\" is required." }
            return calculatorResult(expression: expression)
        case readAttachment.name:
            guard let filename = arguments?["filename"] as? String, !filename.isEmpty else { return "Error: \"filename\" is required." }
            return readAttachmentResult(filename: filename, context: context)
        case getSchedule.name:
            guard let schedule = context.schedule else { return "Error: the schedule tool is disabled in Settings." }
            let days = (arguments?["days"] as? Int) ?? Int(arguments?["days"] as? Double ?? 7)
            return await schedule(days)
        case readClipboard.name:
            guard let clipboard = context.clipboard else { return "Error: the clipboard tool is disabled in Settings." }
            return await clipboard()
        case saveMemory.name:
            guard let memory = context.memory else { return "Error: memory is unavailable." }
            guard let content = arguments?["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: \"content\" is required."
            }
            return await memory.mutate(.save(content: content, topic: arguments?["topic"] as? String))
        case searchMemory.name:
            guard let memory = context.memory else { return "Error: memory is unavailable." }
            return searchMemoryResult(query: arguments?["query"] as? String ?? "", memory: memory)
        case editMemory.name:
            guard let memory = context.memory else { return "Error: memory is unavailable." }
            guard let idString = arguments?["id"] as? String, let id = UUID(uuidString: idString) else {
                return "Error: a valid \"id\" from search_memory is required."
            }
            switch arguments?["action"] as? String {
            case "delete":
                return await memory.mutate(.delete(id: id))
            case "update":
                return await memory.mutate(.update(id: id, content: arguments?["content"] as? String, topic: arguments?["topic"] as? String))
            default:
                return "Error: \"action\" must be \"update\" or \"delete\"."
            }
        default:
            if name.hasPrefix("mcp_"), let mcpCall = context.mcpCall {
                return await mcpCall(name, argumentsJSON)
            }
            return "Error: unknown tool \"\(name)\"."
        }
    }

    private static func searchMemoryResult(query: String, memory: MemoryAccess) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches: [MemorySnapshot]
        if trimmed.isEmpty {
            matches = Array(memory.snapshot.suffix(12).reversed())
        } else {
            matches = memory.snapshot.filter {
                $0.content.lowercased().contains(trimmed) || ($0.topic?.lowercased().contains(trimmed) ?? false)
            }
        }
        guard !matches.isEmpty else {
            return memory.snapshot.isEmpty
                ? "Memory is empty — nothing has been saved yet."
                : "No stored memories match \"\(query)\"."
        }
        return matches
            .map { "[\($0.id.uuidString)] (\($0.topic ?? "General")) \($0.content)" }
            .joined(separator: "\n")
    }

    private static func readAttachmentResult(filename: String, context: ExecutionContext) -> String {
        if let exact = context.attachmentTexts[filename] { return exact }
        // Tolerate case differences and partial names — the model is typing
        // a filename it saw rendered, not a key it was handed.
        let lowered = filename.lowercased()
        if let match = context.attachmentTexts.first(where: { $0.key.lowercased() == lowered })
            ?? context.attachmentTexts.first(where: { $0.key.lowercased().contains(lowered) }) {
            return match.value
        }
        let available = context.attachmentTexts.keys.sorted().joined(separator: ", ")
        return available.isEmpty
            ? "Error: this conversation has no readable text attachments."
            : "Error: no attachment named \"\(filename)\". Available: \(available)"
    }

    private static func fetchURLResult(urlString: String) async -> String {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "Error: \"\(urlString)\" is not a valid http(s) URL."
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Browser-shaped headers: many sites 403 anything that doesn't
        // look like a real browser. Redirects follow by default.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                let hint = (http.statusCode == 403 || http.statusCode == 429)
                    ? " This site blocks automated readers — try a different source instead of retrying it."
                    : ""
                return "Error: \(url.host ?? urlString) returned HTTP \(http.statusCode) (\(reason)).\(hint)"
            }
            guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return "Error: the page is not text."
            }
            let text = Self.htmlToText(raw)
            let capped = text.count > 12_000 ? String(text.prefix(12_000)) + "\n\n[Truncated — page continues.]" : text
            return capped.isEmpty ? "The page had no readable text." : capped
        } catch {
            return "Error fetching \(urlString): \(error.localizedDescription)"
        }
    }

    /// Good-enough HTML→text: drops script/style/head blocks, turns
    /// block-level tags into newlines, strips the rest, decodes common
    /// entities, collapses blank runs. Not a real DOM parser on purpose.
    static func htmlToText(_ html: String) -> String {
        var text = html
        for block in ["script", "style", "head", "noscript", "svg"] {
            text = text.replacingOccurrences(of: "<\(block)[\\s\\S]*?</\(block)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tiny recursive-descent parser (+ - * / % ^, parentheses, unary
    /// minus, decimals) rather than NSExpression — NSExpression raises
    /// uncatchable ObjC exceptions on malformed model-typed input.
    private static func calculatorResult(expression: String) -> String {
        var parser = ExpressionParser(expression)
        guard let value = parser.parse() else {
            return "Error: could not evaluate \"\(expression)\" — numbers, + - * / % ^ and parentheses only."
        }
        if value.isNaN || value.isInfinite { return "Error: the expression is undefined (division by zero?)." }
        let formatted = value == value.rounded() && abs(value) < 1e15
            ? String(format: "%.0f", value)
            : String(value)
        return "\(expression) = \(formatted)"
    }

    private struct ExpressionParser {
        private let characters: [Character]
        private var position = 0

        init(_ text: String) { characters = Array(text.replacingOccurrences(of: ",", with: "")) }

        mutating func parse() -> Double? {
            let value = parseAdditive()
            skipSpaces()
            return position == characters.count ? value : nil
        }

        private mutating func parseAdditive() -> Double? {
            guard var left = parseMultiplicative() else { return nil }
            while true {
                skipSpaces()
                guard position < characters.count, characters[position] == "+" || characters[position] == "-" else { return left }
                let op = characters[position]; position += 1
                guard let right = parseMultiplicative() else { return nil }
                left = op == "+" ? left + right : left - right
            }
        }

        private mutating func parseMultiplicative() -> Double? {
            guard var left = parsePower() else { return nil }
            while true {
                skipSpaces()
                guard position < characters.count, "*/%".contains(characters[position]) else { return left }
                let op = characters[position]; position += 1
                guard let right = parsePower() else { return nil }
                switch op {
                case "*": left *= right
                case "/": left /= right
                default: left = left.truncatingRemainder(dividingBy: right)
                }
            }
        }

        private mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            skipSpaces()
            guard position < characters.count, characters[position] == "^" else { return base }
            position += 1
            guard let exponent = parsePower() else { return nil }  // right-associative
            return pow(base, exponent)
        }

        private mutating func parseUnary() -> Double? {
            skipSpaces()
            if position < characters.count, characters[position] == "-" {
                position += 1
                return parseUnary().map { -$0 }
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Double? {
            skipSpaces()
            guard position < characters.count else { return nil }
            if characters[position] == "(" {
                position += 1
                let value = parseAdditive()
                skipSpaces()
                guard position < characters.count, characters[position] == ")" else { return nil }
                position += 1
                return value
            }
            var digits = ""
            while position < characters.count, characters[position].isNumber || characters[position] == "." {
                digits.append(characters[position]); position += 1
            }
            return Double(digits)
        }

        private mutating func skipSpaces() {
            while position < characters.count, characters[position] == " " { position += 1 }
        }
    }

    private static func writeFileResult(path: String, content: String, context: ExecutionContext) -> String {
        guard let url = SandboxManager.resolve(path, in: context.workspaceDirectory) else {
            return "Error: \"\(path)\" is outside the workspace folder — only relative paths within it are allowed."
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "Wrote \(content.utf8.count) bytes to \(path)."
        } catch {
            return "Error writing \(path): \(error.localizedDescription)"
        }
    }

    private static func readFileResult(path: String, context: ExecutionContext) -> String {
        guard let url = SandboxManager.resolve(path, in: context.workspaceDirectory) else {
            return "Error: \"\(path)\" is outside the workspace folder — only relative paths within it are allowed."
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: could not read \(path) — it may not exist yet."
        }
        return text
    }

    private static func listWorkspaceFilesResult(context: ExecutionContext) -> String {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: context.workspaceDirectory.path), !items.isEmpty else {
            return "The workspace folder is empty."
        }
        return items.sorted().joined(separator: "\n")
    }

    private static func editFileResult(path: String, oldString: String, newString: String, replaceAll: Bool, context: ExecutionContext) -> String {
        guard let url = SandboxManager.resolve(path, in: context.workspaceDirectory) else {
            return "Error: \"\(path)\" is outside the workspace folder — only relative paths within it are allowed."
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: could not read \(path) — it may not exist yet. Use write_file to create it."
        }
        let occurrences = text.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else {
            return "Error: old_string was not found in \(path). Read the file and copy the exact text, including whitespace."
        }
        if occurrences > 1 && !replaceAll {
            return "Error: old_string matched \(occurrences) times in \(path). Add surrounding context to make it unique, or set replace_all=true."
        }
        let updated = text.replacingOccurrences(of: oldString, with: newString)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return "Edited \(path) — replaced \(replaceAll ? occurrences : 1) occurrence\(replaceAll && occurrences != 1 ? "s" : "")."
        } catch {
            return "Error writing \(path): \(error.localizedDescription)"
        }
    }

    private static func searchFilesResult(glob: String?, query: String?, context: ExecutionContext) -> String {
        let root = context.workspaceDirectory
        let globRegex = glob.map { Self.globToRegex($0) }
        let contentRegex = query.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return "Error: could not read the workspace folder."
        }
        var results: [String] = []
        var scanned = 0
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            if let globRegex, relative.range(of: globRegex, options: .regularExpression) == nil,
               fileURL.lastPathComponent.range(of: globRegex, options: .regularExpression) == nil { continue }
            if let contentRegex {
                scanned += 1
                if scanned > 2_000 { break }
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let lines = text.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    if contentRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                        results.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(160))")
                        if results.count >= 100 { break }
                    }
                }
            } else {
                results.append(relative)
            }
            if results.count >= 100 { break }
        }
        if results.isEmpty { return "No matches." }
        let capped = results.count >= 100 ? results + ["[…more matches; refine the search.]"] : results
        return capped.joined(separator: "\n")
    }

    private static func globToRegex(_ glob: String) -> String {
        var regex = "^"
        for character in glob {
            switch character {
            case "*": regex += "[^/]*"
            case "?": regex += "[^/]"
            case ".": regex += "\\."
            default: regex += String(character)
            }
        }
        return regex + "$"
    }

    private static func searchConversationsResult(query: String, context: ExecutionContext) -> String {
        let lowerQuery = query.lowercased()
        var matches: [String] = []
        for summary in context.conversationSummaries {
            for message in summary.messages where message.content.lowercased().contains(lowerQuery) {
                let excerptStart = message.content.lowercased().range(of: lowerQuery)
                let excerpt: String
                if let excerptStart {
                    let start = message.content.index(excerptStart.lowerBound, offsetBy: -80, limitedBy: message.content.startIndex) ?? message.content.startIndex
                    let end = message.content.index(excerptStart.upperBound, offsetBy: 80, limitedBy: message.content.endIndex) ?? message.content.endIndex
                    excerpt = String(message.content[start..<end])
                } else {
                    excerpt = String(message.content.prefix(160))
                }
                matches.append("[\"\(summary.title)\", \(message.role)] …\(excerpt)…")
                if matches.count >= 8 { break }
            }
            if matches.count >= 8 { break }
        }
        guard !matches.isEmpty else { return "No past conversations mention \"\(query)\"." }
        return "Found \(matches.count) match(es) for \"\(query)\":\n\n" + matches.joined(separator: "\n\n")
    }

    private static func webSearchResult(query: String, context: ExecutionContext) async -> String {
        let trimmedEndpoint = context.searchEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            // "Error" prefix is load-bearing: it's how activity lines know a
            // call failed (see `activityFinished` emission in ChatAPI).
            return "Error: web search isn't configured — no SearXNG endpoint is set in Settings."
        }
        do {
            let results = try await CompatibleChatClient.shared.searchWeb(query: query, endpoint: trimmedEndpoint)
            guard !results.isEmpty else { return "No results found for \"\(query)\"." }
            return results.map { "- \($0.title)\n  \($0.url)\n  \($0.snippet)" }.joined(separator: "\n\n")
        } catch {
            return "Error: web search failed — \(error.localizedDescription)"
        }
    }
}
