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
public enum ClaudeStreamFrame: Decodable {
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

    public init(from decoder: Decoder) throws {
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
    public static func decode(line: String) -> ClaudeStreamFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClaudeStreamFrame.self, from: data)
    }
}

// MARK: - init

/// The `system`/`init` frame — the handshake. Everything the bridge needs
/// to decide what it may offer the user comes from here.
public struct ClaudeInitEvent: Decodable {
    public var subtype: String?
    public var sessionID: String?
    public var cwd: String?
    public var model: String?
    public var claudeCodeVersion: String?
    public var permissionMode: String?
    public var apiKeySource: String?
    public var tools: [String]
    public var slashCommands: [String]
    public var skills: [String]
    public var agents: [String]
    public var mcpServers: [ClaudeMcpServerStatus]
    /// Protocol behaviors this Claude Code implements, e.g.
    /// `interrupt_receipt_v1`. Feature-detect against this; never compare
    /// version strings.
    public var capabilities: [String]

    private enum CodingKeys: String, CodingKey {
        case subtype, cwd, model, tools, skills, agents, capabilities
        case sessionID = "session_id"
        case claudeCodeVersion = "claude_code_version"
        case permissionMode
        case apiKeySource
        case slashCommands = "slash_commands"
        case mcpServers = "mcp_servers"
    }

    public init(from decoder: Decoder) throws {
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

    public var isIsolated: Bool { mcpServers.isEmpty && skills.isEmpty && slashCommands.isEmpty }
}

public struct ClaudeMcpServerStatus: Decodable, Equatable {
    public var name: String
    public var status: String?
}

/// Named protocol behaviors. Values are compared as strings and unknown
/// ones ignored, so a newer Claude Code advertising more capabilities is
/// simply understood less completely, never rejected.
public enum ClaudeCapability: String {
    case interruptReceipt = "interrupt_receipt_v1"
    case interruptCancelQueued = "interrupt_cancel_queued_v1"
    case messageLifecycle = "msg_lifecycle_v1"
}

public struct ClaudeCapabilities: Equatable {
    private let names: Set<String>
    public init(_ names: [String]) { self.names = Set(names) }
    public func has(_ capability: ClaudeCapability) -> Bool { names.contains(capability.rawValue) }
    public func has(_ raw: String) -> Bool { names.contains(raw) }
    public var all: Set<String> { names }
}

// MARK: - assistant / user turns

public struct ClaudeAssistantEvent: Decodable {
    public var sessionID: String?
    public var message: ClaudeMessage
    public var parentToolUseID: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case sessionID = "session_id"
        case parentToolUseID = "parent_tool_use_id"
    }
}

public struct ClaudeMessage: Decodable {
    public var id: String?
    public var model: String?
    public var role: String?
    public var stopReason: String?
    public var content: [ClaudeContentBlock]
    public var usage: ClaudeUsage?

    private enum CodingKeys: String, CodingKey {
        case id, model, role, content, usage
        case stopReason = "stop_reason"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        content = try c.decodeIfPresent([ClaudeContentBlock].self, forKey: .content) ?? []
        usage = try c.decodeIfPresent(ClaudeUsage.self, forKey: .usage)
    }

    public var text: String {
        content.compactMap { if case .text(let value) = $0 { return value } else { return nil } }
            .joined()
    }

    public var thinking: String {
        content.compactMap { if case .thinking(let value) = $0 { return value } else { return nil } }
            .joined()
    }

    public var toolUses: [ClaudeToolUse] {
        content.compactMap { if case .toolUse(let use) = $0 { return use } else { return nil } }
    }
}

public enum ClaudeContentBlock: Decodable {
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

    public init(from decoder: Decoder) throws {
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

public struct ClaudeToolUse: Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }

    /// A one-line argument summary for the activity timeline — the same
    /// shape VelaChat's own tool rows use.
    public var summary: String {
        guard case .object(let fields) = input else { return "" }
        for key in ["command", "file_path", "path", "pattern", "query", "url", "description"] {
            if case .string(let value)? = fields[key] { return value }
        }
        return ""
    }
}

public struct ClaudeToolResult: Equatable {
    public var toolUseID: String
    public var content: JSONValue
    public var isError: Bool

    public init(toolUseID: String, content: JSONValue, isError: Bool) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
    }

    public var text: String {
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
public struct ClaudeUserEvent: Decodable {
    public var sessionID: String?
    public var message: ClaudeMessage

    private enum CodingKeys: String, CodingKey {
        case message
        case sessionID = "session_id"
    }

    public var toolResults: [ClaudeToolResult] {
        message.content.compactMap { if case .toolResult(let result) = $0 { return result } else { return nil } }
    }
}

// MARK: - usage and result

/// Claude's own usage shape. Note `cacheCreation`, which splits cache
/// writes by TTL tier — the exact field Phase 2's cost math needs and
/// which no OpenAI-compatible provider reports.
public struct ClaudeUsage: Decodable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadInputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var cacheCreation: ClaudeCacheCreation?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
    }
}

public struct ClaudeCacheCreation: Decodable, Equatable {
    public var ephemeral5m: Int?
    public var ephemeral1h: Int?

    private enum CodingKeys: String, CodingKey {
        case ephemeral5m = "ephemeral_5m_input_tokens"
        case ephemeral1h = "ephemeral_1h_input_tokens"
    }
}

public struct ClaudeResultEvent: Decodable {
    public var sessionID: String?
    public var isError: Bool
    public var stopReason: String?
    public var numTurns: Int?
    public var durationAPIms: Int?
    /// Claude Code's own cost figure. Provider-reported, so it is used as
    /// observed rather than recomputed — see invariant 5.
    public var totalCostUSD: Double?
    public var usage: ClaudeUsage?

    private enum CodingKeys: String, CodingKey {
        case usage
        case sessionID = "session_id"
        case isError = "is_error"
        case stopReason = "stop_reason"
        case numTurns = "num_turns"
        case durationAPIms = "duration_api_ms"
        case totalCostUSD = "total_cost_usd"
    }

    public init(from decoder: Decoder) throws {
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
public struct ClaudeRateLimitEvent: Decodable {
    public var info: Info?

    public struct Info: Decodable, Equatable {
        public var status: String?
        public var resetsAt: Double?
        public var rateLimitType: String?
        public var isUsingOverage: Bool?

        // Keys are camelCase ON THE WIRE (verified against the recorded
        // 2.1.236 fixture) — no CodingKeys needed, and a snake_case guess
        // silently decodes every field as nil.

        public var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }

        /// Minutes in the window named by `rateLimitType`, when it maps to
        /// one VelaChat already models. Unknown values stay `nil` rather
        /// than being guessed at.
        public var windowMinutes: Int? {
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
public struct ClaudeControlRequest: Decodable {
    public var requestID: String?
    public var subtype: String?
    public var request: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case subtype, request
        case requestID = "request_id"
    }

    public var isPermission: Bool {
        subtype == "permission" || subtype == "can_use_tool"
    }

    /// Tool name a permission request is asking about, when present.
    public var toolName: String? {
        guard case .object(let fields)? = request else { return nil }
        if case .string(let name)? = fields["tool_name"] { return name }
        if case .string(let name)? = fields["name"] { return name }
        return nil
    }

    public var toolInput: JSONValue? {
        guard case .object(let fields)? = request else { return nil }
        return fields["input"] ?? fields["tool_input"]
    }
}

public struct ClaudeControlResponse: Decodable {
    public var requestID: String?
    public var response: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case response
        case requestID = "request_id"
    }
}

/// Frames VelaChat writes to Claude Code's stdin.
public enum ClaudeOutboundFrame {
    case userTurn(text: String)
    case interrupt(requestID: String)
    case permissionAllow(requestID: String, updatedInput: JSONValue?)
    case permissionDeny(requestID: String, reason: String)

    public func encoded() throws -> Data {
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
