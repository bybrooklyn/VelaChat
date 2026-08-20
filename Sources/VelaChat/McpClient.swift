import Foundation
import Observation

/// One configured MCP server — the standard `mcpServers` JSON shape
/// (command + args + env), stored per entry with a local enable switch.
struct McpServerConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var args: [String] = []
    var env: [String: String] = [:]
    var enabled = true

    init(id: UUID = UUID(), name: String, command: String, args: [String] = [], env: [String: String] = [:], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "server"
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct McpToolInfo: Sendable {
    let name: String
    let description: String
    let inputSchemaJSON: String
}

/// A long-lived stdio MCP server process speaking newline-delimited
/// JSON-RPC 2.0 — initialize handshake, tools/list, tools/call. Basic by
/// design (user-confirmed): no HTTP transports, no resources/prompts,
/// no per-call approval.
actor McpClient {
    enum McpError: LocalizedError {
        case notRunning(String)
        case timeout
        case protocolError(String)
        var errorDescription: String? {
            switch self {
            case .notRunning(let detail): "MCP server isn't running: \(detail)"
            case .timeout: "The MCP server didn't answer in time."
            case .protocolError(let detail): detail
            }
        }
    }

    private let config: McpServerConfig
    private var process: Process?
    private var stdinPipe: Pipe?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var readBuffer = Data()
    private(set) var stderrLog = ""
    private var didAutoRestart = false

    init(config: McpServerConfig) {
        self.config = config
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() async throws {
        guard !(process?.isRunning ?? false) else { return }
        let process = Process()
        // GUI apps don't inherit a shell PATH — resolve bare commands via
        // env with Homebrew's prefix appended.
        if config.command.contains("/") {
            process.executableURL = URL(fileURLWithPath: config.command)
            process.arguments = config.args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [config.command] + config.args
        }
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = path + ":/opt/homebrew/bin:/usr/local/bin"
        for (key, value) in config.env { environment[key] = value }
        process.environment = environment

        let input = Pipe(), output = Pipe(), errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consume(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendStderr(text) }
        }
        try process.run()
        self.process = process
        self.stdinPipe = input

        // Handshake: initialize → notifications/initialized.
        _ = try await request(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "VelaChat", "version": AppModel.appVersion]
        ])
        try send(json: ["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func stop() {
        for (_, continuation) in pending {
            continuation.resume(throwing: McpError.notRunning("stopped"))
        }
        pending.removeAll()
        process?.terminate()
        process = nil
        stdinPipe = nil
    }

    func listTools() async throws -> [McpToolInfo] {
        try await ensureRunning()
        // Shorter than a tool call's budget: a dead server at send time
        // should cost seconds, not half a minute of stalled reply.
        let result = try await request(method: "tools/list", params: [:], timeoutSeconds: Limits.mcpListTimeout)
        let tools = (result["tools"] as? [[String: Any]]) ?? []
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let schema = tool["inputSchema"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { String(data: $0, encoding: .utf8) }
            return McpToolInfo(
                name: name,
                description: (tool["description"] as? String) ?? "",
                inputSchemaJSON: schema ?? #"{"type":"object","properties":{}}"#
            )
        }
    }

    func callTool(name: String, argumentsJSON: String) async -> String {
        do {
            try await ensureRunning()
            let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
            let result = try await request(method: "tools/call", params: [
                "name": name,
                "arguments": arguments
            ])
            let content = (result["content"] as? [[String: Any]]) ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if (result["isError"] as? Bool) == true {
                // "Error" prefix is load-bearing for activity-line tinting.
                return "Error: " + (text.isEmpty ? "the tool reported a failure." : text)
            }
            return text.isEmpty ? "(The tool returned no text content.)" : text
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Internals

    private func ensureRunning() async throws {
        if process?.isRunning == true { return }
        if process != nil, !didAutoRestart {
            // One automatic restart after a crash; after that, honest failure.
            didAutoRestart = true
            process = nil
        } else if process != nil {
            throw McpError.notRunning("the server crashed and was already restarted once")
        }
        try await start()
    }

    private func appendStderr(_ text: String) {
        stderrLog += text
        if stderrLog.count > 4_000 { stderrLog = String(stderrLog.suffix(4_000)) }
    }

    private func request(method: String, params: [String: Any], timeoutSeconds: Double = 30) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(json: payload)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self.timeOut(id: id)
            }
        }
    }

    private func timeOut(id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: McpError.timeout)
    }

    private func send(json: [String: Any]) throws {
        guard let stdinPipe else { throw McpError.notRunning("no stdin") }
        var data = try JSONSerialization.data(withJSONObject: json)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer[readBuffer.startIndex..<newline]
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard !line.isEmpty,
                  let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = message["id"] as? Int,
                  let continuation = pending.removeValue(forKey: id) else { continue }
            if let error = message["error"] as? [String: Any] {
                let text = (error["message"] as? String) ?? "unknown JSON-RPC error"
                continuation.resume(throwing: McpError.protocolError(text))
            } else {
                continuation.resume(returning: (message["result"] as? [String: Any]) ?? [:])
            }
        }
    }
}

/// The app-side registry: persisted configs, lazy clients, tool cache,
/// and the send-time definition merge.
@MainActor
@Observable
final class McpManager {
    private(set) var servers: [McpServerConfig] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(servers) {
                UserDefaults.standard.set(data, forKey: DefaultsKey.mcpServers)
            }
        }
    }
    /// Last start/list failure per server, for the Settings card.
    private(set) var lastErrorByServer: [UUID: String] = [:]
    private var clients: [UUID: McpClient] = [:]
    private var toolCache: [UUID: [McpToolInfo]] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.mcpServers),
           let saved = try? JSONDecoder().decode([McpServerConfig].self, from: data) {
            servers = saved
        }
    }

    func add(_ config: McpServerConfig) {
        servers.append(config)
    }

    func update(_ config: McpServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[index] = config
        toolCache[config.id] = nil
        if let client = clients.removeValue(forKey: config.id) {
            Task { await client.stop() }
        }
    }

    func remove(id: UUID) {
        servers.removeAll { $0.id == id }
        toolCache[id] = nil
        if let client = clients.removeValue(forKey: id) {
            Task { await client.stop() }
        }
    }

    /// Accepts the standard `{"mcpServers": {name: {command,args,env}}}`
    /// blob (Claude Desktop-compatible); merges by name.
    func importJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["mcpServers"] as? [String: [String: Any]] else {
            return "That doesn't look like an mcpServers JSON config."
        }
        var imported = 0
        for (name, entry) in entries {
            guard let command = entry["command"] as? String else { continue }
            let config = McpServerConfig(
                name: name,
                command: command,
                args: (entry["args"] as? [String]) ?? [],
                env: (entry["env"] as? [String: String]) ?? [:]
            )
            if let index = servers.firstIndex(where: { $0.name == name }) {
                var updated = config
                updated.id = servers[index].id
                updated.enabled = servers[index].enabled
                servers[index] = updated
            } else {
                servers.append(config)
            }
            imported += 1
        }
        return imported == 0 ? "No servers found in that JSON." : nil
    }

    private func client(for config: McpServerConfig) -> McpClient {
        if let existing = clients[config.id] { return existing }
        let client = McpClient(config: config)
        clients[config.id] = client
        return client
    }

    /// Tool definitions for a send — lazily starts enabled servers, caches
    /// their tool lists, never blocks a send on a broken server.
    func definitionsForSend() async -> [ToolCatalog.Definition] {
        var definitions: [ToolCatalog.Definition] = []
        for config in servers where config.enabled && !config.command.isEmpty {
            let tools: [McpToolInfo]
            if let cached = toolCache[config.id] {
                tools = cached
            } else {
                do {
                    tools = try await client(for: config).listTools()
                    toolCache[config.id] = tools
                    lastErrorByServer[config.id] = nil
                } catch {
                    lastErrorByServer[config.id] = error.localizedDescription
                    continue
                }
            }
            for tool in tools {
                definitions.append(ToolCatalog.Definition(
                    name: Self.prefixedName(server: config.name, tool: tool.name),
                    description: tool.description.isEmpty ? "A tool provided by the '\(config.name)' MCP server." : tool.description,
                    parametersJSON: tool.inputSchemaJSON,
                    guidance: "Provided by the '\(config.name)' MCP server."
                ))
            }
        }
        return definitions
    }

    func call(prefixedName: String, argumentsJSON: String) async -> String {
        // A sanitized server name can itself contain "_" (e.g.
        // "brave-search" → "brave_search"), so splitting on the first
        // underscore misroutes; match the longest configured server
        // prefix instead and treat the remainder as the tool name.
        guard prefixedName.hasPrefix("mcp_") else {
            return "Error: no MCP server matches \"\(prefixedName)\"."
        }
        let rest = String(prefixedName.dropFirst(4))
        let match = servers
            .map { (config: $0, prefix: Self.sanitized($0.name) + "_") }
            .filter { rest.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }
        guard let match, rest.count > match.prefix.count else {
            return "Error: no MCP server matches \"\(prefixedName)\"."
        }
        let toolName = String(rest.dropFirst(match.prefix.count))
        return await client(for: match.config).callTool(name: toolName, argumentsJSON: argumentsJSON)
    }

    func stopAll() {
        for (_, client) in clients {
            Task { await client.stop() }
        }
        clients.removeAll()
    }

    static func sanitized(_ name: String) -> String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    static func prefixedName(server: String, tool: String) -> String {
        "mcp_\(sanitized(server))_\(tool)"
    }
}
