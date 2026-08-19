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

    static let currentDatetime = Definition(
        name: "current_datetime",
        description: "Get the user's current local date, time, and timezone. Use whenever \"today\", \"now\", or any relative date matters — do not guess the date.",
        parametersJSON: #"{"type":"object","properties":{}}"#,
        summary: "get the current local date and time",
        guidance: "Your training data does not tell you today's date. Call this before reasoning about anything time-relative."
    )

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

    /// The system-prompt tool inventory: the wire `tools` array alone is not
    /// enough — models routinely claim "I don't have internet access" while
    /// a web_search tool sits attached. Built from the exact tools being
    /// attached, so it never advertises something the request doesn't carry.
    static func inventoryInstruction(tools: [Definition], nativeSearch: Bool) -> String? {
        guard !tools.isEmpty else { return nil }
        var lines = [
            "You have real, callable tools attached to this request. Use them — never claim you lack a capability one of them provides."
        ]
        for tool in tools {
            lines.append("- \(tool.name): \(tool.summary). \(tool.guidance)")
        }
        if nativeSearch {
            lines.append("- (Your provider also performs live web search natively on this request.)")
        }
        lines.append("Call tools as often as genuinely needed; results come back to you before you answer. Keep your final answer grounded in what the tools returned.")
        return lines.joined(separator: "\n")
    }

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

    static func execute(name: String, argumentsJSON: String, context: ExecutionContext) async -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]

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
        case readFile.name:
            guard let path = arguments?["path"] as? String else { return "Error: \"path\" is required." }
            return readFileResult(path: path, context: context)
        case listWorkspaceFiles.name:
            return listWorkspaceFilesResult(context: context)
        case fetchURL.name:
            guard let urlString = arguments?["url"] as? String, !urlString.isEmpty else { return "Error: \"url\" is required." }
            return await fetchURLResult(urlString: urlString)
        case currentDatetime.name:
            return currentDatetimeResult()
        case calculator.name:
            guard let expression = arguments?["expression"] as? String, !expression.isEmpty else { return "Error: \"expression\" is required." }
            return calculatorResult(expression: expression)
        case readAttachment.name:
            guard let filename = arguments?["filename"] as? String, !filename.isEmpty else { return "Error: \"filename\" is required." }
            return readAttachmentResult(filename: filename, context: context)
        default:
            return "Error: unknown tool \"\(name)\"."
        }
    }

    private static func currentDatetimeResult() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        return formatter.string(from: Date())
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
        request.setValue("Mozilla/5.0 (Macintosh) VelaChat", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return "Error: \(url.host ?? urlString) returned HTTP \(http.statusCode)."
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
