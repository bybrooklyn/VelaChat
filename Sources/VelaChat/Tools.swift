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
        let description: String
        /// A JSON Schema `properties` object, hand-built per tool rather
        /// than reflected from Swift types — there are only two tools, and
        /// a tiny hand-written schema is far less risk than a general
        /// schema generator for this scope.
        let parametersJSON: String
    }

    static let searchConversations = Definition(
        name: "search_conversations",
        description: "Search the user's past conversations in this app for relevant context — names, decisions, or details mentioned before. Token-efficient: returns only matching excerpts, not whole conversations.",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"What to search for"}},"required":["query"]}"#
    )

    static let webSearch = Definition(
        name: "web_search",
        description: "Search the live web and return real results with titles, URLs, and snippets.",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"The search query"}},"required":["query"]}"#
    )

    /// A real, private, per-conversation folder on disk — not a general
    /// filesystem. See `SandboxManager` for the actual safety boundary
    /// (path validation, not process sandboxing) and why a shell-execution
    /// tool isn't offered alongside these.
    static let writeFile = Definition(
        name: "write_file",
        description: "Write a text file into this conversation's private workspace folder (a real, isolated folder on disk, separate for every conversation). Overwrites the file if it already exists. Use relative paths only.",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Relative path within the workspace, e.g. \"notes.txt\" or \"src/main.py\""},"content":{"type":"string","description":"The full file content to write"}},"required":["path","content"]}"#
    )
    static let readFile = Definition(
        name: "read_file",
        description: "Read a text file from this conversation's private workspace folder.",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Relative path within the workspace"}},"required":["path"]}"#
    )
    static let listWorkspaceFiles = Definition(
        name: "list_workspace_files",
        description: "List the files currently in this conversation's private workspace folder.",
        parametersJSON: #"{"type":"object","properties":{}}"#
    )

    /// What a tool call actually needs at execution time — read-only
    /// snapshots, not a live reference to `AppModel` (this runs from
    /// `CompatibleChatClient`, which has no knowledge of `AppModel`).
    struct ExecutionContext: Sendable {
        let conversationSummaries: [ConversationSearchSummary]
        let searchEndpoint: String
        let workspaceDirectory: URL
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
        return (arguments["query"] as? String) ?? (arguments["path"] as? String) ?? argumentsJSON
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
        default:
            return "Error: unknown tool \"\(name)\"."
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
            return "Web search isn't configured — no SearXNG endpoint is set in Settings."
        }
        do {
            let results = try await CompatibleChatClient.shared.searchWeb(query: query, endpoint: trimmedEndpoint)
            guard !results.isEmpty else { return "No results found for \"\(query)\"." }
            return results.map { "- \($0.title)\n  \($0.url)\n  \($0.snippet)" }.joined(separator: "\n\n")
        } catch {
            return "Web search failed: \(error.localizedDescription)"
        }
    }
}
