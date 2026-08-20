import Foundation

/// Wire types for Claude Code's `stream-json` output.
///
/// This format is **undocumented and version-dependent**. Everything here
/// was derived from frames recorded off a real `claude` 2.1.236 session
/// (`Tests/VelaChatTests/Fixtures/claude-stream.jsonl`), not from a
/// specification — so the decoding rules are deliberately forgiving:
///
/// - Unknown `type` values decode to `.unknown` rather than throwing. A
///   new frame type in a future Claude Code release must not break an
///   in-flight conversation.
/// - Every field that is not load-bearing is optional.
/// - Capabilities are feature-detected by name, never by version compare
///   (`ClaudeCapabilities`).
///
/// Re-record the fixture when Claude Code updates; expect drift.
enum ClaudeStreamFrame: Decodable {
    case system(ClaudeInitEvent)
    case assistant(ClaudeAssistantEvent)
    case user(ClaudeUserEvent)
    case result(ClaudeResultEvent)
    case rateLimit(ClaudeRateLimitEvent)
    case controlRequest(ClaudeControlRequest)
    case controlResponse(ClaudeControlResponse)
    /// A frame this version doesn't model. Carries its `type` so it can be
    /// logged without pretending to understand it.
    case unknown(type: String)

    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "system": self = .system(try ClaudeInitEvent(from: decoder))
        case "assistant": self = .assistant(try ClaudeAssistantEvent(from: decoder))
        case "user": self = .user(try ClaudeUserEvent(from: decoder))
        case "result": self = .result(try ClaudeResultEvent(from: decoder))
        case "rate_limit_event": self = .rateLimit(try ClaudeRateLimitEvent(from: decoder))
        case "control_request", "sdk_control_request": self = .controlRequest(try ClaudeControlRequest(from: decoder))
        case "control_response", "sdk_control_response": self = .controlResponse(try ClaudeControlResponse(from: decoder))
        default: self = .unknown(type: type)
        }
    }

    /// Decodes one NDJSON line. Returns `nil` for blank lines and for
    /// output that isn't JSON at all — Claude Code writes human-readable
    /// diagnostics to the same stream under some failure modes, and one
    /// stray line must not kill the session.
    static func decode(line: String) -> ClaudeStreamFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClaudeStreamFrame.self, from: data)
    }
}

// MARK: - init

/// The `system`/`init` frame — the handshake. Everything the bridge needs
/// to decide what it may offer the user comes from here.
struct ClaudeInitEvent: Decodable {
    var subtype: String?
    var sessionID: String?
    var cwd: String?
    var model: String?
    var claudeCodeVersion: String?
    var permissionMode: String?
    var apiKeySource: String?
    var tools: [String]
    var slashCommands: [String]
    var skills: [String]
    var agents: [String]
    var mcpServers: [ClaudeMcpServerStatus]
    /// Protocol behaviors this Claude Code implements, e.g.
    /// `interrupt_receipt_v1`. Feature-detect against this; never compare
    /// version strings.
    var capabilities: [String]

    private enum CodingKeys: String, CodingKey {
        case subtype, cwd, model, tools, skills, agents, capabilities
        case sessionID = "session_id"
        case claudeCodeVersion = "claude_code_version"
        case permissionMode
        case apiKeySource
        case slashCommands = "slash_commands"
        case mcpServers = "mcp_servers"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtype = try c.decodeIfPresent(String.self, forKey: .subtype)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        claudeCodeVersion = try c.decodeIfPresent(String.self, forKey: .claudeCodeVersion)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        apiKeySource = try c.decodeIfPresent(String.self, forKey: .apiKeySource)
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        slashCommands = try c.decodeIfPresent([String].self, forKey: .slashCommands) ?? []
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        agents = try c.decodeIfPresent([String].self, forKey: .agents) ?? []
        mcpServers = try c.decodeIfPresent([ClaudeMcpServerStatus].self, forKey: .mcpServers) ?? []
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }

    var isIsolated: Bool { mcpServers.isEmpty && skills.isEmpty && slashCommands.isEmpty }
}

struct ClaudeMcpServerStatus: Decodable, Equatable {
    var name: String
    var status: String?
}

/// Named protocol behaviors. Values are compared as strings and unknown
/// ones ignored, so a newer Claude Code advertising more capabilities is
/// simply understood less completely, never rejected.
enum ClaudeCapability: String {
    case interruptReceipt = "interrupt_receipt_v1"
    case interruptCancelQueued = "interrupt_cancel_queued_v1"
    case messageLifecycle = "msg_lifecycle_v1"
}

struct ClaudeCapabilities: Equatable {
    private let names: Set<String>
    init(_ names: [String]) { self.names = Set(names) }
    func has(_ capability: ClaudeCapability) -> Bool { names.contains(capability.rawValue) }
    func has(_ raw: String) -> Bool { names.contains(raw) }
    var all: Set<String> { names }
}

// MARK: - assistant / user turns

struct ClaudeAssistantEvent: Decodable {
    var sessionID: String?
    var message: ClaudeMessage
    var parentToolUseID: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case sessionID = "session_id"
        case parentToolUseID = "parent_tool_use_id"
    }
}

struct ClaudeMessage: Decodable {
    var id: String?
    var model: String?
    var role: String?
    var stopReason: String?
    var content: [ClaudeContentBlock]
    var usage: ClaudeUsage?

    private enum CodingKeys: String, CodingKey {
        case id, model, role, content, usage
        case stopReason = "stop_reason"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        content = try c.decodeIfPresent([ClaudeContentBlock].self, forKey: .content) ?? []
        usage = try c.decodeIfPresent(ClaudeUsage.self, forKey: .usage)
    }

    var text: String {
        content.compactMap { if case .text(let value) = $0 { return value } else { return nil } }
            .joined()
    }

    var thinking: String {
        content.compactMap { if case .thinking(let value) = $0 { return value } else { return nil } }
            .joined()
    }

    var toolUses: [ClaudeToolUse] {
        content.compactMap { if case .toolUse(let use) = $0 { return use } else { return nil } }
    }
}

enum ClaudeContentBlock: Decodable {
    case text(String)
    case thinking(String)
    case toolUse(ClaudeToolUse)
    case toolResult(ClaudeToolResult)
    case other(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input
        case toolUseID = "tool_use_id"
        case content
        case isError = "is_error"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "text":
            self = .text((try? c.decode(String.self, forKey: .text)) ?? "")
        case "thinking":
            self = .thinking((try? c.decode(String.self, forKey: .thinking)) ?? "")
        case "tool_use":
            self = .toolUse(ClaudeToolUse(
                id: (try? c.decode(String.self, forKey: .id)) ?? "",
                name: (try? c.decode(String.self, forKey: .name)) ?? "",
                input: (try? c.decode(JSONValue.self, forKey: .input)) ?? .null
            ))
        case "tool_result":
            self = .toolResult(ClaudeToolResult(
                toolUseID: (try? c.decode(String.self, forKey: .toolUseID)) ?? "",
                content: (try? c.decode(JSONValue.self, forKey: .content)) ?? .null,
                isError: (try? c.decode(Bool.self, forKey: .isError)) ?? false
            ))
        default:
            self = .other(type: type)
        }
    }
}

struct ClaudeToolUse: Equatable {
    var id: String
    var name: String
    var input: JSONValue

    /// A one-line argument summary for the activity timeline — the same
    /// shape VelaChat's own tool rows use.
    var summary: String {
        guard case .object(let fields) = input else { return "" }
        for key in ["command", "file_path", "path", "pattern", "query", "url", "description"] {
            if case .string(let value)? = fields[key] { return value }
        }
        return ""
    }
}

struct ClaudeToolResult: Equatable {
    var toolUseID: String
    var content: JSONValue
    var isError: Bool

    var text: String {
        switch content {
        case .string(let value): return value
        case .array(let items):
            return items.compactMap { item -> String? in
                if case .object(let fields) = item, case .string(let value)? = fields["text"] { return value }
                if case .string(let value) = item { return value }
                return nil
            }.joined(separator: "\n")
        default: return ""
        }
    }
}

/// A `user` frame in this stream is Claude Code replaying a tool result
/// back into the conversation — not something the human typed.
struct ClaudeUserEvent: Decodable {
    var sessionID: String?
    var message: ClaudeMessage

    private enum CodingKeys: String, CodingKey {
        case message
        case sessionID = "session_id"
    }

    var toolResults: [ClaudeToolResult] {
        message.content.compactMap { if case .toolResult(let result) = $0 { return result } else { return nil } }
    }
}

// MARK: - usage and result

/// Claude's own usage shape. Note `cacheCreation`, which splits cache
/// writes by TTL tier — the exact field Phase 2's cost math needs and
/// which no OpenAI-compatible provider reports.
struct ClaudeUsage: Decodable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadInputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheCreation: ClaudeCacheCreation?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
    }
}

struct ClaudeCacheCreation: Decodable, Equatable {
    var ephemeral5m: Int?
    var ephemeral1h: Int?

    private enum CodingKeys: String, CodingKey {
        case ephemeral5m = "ephemeral_5m_input_tokens"
        case ephemeral1h = "ephemeral_1h_input_tokens"
    }
}

struct ClaudeResultEvent: Decodable {
    var sessionID: String?
    var isError: Bool
    var stopReason: String?
    var numTurns: Int?
    var durationAPIms: Int?
    /// Claude Code's own cost figure. Provider-reported, so it is used as
    /// observed rather than recomputed — see invariant 5.
    var totalCostUSD: Double?
    var usage: ClaudeUsage?

    private enum CodingKeys: String, CodingKey {
        case usage
        case sessionID = "session_id"
        case isError = "is_error"
        case stopReason = "stop_reason"
        case numTurns = "num_turns"
        case durationAPIms = "duration_api_ms"
        case totalCostUSD = "total_cost_usd"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        numTurns = try c.decodeIfPresent(Int.self, forKey: .numTurns)
        durationAPIms = try c.decodeIfPresent(Int.self, forKey: .durationAPIms)
        totalCostUSD = try c.decodeIfPresent(Double.self, forKey: .totalCostUSD)
        usage = try c.decodeIfPresent(ClaudeUsage.self, forKey: .usage)
    }
}

// MARK: - rate limits

/// Undocumented but load-bearing: this arrives unprompted on the stream
/// and carries a real reset timestamp. It is a far better quota source
/// than polling an OAuth endpoint, because it costs nothing and cannot be
/// rate-limited itself.
struct ClaudeRateLimitEvent: Decodable {
    var info: Info?

    struct Info: Decodable, Equatable {
        var status: String?
        var resetsAt: Double?
        var rateLimitType: String?
        var isUsingOverage: Bool?

        var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }

        /// Minutes in the window named by `rateLimitType`, when it maps to
        /// one VelaChat already models. Unknown values stay `nil` rather
        /// than being guessed at.
        var windowMinutes: Int? {
            switch rateLimitType {
            case "five_hour": return 300
            case "seven_day", "weekly": return 10_080
            default: return nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case info = "rate_limit_info" }
}

// MARK: - control frames

/// Bidirectional control channel. Claude Code sends a request; the host
/// answers with a matching `response.request_id`.
struct ClaudeControlRequest: Decodable {
    var requestID: String?
    var subtype: String?
    var request: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case subtype, request
        case requestID = "request_id"
    }

    var isPermission: Bool {
        subtype == "permission" || subtype == "can_use_tool"
    }

    /// Tool name a permission request is asking about, when present.
    var toolName: String? {
        guard case .object(let fields)? = request else { return nil }
        if case .string(let name)? = fields["tool_name"] { return name }
        if case .string(let name)? = fields["name"] { return name }
        return nil
    }

    var toolInput: JSONValue? {
        guard case .object(let fields)? = request else { return nil }
        return fields["input"] ?? fields["tool_input"]
    }
}

struct ClaudeControlResponse: Decodable {
    var requestID: String?
    var response: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case response
        case requestID = "request_id"
    }
}

/// Frames VelaChat writes to Claude Code's stdin.
enum ClaudeOutboundFrame {
    case userTurn(text: String)
    case interrupt(requestID: String)
    case permissionAllow(requestID: String, updatedInput: JSONValue?)
    case permissionDeny(requestID: String, reason: String)

    func encoded() throws -> Data {
        let object: [String: Any]
        switch self {
        case .userTurn(let text):
            object = [
                "type": "user",
                "message": ["role": "user", "content": [["type": "text", "text": text]]]
            ]
        case .interrupt(let requestID):
            object = ["type": "control_request", "request_id": requestID, "request": ["subtype": "interrupt"]]
        case .permissionAllow(let requestID, let updatedInput):
            var response: [String: Any] = ["behavior": "allow"]
            if let updatedInput, let raw = updatedInput.anyValue { response["updatedInput"] = raw }
            object = ["type": "control_response", "request_id": requestID, "response": response]
        case .permissionDeny(let requestID, let reason):
            object = [
                "type": "control_response",
                "request_id": requestID,
                "response": ["behavior": "deny", "message": reason]
            ]
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)  // NDJSON: exactly one frame per line.
        return data
    }
}
