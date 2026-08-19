import Foundation

struct ProviderCredential: Sendable {
    let token: String?
    let accountID: String?
    let isCodexOAuth: Bool
}

final class CompatibleChatClient: @unchecked Sendable {
    static let shared = CompatibleChatClient()

    private let session: URLSession
    private let decoder = JSONDecoder()

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        session = URLSession(configuration: configuration)
    }

    /// Queries a self-hosted or public SearXNG instance's JSON API — free,
    /// keyless metasearch, per the explicit "permanently free, no key"
    /// requirement (a commercial keyed API, or Ollama's own hosted search,
    /// were both ruled out for exactly that reason).
    func searchWeb(query: String, endpoint: String) async throws -> [WebSearchResult] {
        guard var components = URLComponents(string: endpoint), components.host != nil else {
            throw APIError.message("Invalid web search endpoint URL.")
        }
        let existingPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = existingPath.isEmpty ? "/search" : "/\(existingPath)/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else {
            throw APIError.message("Invalid web search endpoint URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("VelaChat/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let payload = try decoder.decode(SearXNGResponse.self, from: data)
        return payload.results.prefix(5).map {
            WebSearchResult(title: $0.title, url: $0.url, snippet: $0.content ?? "")
        }
    }

    func fetchModels(profile: ProviderProfile, credential: ProviderCredential) async throws -> [RemoteModel] {
        if profile.kind == .codex && credential.isCodexOAuth {
            return ModelCatalog.curated(for: .codex)
        }
        try Self.requireCredential(profile: profile, credential: credential)

        if profile.kind == .ollama {
            let base = try baseURL(for: profile.endpoint)
            let url = base.deletingLastPathComponent().appendingPathComponent("api/tags")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = Self.discoveryTimeout(for: profile.kind)
            addHeaders(to: &request, profile: profile, credential: credential)
            let (data, response) = try await session.data(for: request)
            try Self.check(response: response, data: data)
            let payload = try decoder.decode(OllamaTagsResponse.self, from: data)
            // `/api/tags` alone only gives quantization/size — real
            // capability and context-length data lives behind a per-model
            // `/api/show` call, so the catalog is enriched with one of those
            // per model (concurrently; Ollama is local, so this is cheap).
            // A `/api/show` failure for one model just falls back to the
            // same ID-substring guess used for every other provider — it
            // never breaks the rest of the catalog.
            return try await withThrowingTaskGroup(of: RemoteModel.self) { group in
                for item in payload.models {
                    group.addTask {
                        let isCloud = item.name.lowercased().hasSuffix(":cloud")
                        let show = try? await self.fetchOllamaShow(profile: profile, model: item.name, family: item.details?.family)
                        let capabilities = show?.capabilities ?? []
                        let vision = capabilities.isEmpty
                            ? item.details?.families?.contains(where: { $0.lowercased().contains("clip") || $0.lowercased().contains("vision") })
                            : capabilities.contains("vision")
                        return RemoteModel(
                            id: item.name,
                            name: item.name,
                            contextLength: show?.contextLength,
                            parameterSize: item.details?.parameterSize,
                            sizeBytes: item.size,
                            quantizationLevel: item.details?.quantizationLevel,
                            isCloudHosted: isCloud,
                            supportsReasoning: capabilities.isEmpty ? nil : capabilities.contains("thinking"),
                            supportsVision: vision,
                            supportsTools: capabilities.isEmpty ? nil : capabilities.contains("tools"),
                            isLocal: true
                        )
                    }
                }
                var results: [RemoteModel] = []
                for try await model in group { results.append(model) }
                return results
            }
        }

        // Anthropic's API is not OpenAI-shaped at all — separate endpoint,
        // separate auth headers, separate response schema — so it gets its
        // own request path rather than being forced through the generic one.
        if profile.kind == .anthropic {
            return try await fetchAnthropicModels(profile: profile, credential: credential)
        }

        let url = try endpointURL(profile: profile, path: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.discoveryTimeout(for: profile.kind)
        addHeaders(to: &request, profile: profile, credential: credential)
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let payload = try decoder.decode(ModelListResponse.self, from: data)
        // blockrun.ai is anonymous and keyless, but not every model in its
        // catalog actually is: only `billing_mode == "free"` models accept
        // an anonymous request — everything else 402s, since blockrun uses
        // x402 crypto micropayments rather than a traditional login/API-key
        // tier VelaChat could authenticate. Confirmed live against the real
        // API before writing this filter, not assumed.
        let items = profile.kind == .blockrun
            ? payload.data.filter { $0.billingMode?.lowercased() == "free" }
            : payload.data
        return items.map { item in
            let supported = item.supportedParameters ?? []
            let normalized = supported.map { $0.lowercased() }
            let categories = (item.categories ?? []).map { $0.lowercased() }
            let architectureModalities = item.architecture?.inputModalities ?? []
            let advertisedEfforts = item.reasoning?.supportedEfforts ?? []
            let reasoning = normalized.contains(where: { $0.contains("reasoning") }) || !advertisedEfforts.isEmpty || categories.contains("reasoning")
            let vision = architectureModalities.contains(where: { $0.lowercased().contains("image") }) || categories.contains("vision")
            let tools = normalized.contains(where: { $0 == "tools" || $0.contains("tool_choice") }) || categories.contains("tools")
            let deepSeekModel = profile.kind == .deepSeek && item.id.lowercased().contains("deepseek-v4")
            // Two real, verified pricing shapes: blockrun already publishes
            // $/1M tokens as numbers; OpenRouter publishes $/token as
            // strings, so it needs converting to the same $/1M unit.
            // Neither is guessed for any other provider.
            let (inputPrice, outputPrice): (Double?, Double?) = {
                guard let pricing = item.pricing else { return (nil, nil) }
                if profile.kind == .blockrun {
                    return (pricing.input, pricing.output)
                }
                let promptPerToken = pricing.prompt.flatMap(Double.init)
                let completionPerToken = pricing.completion.flatMap(Double.init)
                return (promptPerToken.map { $0 * 1_000_000 }, completionPerToken.map { $0 * 1_000_000 })
            }()
            return RemoteModel(
                id: item.id,
                ownedBy: item.ownedBy,
                name: item.name,
                description: item.description,
                contextLength: item.contextLength ?? item.contextWindow ?? ModelCatalog.curatedContextLength(for: item.id),
                maxOutputTokens: item.topProvider?.maxCompletionTokens ?? item.maxOutput ?? (deepSeekModel ? 384_000 : nil),
                supportsReasoning: reasoning ? true : nil,
                supportsVision: vision ? true : nil,
                supportsTools: tools ? true : nil,
                supportedEfforts: advertisedEfforts.isEmpty ? supportedReasoningEfforts(from: normalized) : advertisedEfforts,
                inputPricePerMillion: inputPrice,
                outputPricePerMillion: outputPrice
            )
        }
    }

    private struct OllamaShowRequest: Encodable {
        let model: String
    }

    /// `/api/show`'s `model_info` uses architecture-prefixed dynamic keys
    /// (`"llama.context_length"`, `"gemma3.context_length"`, …), which plain
    /// `Decodable` can't target without knowing the architecture ahead of
    /// time — read as a loose JSON object instead of a fixed Decodable shape.
    private func fetchOllamaShow(profile: ProviderProfile, model: String, family: String?) async throws -> (capabilities: [String], contextLength: Int?) {
        let base = try baseURL(for: profile.endpoint)
        let url = base.deletingLastPathComponent().appendingPathComponent("api/show")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(OllamaShowRequest(model: model))
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], nil)
        }
        let capabilities = (object["capabilities"] as? [String]) ?? []
        var contextLength: Int?
        if let modelInfo = object["model_info"] as? [String: Any] {
            if let family, let value = modelInfo["\(family).context_length"] as? Int {
                contextLength = value
            } else if let match = modelInfo.first(where: { $0.key.hasSuffix(".context_length") }) {
                contextLength = match.value as? Int
            }
        }
        return (capabilities, contextLength)
    }

    /// One progress line from Ollama's `/api/pull` NDJSON stream — real
    /// fields straight off the wire (`status`, `digest`, `total`,
    /// `completed`, `error`), no guessing at download size ahead of time.
    struct OllamaPullProgress: Decodable, Sendable {
        let status: String
        let digest: String?
        let total: Int64?
        let completed: Int64?
        let error: String?
    }

    private struct OllamaPullRequest: Encodable {
        let model: String
        let stream: Bool
    }

    /// Streams live pull progress for an Ollama model — the same NDJSON
    /// `/api/pull` endpoint the `ollama pull` CLI itself uses, so the
    /// progress shown here is exactly what the terminal would show.
    func pullOllamaModel(profile: ProviderProfile, name: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let base = try baseURL(for: profile.endpoint)
                    let url = base.deletingLastPathComponent().appendingPathComponent("api/pull")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 3_600
                    request.httpBody = try JSONEncoder().encode(OllamaPullRequest(model: name, stream: true))

                    let (bytes, response) = try await session.bytes(for: request)
                    try await Self.checkStream(response: response, bytes: bytes)

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                              let progress = try? self.decoder.decode(OllamaPullProgress.self, from: data) else { continue }
                        if let error = progress.error, !error.isEmpty {
                            throw APIError.message(error)
                        }
                        continuation.yield(progress)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func streamChat(
        profile: ProviderProfile,
        credential: ProviderCredential,
        model: String,
        thinking: ThinkingLevel = .auto,
        modelInfo: RemoteModel? = nil,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition] = [],
        toolContext: ToolCatalog.ExecutionContext? = nil,
        onEvent: @escaping @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        try Self.requireCredential(profile: profile, credential: credential)

        if profile.kind == .codex && credential.isCodexOAuth {
            try await streamCodex(model: model, credential: credential, thinking: thinking, messages: messages, onEvent: onEvent)
            return
        }

        if profile.kind == .anthropic {
            try await streamAnthropic(model: model, credential: credential, thinking: thinking, modelInfo: modelInfo, messages: messages, tools: tools, toolContext: toolContext, onEvent: onEvent)
            return
        }

        let settings = requestSettings(for: profile.kind, level: thinking, modelInfo: modelInfo)
        var wireMessages = messages.map {
            APIMessage(role: $0.role, text: $0.contentForRequest, imageDataURLs: $0.imageAttachments.map(\.dataURL))
        }

        // Real tool calling loops entirely inside this function: each round
        // either produces a final text reply (streamed to `onEvent` as it
        // arrives, same as before tools existed) or a set of tool calls,
        // which get executed locally and fed back for another round. The
        // caller only ever sees normal delta/usage events plus `.toolUse`
        // for transparency — never the raw multi-round exchange.
        let maxRounds = 5
        for round in 0..<maxRounds {
            let url = try endpointURL(profile: profile, path: "chat/completions")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3_600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            addHeaders(to: &request, profile: profile, credential: credential)

            let body = ChatCompletionBody(
                model: model,
                messages: wireMessages,
                stream: true,
                temperature: thinking == .off ? 0.7 : nil,
                reasoningEffort: settings.reasoningEffort,
                reasoning: settings.reasoning,
                thinking: settings.thinking,
                think: settings.think,
                keepAlive: profile.kind == .ollama ? "10m" : nil
            )
            request.httpBody = try Self.encodeWithTools(body, tools: tools)

            let (bytes, response) = try await session.bytes(for: request)
            try await Self.checkStream(response: response, bytes: bytes)

            var consecutiveParseFailures = 0
            var pendingToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
            var sawToolCalls = false

            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", !payload.isEmpty,
                      let data = payload.data(using: .utf8) else { continue }

                if let message = GenericErrorEnvelope.message(from: data), !message.isEmpty {
                    throw APIError.message(message)
                }
                guard let chunk = try? decoder.decode(StreamChunk.self, from: data) else {
                    consecutiveParseFailures += 1
                    if consecutiveParseFailures >= 3 {
                        throw APIError.message("The response stream could not be parsed.")
                    }
                    continue
                }
                consecutiveParseFailures = 0
                guard let choice = chunk.choices.first else {
                    if let usage = chunk.usage {
                        onEvent(.usage(prompt: usage.promptTokens, completion: usage.completionTokens, cachedTokens: usage.cachedTokens))
                    }
                    continue
                }
                let content = choice.delta.contentText
                let reasoning = choice.delta.reasoningText
                if !content.isEmpty || !reasoning.isEmpty {
                    onEvent(.delta(content: content, reasoning: reasoning))
                }
                if let deltas = choice.delta.toolCalls {
                    sawToolCalls = true
                    for delta in deltas {
                        var existing = pendingToolCalls[delta.index] ?? (id: "", name: "", arguments: "")
                        if let id = delta.id, !id.isEmpty { existing.id = id }
                        if let name = delta.function?.name, !name.isEmpty { existing.name = name }
                        if let args = delta.function?.arguments { existing.arguments += args }
                        pendingToolCalls[delta.index] = existing
                    }
                }
                if let usage = chunk.usage {
                    onEvent(.usage(prompt: usage.promptTokens, completion: usage.completionTokens, cachedTokens: usage.cachedTokens))
                }
            }

            guard sawToolCalls, !pendingToolCalls.isEmpty, let toolContext, round < maxRounds - 1 else { return }

            let calls = pendingToolCalls.sorted { $0.key < $1.key }.map(\.value)
            wireMessages.append(APIMessage(
                role: "assistant",
                text: "",
                imageDataURLs: [],
                toolCalls: calls.map { .init(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments)) }
            ))
            for call in calls {
                let result = await ToolCatalog.execute(name: call.name, argumentsJSON: call.arguments, context: toolContext)
                onEvent(.toolUse(name: call.name, query: ToolCatalog.displayArgument(from: call.arguments), result: result))
                wireMessages.append(APIMessage(role: "tool", text: result, imageDataURLs: [], toolCallID: call.id))
            }
        }
    }

    /// Tool definitions are raw hand-written JSON Schema strings, not
    /// Codable structs — merging them in via `JSONSerialization` after the
    /// rest of the body is encoded is simpler and less error-prone than a
    /// generic "arbitrary JSON passthrough" Encodable type for two tools.
    private static func encodeWithTools(_ body: ChatCompletionBody, tools: [ToolCatalog.Definition]) throws -> Data {
        let encoded = try JSONEncoder().encode(body)
        guard !tools.isEmpty else { return encoded }
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return encoded }
        object["tools"] = tools.map(toolWireObject)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func toolWireObject(_ tool: ToolCatalog.Definition) -> [String: Any] {
        let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] ?? [:]
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": parameters
            ]
        ]
    }

    func streamChatEvents(
        profile: ProviderProfile,
        credential: ProviderCredential,
        model: String,
        thinking: ThinkingLevel = .auto,
        modelInfo: RemoteModel? = nil,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition] = [],
        toolContext: ToolCatalog.ExecutionContext? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamChat(
                        profile: profile,
                        credential: credential,
                        model: model,
                        thinking: thinking,
                        modelInfo: modelInfo,
                        messages: messages,
                        tools: tools,
                        toolContext: toolContext
                    ) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func sendNonStreaming(
        profile: ProviderProfile,
        credential: ProviderCredential,
        model: String,
        messages: [ChatMessage]
    ) async throws -> String {
        let url = try endpointURL(profile: profile, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addHeaders(to: &request, profile: profile, credential: credential)
        request.httpBody = try JSONEncoder().encode(ChatCompletionBody(
            model: model,
            messages: messages.map { APIMessage(role: $0.role, text: $0.contentForRequest, imageDataURLs: $0.imageAttachments.map(\.dataURL)) },
            stream: false,
            temperature: 0.7,
            reasoningEffort: nil,
            reasoning: nil,
            thinking: nil,
            think: nil,
            keepAlive: profile.kind == .ollama ? "10m" : nil
        ))
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let result = try decoder.decode(CompletionResponse.self, from: data)
        return result.choices.first?.message.content ?? ""
    }

    // MARK: Request construction

    private func endpointURL(profile: ProviderProfile, path: String) throws -> URL {
        let base = try baseURL(for: profile.endpoint)
        return base.appendingPathComponent(path)
    }

    private func baseURL(for value: String) throws -> URL {
        var string = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !string.contains("://") { string = "http://" + string }
        while string.hasSuffix("/") { string.removeLast() }
        guard let url = URL(string: string), url.host != nil else {
            throw APIError.message("Invalid endpoint URL: \(value)")
        }
        return url
    }

    private struct RequestSettings {
        let reasoningEffort: String?
        let reasoning: ReasoningOptions?
        let thinking: DeepSeekThinking?
        let think: OllamaThink?
    }

    private func requestSettings(for kind: ProviderKind, level: ThinkingLevel, modelInfo: RemoteModel?) -> RequestSettings {
        if let modelInfo, !modelInfo.supportsReasoning {
            return RequestSettings(reasoningEffort: nil, reasoning: nil, thinking: nil, think: nil)
        }
        switch kind {
        case .deepSeek:
            let deepSeekEffort: String?
            switch level {
            case .auto, .off: deepSeekEffort = nil
            case .low: deepSeekEffort = "low"
            case .medium, .high, .extraHigh: deepSeekEffort = "high"
            case .max: deepSeekEffort = "max"
            }
            return RequestSettings(
                reasoningEffort: deepSeekEffort,
                reasoning: nil,
                thinking: level == .off ? DeepSeekThinking(type: "disabled") : (level == .auto ? nil : DeepSeekThinking(type: "enabled")),
                think: nil
            )
        case .openAI, .compatible, .groq, .mistral, .xai, .google, .blockrun:
            return RequestSettings(reasoningEffort: level.requestValue, reasoning: nil, thinking: nil, think: nil)
        case .openRouter:
            return RequestSettings(
                reasoningEffort: nil,
                reasoning: level.requestValue.map { ReasoningOptions(effort: $0) },
                thinking: nil,
                think: nil
            )
        case .ollama, .lmStudio:
            let value: OllamaThink?
            switch level {
            case .auto: value = nil
            case .off: value = .boolean(false)
            case .low: value = .effort("low")
            case .medium: value = .effort("medium")
            case .high: value = .effort("high")
            case .extraHigh, .max: value = .effort("max")
            }
            return RequestSettings(reasoningEffort: nil, reasoning: nil, thinking: nil, think: value)
        // Codex and Anthropic each have their own dedicated request path with
        // their own thinking/reasoning shape, so this generic mapping is
        // never consulted for them. Perplexity and Preview don't take a
        // reasoning parameter at all.
        case .codex, .preview, .perplexity, .anthropic:
            return RequestSettings(reasoningEffort: nil, reasoning: nil, thinking: nil, think: nil)
        }
    }

    private func supportedReasoningEfforts(from parameters: [String]) -> [String] {
        guard parameters.contains(where: { $0.contains("reasoning") }) else { return [] }
        // Most catalogs advertise the reasoning object but not its enum. The
        // UI then uses the provider's standard effort ladder.
        return ["none", "low", "medium", "high", "xhigh", "max"]
    }

    private func addHeaders(to request: inout URLRequest, profile: ProviderProfile, credential: ProviderCredential) {
        // Anthropic authenticates with `x-api-key` plus a required
        // `anthropic-version` header — not `Authorization: Bearer`, which is
        // what every other provider here uses.
        if profile.kind == .anthropic {
            if let token = credential.token, !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !profile.kind.isLocal, profile.kind != .preview, let token = credential.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if profile.kind == .codex, let accountID = credential.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        if profile.kind == .openRouter {
            request.setValue("https://velachat.local", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("VelaChat", forHTTPHeaderField: "X-Title")
        }
        request.setValue("VelaChat/1.0", forHTTPHeaderField: "User-Agent")
    }

    private func streamCodex(
        model: String,
        credential: ProviderCredential,
        thinking: ThinkingLevel,
        messages: [ChatMessage],
        onEvent: @escaping @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/responses") else {
            throw APIError.message("Invalid Codex endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3_600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        addHeaders(to: &request, profile: ProviderProfile(kind: .codex, name: "Codex", endpoint: "", model: model), credential: credential)
        request.httpBody = try JSONEncoder().encode(CodexResponsesBody(
            model: model,
            thinking: thinking,
            input: messages.map { message in
                // The Responses API requires "output_text" for model-authored
                // turns being replayed as history, and "input_text" for
                // everything else — sending "input_text" unconditionally
                // (as before) made every conversation fail on message two,
                // the moment a prior assistant reply entered the replay.
                let isOutput = message.role == "assistant"
                var contents: [CodexInputContent] = isOutput
                    ? []
                    : message.imageAttachments.map { .image($0.dataURL) }
                let text = message.contentForRequest
                if !text.isEmpty || contents.isEmpty {
                    contents.append(.text(text, isOutput: isOutput))
                }
                return CodexInputMessage(
                    role: message.role == "system" ? "developer" : message.role,
                    content: contents
                )
            }
        ))

        let (bytes, response) = try await session.bytes(for: request)
        try await Self.checkStream(response: response, bytes: bytes)
        var consecutiveParseFailures = 0
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", !payload.isEmpty,
                  let data = payload.data(using: .utf8) else { continue }
            if let message = GenericErrorEnvelope.message(from: data), !message.isEmpty {
                throw APIError.message(message)
            }
            // Matches the generic OpenAI-compatible path's escape hatch
            // (below) — without this, a persistently malformed stream just
            // finished silently with an empty reply instead of a real error.
            guard let event = try? decoder.decode(CodexResponseEvent.self, from: data) else {
                consecutiveParseFailures += 1
                if consecutiveParseFailures >= 3 {
                    throw APIError.message("The response stream could not be parsed.")
                }
                continue
            }
            consecutiveParseFailures = 0
            switch event.type {
            case "response.output_text.delta":
                if let delta = event.delta, !delta.isEmpty { onEvent(.delta(content: delta, reasoning: "")) }
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let delta = event.delta, !delta.isEmpty { onEvent(.delta(content: "", reasoning: delta)) }
            case "response.completed":
                if let usage = event.response?.usage {
                    onEvent(.usage(prompt: usage.inputTokens, completion: usage.outputTokens, cachedTokens: nil))
                }
            default:
                continue
            }
        }
    }

    private func fetchAnthropicModels(profile: ProviderProfile, credential: ProviderCredential) async throws -> [RemoteModel] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=100") else {
            throw APIError.message("Invalid Anthropic endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.discoveryTimeout(for: profile.kind)
        addHeaders(to: &request, profile: profile, credential: credential)
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let payload = try decoder.decode(AnthropicModelListResponse.self, from: data)
        return payload.data.map { RemoteModel(id: $0.id, name: $0.displayName) }
    }

    /// Anthropic's Messages API: a real, separate integration rather than
    /// forcing Claude through the OpenAI chat-completions shape, which
    /// Anthropic's own API does not accept — different endpoint
    /// (`/v1/messages`, not `/v1/chat/completions`), different auth headers
    /// (`x-api-key` + `anthropic-version`, not `Authorization: Bearer`), a
    /// top-level `system` field instead of a `system`-role message, a
    /// required `max_tokens`, and an entirely different SSE event shape
    /// (`content_block_delta` with a `text_delta`/`thinking_delta` payload,
    /// not `choices[].delta.content`).
    private func streamAnthropic(
        model: String,
        credential: ProviderCredential,
        thinking: ThinkingLevel,
        modelInfo: RemoteModel?,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition] = [],
        toolContext: ToolCatalog.ExecutionContext? = nil,
        onEvent: @escaping @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw APIError.message("Invalid Anthropic endpoint")
        }

        // Anthropic rejects a `system`-role message inside the array — every
        // system message (custom instructions, any web-search context) has
        // to be pulled out and joined into the top-level `system` field.
        let systemText = messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n\n")
        let initialTurns = messages
            .filter { $0.role != "system" }
            .map {
                AnthropicMessage(
                    role: $0.role,
                    text: $0.contentForRequest,
                    images: $0.imageAttachments.map { .init(mimeType: $0.mimeType, base64: $0.data.base64EncodedString()) }
                )
            }

        let anthropicThinking = Self.anthropicThinking(for: thinking, modelInfo: modelInfo)
        let baseMaxTokens = modelInfo?.maxOutputTokens ?? 8_192
        let maxTokens = anthropicThinking.map { max(baseMaxTokens, $0.budgetTokens + 4_096) } ?? baseMaxTokens

        // Turns become plain JSON dictionaries from here on. Once tool-call
        // replay messages enter the picture, their shape (`tool_use`/
        // `tool_result` blocks, where `input` is a real nested JSON object,
        // not a string) doesn't fit `AnthropicMessage`'s existing Encodable
        // machinery for the common text/image case — round-tripping through
        // JSONSerialization once here, then working in plain dictionaries,
        // is far simpler than extending Encodable for two more irregular
        // block shapes just for the tool-loop's internal replay messages.
        let initialTurnsData = try JSONEncoder().encode(initialTurns)
        guard var turnsJSON = try JSONSerialization.jsonObject(with: initialTurnsData) as? [[String: Any]] else {
            throw APIError.message("Could not build the Anthropic request.")
        }

        let maxRounds = 5
        for round in 0..<maxRounds {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3_600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            addHeaders(to: &request, profile: ProviderProfile(kind: .anthropic, name: "Anthropic", endpoint: ""), credential: credential)

            var bodyJSON: [String: Any] = [
                "model": model,
                "max_tokens": maxTokens,
                "messages": turnsJSON,
                "stream": true
            ]
            if !systemText.isEmpty {
                // A cache breakpoint on the system block also covers `tools`
                // (rendered ahead of it) per Anthropic's own documented
                // request order — one marker, not one per section. Below
                // the model's minimum cacheable size this is simply a
                // no-op (`cache_creation_input_tokens: 0`), never an error,
                // so it's safe to always attach rather than track each
                // model's exact threshold (512–4096 tokens, and not
                // monotonic across model generations).
                bodyJSON["system"] = [
                    ["type": "text", "text": systemText, "cache_control": ["type": "ephemeral"]]
                ]
            }
            if let anthropicThinking {
                bodyJSON["thinking"] = ["type": "enabled", "budget_tokens": anthropicThinking.budgetTokens]
            }
            if !tools.isEmpty { bodyJSON["tools"] = tools.map(Self.anthropicToolWireObject) }
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyJSON)

            let (bytes, response) = try await session.bytes(for: request)
            try await Self.checkStream(response: response, bytes: bytes)

            var textForThisRound = ""
            var toolBlocks: [Int: (id: String, name: String, json: String)] = [:]
            var consecutiveParseFailures = 0
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
                // Matches the generic OpenAI-compatible path's escape hatch
                // — without this, a persistently malformed stream just
                // finished silently with an empty reply instead of a real
                // error.
                guard let event = try? decoder.decode(AnthropicStreamEvent.self, from: data) else {
                    consecutiveParseFailures += 1
                    if consecutiveParseFailures >= 3 {
                        throw APIError.message("The response stream could not be parsed.")
                    }
                    continue
                }
                consecutiveParseFailures = 0
                switch event.type {
                case "content_block_start":
                    if let block = event.contentBlock, block.type == "tool_use", let index = event.index {
                        toolBlocks[index] = (id: block.id ?? "", name: block.name ?? "", json: "")
                    }
                case "content_block_delta":
                    guard let delta = event.delta else { continue }
                    if delta.type == "text_delta", let text = delta.text, !text.isEmpty {
                        textForThisRound += text
                        onEvent(.delta(content: text, reasoning: ""))
                    } else if delta.type == "thinking_delta", let thinkingText = delta.thinking, !thinkingText.isEmpty {
                        onEvent(.delta(content: "", reasoning: thinkingText))
                    } else if delta.type == "input_json_delta", let index = event.index, let partial = delta.partialJSON {
                        toolBlocks[index]?.json += partial
                    }
                case "message_start":
                    if let usage = event.message?.usage {
                        onEvent(.usage(prompt: usage.inputTokens, completion: usage.outputTokens, cachedTokens: usage.cacheReadInputTokens))
                    }
                case "message_delta":
                    if let usage = event.usage {
                        onEvent(.usage(prompt: nil, completion: usage.outputTokens, cachedTokens: usage.cacheReadInputTokens))
                    }
                case "error":
                    if let message = event.error?.message { throw APIError.message(message) }
                default:
                    continue
                }
            }

            guard !toolBlocks.isEmpty, let toolContext, round < maxRounds - 1 else { return }

            let calls = toolBlocks.sorted { $0.key < $1.key }.map(\.value)
            var assistantContent: [[String: Any]] = []
            if !textForThisRound.isEmpty {
                assistantContent.append(["type": "text", "text": textForThisRound])
            }
            for call in calls {
                let input = (try? JSONSerialization.jsonObject(with: Data(call.json.utf8))) ?? [String: Any]()
                assistantContent.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
            }
            turnsJSON.append(["role": "assistant", "content": assistantContent])

            var toolResultContent: [[String: Any]] = []
            for call in calls {
                let result = await ToolCatalog.execute(name: call.name, argumentsJSON: call.json, context: toolContext)
                onEvent(.toolUse(name: call.name, query: ToolCatalog.displayArgument(from: call.json), result: result))
                toolResultContent.append(["type": "tool_result", "tool_use_id": call.id, "content": result])
            }
            turnsJSON.append(["role": "user", "content": toolResultContent])
        }
    }

    private static func anthropicToolWireObject(_ tool: ToolCatalog.Definition) -> [String: Any] {
        let schema = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] ?? [:]
        return ["name": tool.name, "description": tool.description, "input_schema": schema]
    }

    /// Extended thinking is opt-in on Anthropic's API (unlike the reasoning
    /// knobs every other provider here exposes) and needs an explicit token
    /// budget rather than a named effort level.
    private static func anthropicThinking(for level: ThinkingLevel, modelInfo: RemoteModel?) -> AnthropicThinking? {
        guard modelInfo?.supportsReasoning ?? true else { return nil }
        switch level {
        case .auto, .off: return nil
        case .low: return AnthropicThinking(budgetTokens: 4_000)
        case .medium: return AnthropicThinking(budgetTokens: 8_000)
        case .high: return AnthropicThinking(budgetTokens: 16_000)
        case .extraHigh, .max: return AnthropicThinking(budgetTokens: 32_000)
        }
    }

    static func check(response: URLResponse?, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if let data, let message = GenericErrorEnvelope.message(from: data), !message.isEmpty {
                throw APIError.status(http.statusCode, message)
            }
            // Nothing recognizable parsed out (an HTML proxy error page, a
            // truly malformed body) — fall back to raw text rather than
            // showing nothing, but this is the exception, not the norm.
            let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let trimmed = detail.count > 300 ? String(detail.prefix(300)) + "…" : detail
            throw APIError.status(http.statusCode, trimmed)
        }
    }

    /// Streaming responses hand back an `AsyncBytes` sequence with no upfront
    /// body, so a non-2xx status has to be drained (capped, in case a
    /// misbehaving server streams forever) before its error detail is usable.
    static func checkStream(response: URLResponse?, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
            if collected.count > 8_192 { break }
        }
        try check(response: response, data: collected)
    }

    /// Local/self-hosted servers (Ollama, LM Studio, vLLM…) are commonly slow
    /// to warm up or load a model into memory; hosted providers respond fast
    /// and shouldn't make the user wait 20s to discover a typo'd endpoint.
    static func discoveryTimeout(for kind: ProviderKind) -> TimeInterval {
        switch kind {
        case .ollama, .lmStudio, .compatible: 20
        default: 8
        }
    }

    static func requireCredential(profile: ProviderProfile, credential: ProviderCredential) throws {
        guard profile.kind.requiresKey else { return }
        if profile.kind == .codex && credential.isCodexOAuth {
            guard credential.accountID != nil else {
                throw APIError.message("Codex is signed in, but no ChatGPT account ID was found. Try \"Run codex login\" again in Settings.")
            }
            return
        }
        guard let token = credential.token, !token.isEmpty else {
            throw APIError.message("Add an API key for \(profile.name) in Settings before sending.")
        }
    }
}

// MARK: - Wire models

/// A plain string `content` when there are no images (every request looked
/// like this before attachments existed, and still does for the vast
/// majority) — otherwise the standard OpenAI vision content-part array:
/// `[{"type":"text","text":...},{"type":"image_url","image_url":{"url":...}}]`.
private struct APIMessage: Encodable {
    let role: String
    let text: String
    let imageDataURLs: [String]
    /// Set only on an assistant message that made tool calls — mirrors what
    /// the model actually sent, replayed back so the provider has the full
    /// exchange for the next round.
    var toolCalls: [ToolCallWire] = []
    /// Set only on a `role: "tool"` result message.
    var toolCallID: String?

    struct ToolCallWire: Encodable {
        let id: String
        let type = "function"
        let function: Function
        struct Function: Encodable {
            let name: String
            let arguments: String
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
    private enum PartType: String, Encodable { case text, imageURL = "image_url" }
    private struct TextPart: Encodable {
        let type = PartType.text
        let text: String
    }
    private struct ImageURLPart: Encodable {
        let type = PartType.imageURL
        let imageURL: ImageURL
        struct ImageURL: Encodable {
            let url: String
        }
        private enum CodingKeys: String, CodingKey {
            case type
            case imageURL = "image_url"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let toolCallID { try container.encode(toolCallID, forKey: .toolCallID) }
        if !toolCalls.isEmpty {
            try container.encode(toolCalls, forKey: .toolCalls)
            if !text.isEmpty { try container.encode(text, forKey: .content) }
            return
        }
        guard !imageDataURLs.isEmpty else {
            try container.encode(text, forKey: .content)
            return
        }
        var parts: [any Encodable] = []
        if !text.isEmpty { parts.append(TextPart(text: text)) }
        parts.append(contentsOf: imageDataURLs.map { ImageURLPart(imageURL: .init(url: $0)) })
        var partsContainer = container.nestedUnkeyedContainer(forKey: .content)
        for part in parts { try partsContainer.encode(part) }
    }
}

private struct ChatCompletionBody: Encodable {
    let model: String
    let messages: [APIMessage]
    let stream: Bool
    let temperature: Double?
    let reasoningEffort: String?
    let reasoning: ReasoningOptions?
    let thinking: DeepSeekThinking?
    let think: OllamaThink?
    let keepAlive: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, reasoning, thinking, think
        case reasoningEffort = "reasoning_effort"
        case keepAlive = "keep_alive"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        if let temperature { try container.encode(temperature, forKey: .temperature) }
        if let reasoningEffort { try container.encode(reasoningEffort, forKey: .reasoningEffort) }
        if let reasoning { try container.encode(reasoning, forKey: .reasoning) }
        if let thinking { try container.encode(thinking, forKey: .thinking) }
        if let think { try container.encode(think, forKey: .think) }
        if let keepAlive { try container.encode(keepAlive, forKey: .keepAlive) }
    }
}

private struct ReasoningOptions: Encodable {
    let effort: String
}

private struct DeepSeekThinking: Encodable {
    let type: String
}

private enum OllamaThink: Encodable {
    case boolean(Bool)
    case effort(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .boolean(let value): try container.encode(value)
        case .effort(let value): try container.encode(value)
        }
    }
}

private struct ModelListResponse: Decodable {
    struct Architecture: Decodable {
        let inputModalities: [String]?
        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
        }
    }

    struct TopProvider: Decodable {
        let maxCompletionTokens: Int?
        enum CodingKeys: String, CodingKey {
            case maxCompletionTokens = "max_completion_tokens"
        }
    }

    struct Reasoning: Decodable {
        let supportedEfforts: [String]?
        enum CodingKeys: String, CodingKey {
            case supportedEfforts = "supported_efforts"
        }
    }

    struct Item: Decodable {
        let id: String
        let name: String?
        let description: String?
        let ownedBy: String?
        let contextLength: Int?
        /// blockrun.ai's catalog names this `context_window` instead of
        /// OpenRouter's `context_length` — same meaning, different key.
        let contextWindow: Int?
        let maxOutput: Int?
        /// blockrun.ai tags each model with plain categories
        /// (`"reasoning"`, `"vision"`, `"coding"`) instead of the
        /// `supported_parameters`/`architecture` signals other catalogs use.
        let categories: [String]?
        /// blockrun.ai only — real, server-enforced values are `"free"`,
        /// `"paid"`, `"per_character"`, `"per_track"`, `"per_image"`,
        /// `"per_generation"`, `"per_second"`. Confirmed live: an anonymous
        /// request to a non-`"free"` model returns HTTP 402 Payment Required
        /// (blockrun uses the x402 crypto-micropayment protocol — there's no
        /// traditional login/API-key tier to unlock the rest with).
        let billingMode: String?
        /// Real pricing, in two different documented shapes: OpenRouter's
        /// `prompt`/`completion` are dollars-per-*token* as strings;
        /// blockrun's `input`/`output` are dollars-per-*million-tokens* as
        /// numbers already. Normalized to $/1M in `fetchModels` below.
        let pricing: PricingPayload?
        let architecture: Architecture?
        let topProvider: TopProvider?
        let supportedParameters: [String]?
        let reasoning: Reasoning?

        enum CodingKeys: String, CodingKey {
            case id, name, description, architecture, reasoning, categories, pricing
            case ownedBy = "owned_by"
            case contextLength = "context_length"
            case contextWindow = "context_window"
            case maxOutput = "max_output"
            case topProvider = "top_provider"
            case supportedParameters = "supported_parameters"
            case billingMode = "billing_mode"
        }
    }
    struct PricingPayload: Decodable {
        let prompt: String?
        let completion: String?
        let input: Double?
        let output: Double?
    }
    let data: [Item]
}

private struct OllamaTagsResponse: Decodable {
    struct Details: Decodable {
        let family: String?
        let parameterSize: String?
        let quantizationLevel: String?
        let families: [String]?
        enum CodingKeys: String, CodingKey {
            case family
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
            case families
        }
    }

    struct Item: Decodable {
        let name: String
        let size: Int64?
        let details: Details?
    }
    let models: [Item]
}

private struct SearXNGResponse: Decodable {
    struct Result: Decodable {
        let title: String
        let url: String
        let content: String?
    }
    let results: [Result]
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct ToolCallDelta: Decodable {
            struct FunctionDelta: Decodable {
                let name: String?
                let arguments: String?
            }
            let index: Int
            let id: String?
            let function: FunctionDelta?
        }
        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?
            let reasoning: String?
            let toolCalls: [ToolCallDelta]?
            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
            var contentText: String { content ?? "" }
            var reasoningText: String { reasoningContent ?? reasoning ?? "" }
        }
        let delta: Delta
        let finishReason: String?
        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    struct Usage: Decodable {
        /// OpenAI's real, automatic (zero client opt-in) prompt-cache
        /// reporting — nested under `prompt_tokens_details`.
        struct PromptTokensDetails: Decodable {
            let cachedTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
        }
        let promptTokens: Int?
        let completionTokens: Int?
        let promptTokensDetails: PromptTokensDetails?
        /// DeepSeek reports its own (also automatic) disk-based cache the
        /// same way, but as a flat field with a different name rather than
        /// OpenAI's nested shape.
        let promptCacheHitTokens: Int?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptTokensDetails = "prompt_tokens_details"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
        }
        var cachedTokens: Int? { promptTokensDetails?.cachedTokens ?? promptCacheHitTokens }
    }
    let choices: [Choice]
    let usage: Usage?
}

private struct CodexResponsesBody: Encodable {
    let model: String
    let input: [CodexInputMessage]
    let stream = true
    let store = false
    let reasoning: CodexReasoning?

    enum CodingKeys: String, CodingKey {
        case model, input, stream, store, reasoning
    }

    init(model: String, thinking: ThinkingLevel, input: [CodexInputMessage]) {
        self.model = model
        self.reasoning = thinking == .auto ? nil : CodexReasoning(effort: thinking.codexValue)
        self.input = input
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(input, forKey: .input)
        try container.encode(stream, forKey: .stream)
        try container.encode(store, forKey: .store)
        if let reasoning { try container.encode(reasoning, forKey: .reasoning) }
    }
}

private struct CodexReasoning: Encodable {
    let effort: String
    let summary = "auto"
}

private struct CodexInputMessage: Encodable {
    let role: String
    let content: [CodexInputContent]
}

private struct CodexInputContent: Encodable {
    let type: String
    let text: String?
    let imageURL: String?

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    static func text(_ value: String, isOutput: Bool) -> CodexInputContent {
        CodexInputContent(type: isOutput ? "output_text" : "input_text", text: value, imageURL: nil)
    }
    static func image(_ dataURL: String) -> CodexInputContent {
        CodexInputContent(type: "input_image", text: nil, imageURL: dataURL)
    }
}

private struct CodexResponseEvent: Decodable {
    struct Response: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
        let usage: Usage?
    }
    let type: String
    let delta: String?
    let response: Response?
}

/// Plain string `content` with no images (the common case), otherwise
/// Anthropic's real content-block array — `{"type":"image","source":
/// {"type":"base64","media_type":...,"data":...}}` blocks before the text
/// block, the ordering Anthropic's own docs recommend for best results.
private struct AnthropicMessage: Encodable {
    struct ImageSource {
        let mimeType: String
        let base64: String
    }
    let role: String
    let text: String
    let images: [ImageSource]

    private enum CodingKeys: String, CodingKey { case role, content }
    private enum PartType: String, Encodable { case text, image }
    private struct TextPart: Encodable {
        let type = PartType.text
        let text: String
    }
    private struct ImagePart: Encodable {
        let type = PartType.image
        let source: Source
        struct Source: Encodable {
            let type = "base64"
            let mediaType: String
            let data: String
            private enum CodingKeys: String, CodingKey {
                case type
                case mediaType = "media_type"
                case data
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        guard !images.isEmpty else {
            try container.encode(text, forKey: .content)
            return
        }
        var parts: [any Encodable] = images.map { ImagePart(source: .init(mediaType: $0.mimeType, data: $0.base64)) }
        if !text.isEmpty { parts.append(TextPart(text: text)) }
        var partsContainer = container.nestedUnkeyedContainer(forKey: .content)
        for part in parts { try partsContainer.encode(part) }
    }
}

private struct AnthropicThinking: Encodable {
    let type = "enabled"
    let budgetTokens: Int

    init(budgetTokens: Int) {
        self.budgetTokens = budgetTokens
    }

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

private struct AnthropicModelListResponse: Decodable {
    struct Item: Decodable {
        let id: String
        let displayName: String?
        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }
    let data: [Item]
}

private struct AnthropicStreamEvent: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let id: String?
        let name: String?
    }
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        /// `input_json_delta` — a fragment of a `tool_use` block's `input`
        /// object, accumulated across chunks the same way OpenAI-style
        /// `tool_calls[].function.arguments` fragments are.
        let partialJSON: String?
        enum CodingKeys: String, CodingKey {
            case type, text, thinking
            case partialJSON = "partial_json"
        }
    }
    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }
    struct MessageEnvelope: Decodable {
        let usage: Usage?
    }
    struct ErrorBody: Decodable {
        let message: String?
    }

    let type: String
    let index: Int?
    let contentBlock: ContentBlock?
    let delta: Delta?
    let message: MessageEnvelope?
    let usage: Usage?
    let error: ErrorBody?

    enum CodingKeys: String, CodingKey {
        case type, index, delta, message, usage, error
        case contentBlock = "content_block"
    }
}

private struct CompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

/// Providers use two different failure shapes for the same `"error"` key:
/// most nest the message under an object (`{"error":{"message":"..."}}`),
/// but Ollama — and some other simple servers — return it as a bare string
/// (`{"error":"..."}`). Decoding either means `check`/the streaming error
/// paths can surface the provider's actual sentence instead of either a raw
/// JSON dump or silently missing Ollama's error text entirely.
private struct GenericErrorEnvelope: Decodable {
    let message: String?

    private enum CodingKeys: String, CodingKey { case error }
    private struct NestedError: Decodable { let message: String? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.decode(NestedError.self, forKey: .error) {
            message = nested.message
        } else if let flat = try? container.decode(String.self, forKey: .error) {
            message = flat
        } else {
            message = nil
        }
    }

    static func message(from data: Data) -> String? {
        try? JSONDecoder().decode(GenericErrorEnvelope.self, from: data).message
    }
}

enum APIError: Error, LocalizedError {
    case status(Int, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .status(let code, let detail):
            let suffix = detail.isEmpty ? "" : " \(detail)"
            return "Request failed (\(code)).\(suffix)"
        case .message(let message): return message
        }
    }
}

// MARK: - Offline preview

enum PreviewResponder {
    static func stream(for prompt: String, model: String, emit: @escaping @MainActor (String) -> Void) async throws {
        let response: String
        let lower = prompt.lowercased()
        if lower.contains("hello") || lower == "hi" {
            response = "Hey — this is the offline Preview provider. Pick DeepSeek, OpenRouter, Ollama, OpenAI, or any compatible endpoint in Settings when you’re ready to use a real model."
        } else if lower.contains("provider") || lower.contains("connect") {
            response = "Chat keeps each provider separate. Your keys live in macOS Keychain, while endpoints and model names stay in your local settings. Try Ollama for a private local model, DeepSeek for a fast hosted API, or OpenRouter when you want a live model catalog."
        } else {
            response = "I’m the local preview response for “\(prompt)”. Connect a provider from Settings to stream a real answer into this conversation."
        }
        let words = response.split(separator: " ", omittingEmptySubsequences: true)
        for (index, word) in words.enumerated() {
            try Task.checkCancellation()
            await emit(String(word) + (index == words.count - 1 ? "" : " "))
            try await Task.sleep(nanoseconds: UInt64.random(in: 16_000_000...44_000_000))
        }
    }
}
