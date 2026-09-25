import Foundation

public struct ProviderCredential: Sendable {

    public init(token: String?, accountID: String?, isCodexOAuth: Bool) {
        self.token = token
        self.accountID = accountID
        self.isCodexOAuth = isCodexOAuth
    }
    public let token: String?
    public let accountID: String?
    public let isCodexOAuth: Bool
}

public final class CompatibleChatClient: @unchecked Sendable {
    public static let shared = CompatibleChatClient()

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let streamUsageCapabilityLock = NSLock()
    private var streamUsageCapabilityByEndpoint: [String: Bool] = [:]

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        session = URLSession(configuration: configuration)
    }

    /// Queries a self-hosted or public SearXNG instance's JSON API — free,
    /// keyless metasearch, per the explicit "permanently free, no key"
    /// requirement (a commercial keyed API, or Ollama's own hosted search,
    /// were both ruled out for exactly that reason).
    public func searchWeb(query: String, endpoint: String) async throws -> [WebSearchResult] {
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
        try EgressPolicy.check(url)
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

    /// Reads rate-limit/quota headers without decoding a catalog. There is
    /// no read-only usage endpoint on these providers, so the only honest
    /// way to get fresh numbers is to make a real request and look at what
    /// comes back — `/models` is the cheapest one that exists everywhere,
    /// and the app already calls it routinely for discovery.
    public func probeQuotaHeaders(profile: ProviderProfile, credential: ProviderCredential) async -> QuotaSnapshot? {
        guard profile.kind.speaksOpenAIProtocol || profile.kind == .anthropic else { return nil }
        guard let url = try? endpointURL(profile: profile, path: "models") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        addHeaders(to: &request, profile: profile, credential: credential)
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return QuotaSnapshot(headers: http.allHeaderFields)
    }

    /// OpenRouter key credits — the one key-based provider with a real
    /// read-only usage endpoint. `GET /api/v1/auth/key` returns
    /// `{data: {label, usage, limit}}` in credits (dollars); `limit` is
    /// null when the key has no cap. Everything is optional: anything
    /// unrecognized yields nil rather than a wrong number.
    public func fetchOpenRouterKeyCredit(
        profile: ProviderProfile,
        credential: ProviderCredential
    ) async -> OpenRouterKeyCredit? {
        guard profile.kind == .openRouter else { return nil }
        guard let token = credential.token, !token.isEmpty else { return nil }
        guard let url = try? endpointURL(profile: profile, path: "auth/key") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        addHeaders(to: &request, profile: profile, credential: credential)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let payload = try? decoder.decode(OpenRouterKeyResponse.self, from: data),
              let info = payload.data, let usage = info.usage else { return nil }
        return OpenRouterKeyCredit(usedCredits: usage, limitCredits: info.limit, label: info.label)
    }

    public func fetchModels(profile: ProviderProfile, credential: ProviderCredential) async throws -> [RemoteModel] {
        if profile.kind == .codex && credential.isCodexOAuth {
            return ModelCatalog.curated(for: .codex)
        }
        if profile.kind == .claudeCode {
            guard ClaudeBridge.installedPath != nil else {
                throw APIError.message("Claude Code isn't installed. Install it and run `claude` once to sign in.")
            }
            return ModelCatalog.curated(for: .claudeCode)
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
            let allocatedContexts = (try? await fetchOllamaRunningContexts(profile: profile)) ?? [:]
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
                        let scope = ModelEvidenceScope(profile: profile, requestedModel: item.name, effectiveModel: item.name)
                        var contextEvidence: [ContextLimitEvidence] = []
                        if let capacity = show?.contextLength, capacity > 0 {
                            contextEvidence.append(ContextLimitEvidence(
                                value: capacity,
                                source: .providerCatalog,
                                scope: scope,
                                detail: "Ollama /api/show model capacity"
                            ))
                        }
                        if let allocated = allocatedContexts[item.name.lowercased()], allocated > 0 {
                            contextEvidence.append(ContextLimitEvidence(
                                value: allocated,
                                source: .runtimeConfiguration,
                                scope: scope,
                                detail: "Ollama /api/ps allocated context",
                                observedAt: Date()
                            ))
                        }
                        contextEvidence.append(contentsOf: Self.curatedContextEvidence(modelID: item.name, scope: scope))
                        let vision = capabilities.isEmpty
                            ? item.details?.families?.contains(where: { $0.lowercased().contains("clip") || $0.lowercased().contains("vision") })
                            : capabilities.contains("vision")
                        return RemoteModel(
                            id: item.name,
                            name: item.name,
                            parameterSize: item.details?.parameterSize,
                            sizeBytes: item.size,
                            quantizationLevel: item.details?.quantizationLevel,
                            isCloudHosted: isCloud,
                            supportsReasoning: capabilities.isEmpty ? nil : capabilities.contains("thinking"),
                            supportsVision: vision,
                            supportsTools: capabilities.isEmpty ? nil : capabilities.contains("tools"),
                            isLocal: true,
                            contextLimitEvidence: contextEvidence
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

        // Google's OpenAI-compatible catalog omits the limits published by
        // the native models.list API. Prefer that exact native metadata on the
        // official host, while retaining the compatible path for gateways.
        if profile.kind == .google,
           let native = try? await fetchGeminiModels(profile: profile, credential: credential),
           !native.isEmpty {
            return native
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
        return items.map { Self.remoteModel(from: $0, profile: profile) }
    }

    /// OpenRouter single-model lookup. Verified live against the real API:
    /// `GET /api/v1/model/:slug` returns `{data: <the same Item shape as
    /// the /models list>}`, with aliases resolving server-side. Other
    /// providers expose no equivalent per-model endpoint — callers gate on
    /// `.openRouter` rather than probing every compatible host.
    public func fetchModel(profile: ProviderProfile, credential: ProviderCredential, modelID: String) async throws -> RemoteModel {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.message("Enter a model ID first.") }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        let url = try endpointURL(profile: profile, path: "model/\(encoded)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.discoveryTimeout(for: profile.kind)
        addHeaders(to: &request, profile: profile, credential: credential)
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let payload = try decoder.decode(SingleModelResponse.self, from: data)
        return Self.remoteModel(from: payload.data, profile: profile)
    }

    /// The shared Item → RemoteModel mapping for both the bulk catalog
    /// fetch and the single-model lookup above. Internal (not private) so
    /// the catalog tests can pin the top_provider precedence directly.
    static func remoteModel(from item: ModelListResponse.Item, profile: ProviderProfile) -> RemoteModel {
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
        let scope = ModelEvidenceScope(profile: profile, requestedModel: item.id, effectiveModel: item.id)
        let providerContext = item.topProvider?.contextLength
            ?? item.contextLength
            ?? item.contextWindow
            ?? item.inputTokenLimit
        let providerOutput = item.topProvider?.maxCompletionTokens
            ?? item.maxOutput
            ?? item.outputTokenLimit
        var outputEvidence: [OutputLimitEvidence] = []
        if providerOutput == nil, deepSeekModel {
            outputEvidence.append(OutputLimitEvidence(
                value: 384_000,
                source: .bundledSnapshot,
                scope: scope,
                detail: "VelaChat bundled DeepSeek metadata"
            ))
        }
        let curatedContext = Self.curatedContextEvidence(modelID: item.id, scope: scope)
        return RemoteModel(
            id: item.id,
            ownedBy: item.ownedBy,
            name: item.name,
            description: item.description,
            contextLength: providerContext,
            maxOutputTokens: providerOutput,
            supportsReasoning: reasoning ? true : nil,
            supportsVision: vision ? true : nil,
            supportsTools: tools ? true : nil,
            supportedEfforts: advertisedEfforts.isEmpty ? supportedReasoningEfforts(from: normalized) : advertisedEfforts,
            inputPricePerMillion: inputPrice,
            outputPricePerMillion: outputPrice,
            contextLimitEvidence: curatedContext,
            outputLimitEvidence: outputEvidence,
            evidenceScope: scope,
            scalarEvidenceSource: .providerCatalog,
            scalarEvidenceDetail: profile.kind == .openRouter
                ? "OpenRouter model catalog / top_provider"
                : "\(profile.kind.rawValue) model catalog"
        )
    }

    /// Exact, provider-native input token counting for providers that expose
    /// it. The caller is responsible for caching by its prepared-request
    /// fingerprint; this method always performs one live count.
    public func countInputTokens(
        profile: ProviderProfile,
        credential: ProviderCredential,
        model: String,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition] = []
    ) async throws -> ProviderInputTokenCount {
        try Self.requireCredential(profile: profile, credential: credential)
        switch profile.kind {
        case .openAI:
            return try await countOpenAIInputTokens(
                profile: profile,
                credential: credential,
                model: model,
                messages: messages,
                tools: tools
            )
        case .anthropic:
            return try await countAnthropicInputTokens(
                profile: profile,
                credential: credential,
                model: model,
                messages: messages,
                tools: tools
            )
        case .google:
            return try await countGeminiInputTokens(
                profile: profile,
                credential: credential,
                model: model,
                messages: messages,
                tools: tools
            )
        default:
            throw APIError.message("\(profile.kind.rawValue) does not expose a supported exact token-count endpoint.")
        }
    }

    public func countInputTokens(
        profile: ProviderProfile,
        credential: ProviderCredential,
        preparedRequest: PreparedRequest
    ) async throws -> ProviderInputTokenCount {
        guard preparedRequest.providerID == profile.id,
              preparedRequest.endpointFingerprint == ModelEvidenceScope.fingerprint(endpoint: profile.endpoint) else {
            throw APIError.message("The prepared request belongs to a different provider endpoint.")
        }
        return try await countInputTokens(
            profile: profile,
            credential: credential,
            model: preparedRequest.wireModel,
            messages: preparedRequest.messages,
            tools: preparedRequest.tools
        )
    }

    private func countOpenAIInputTokens(
        profile: ProviderProfile,
        credential: ProviderCredential,
        model: String,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition]
    ) async throws -> ProviderInputTokenCount {
        let url = try endpointURL(profile: profile, path: "responses/input_tokens")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addHeaders(to: &request, profile: profile, credential: credential)
        request.httpBody = try Self.openAIInputTokenCountBody(model: model, messages: messages, tools: tools)
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let payload = try decoder.decode(OpenAIInputTokenCountResponse.self, from: data)
        return ProviderInputTokenCount(inputTokens: payload.inputTokens, provider: .openAI, requestedModel: model)
    }

    static func openAIInputTokenCountBody(
        model: String,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition]
    ) throws -> Data {
        let input: [[String: Any]] = messages.map { message in
            var content: [[String: Any]] = []
            if !message.contentForRequest.isEmpty || message.imageAttachments.isEmpty {
                content.append(["type": "input_text", "text": message.contentForRequest])
            }
            content.append(contentsOf: message.imageAttachments.map {
                ["type": "input_image", "image_url": $0.dataURL, "detail": "auto"]
            })
            return ["type": "message", "role": message.role, "content": content]
        }
        var body: [String: Any] = ["model": model, "input": input]
        if !tools.isEmpty { body["tools"] = tools.map(Self.responsesToolWireObject) }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func countAnthropicInputTokens(
        profile: ProviderProfile,
        credential: ProviderCredential,
        model: String,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition]
    ) async throws -> ProviderInputTokenCount {
        guard let url = Self.anthropicURL(profile: profile, path: "/messages/count_tokens") else {
            throw APIError.message("Invalid Anthropic endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addHeaders(to: &request, profile: profile, credential: credential)
        request.httpBody = try Self.anthropicInputTokenCountBody(model: model, messages: messages, tools: tools)
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let payload = try decoder.decode(AnthropicInputTokenCountResponse.self, from: data)
        return ProviderInputTokenCount(inputTokens: payload.inputTokens, provider: .anthropic, requestedModel: model)
    }

    static func anthropicInputTokenCountBody(
        model: String,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition]
    ) throws -> Data {
        let systemText = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != "system" }.map {
            AnthropicMessage(
                role: $0.role,
                text: $0.contentForRequest,
                images: $0.imageAttachments.map { .init(mimeType: $0.mimeType, base64: $0.data.base64EncodedString()) }
            )
        }
        let turnsData = try JSONEncoder().encode(turns)
        guard var turnsJSON = try JSONSerialization.jsonObject(with: turnsData) as? [[String: Any]] else {
            throw APIError.message("Could not build the Anthropic token-count request.")
        }
        AnthropicPromptCache.markLatestTurn(&turnsJSON)
        var body: [String: Any] = ["model": model, "messages": turnsJSON]
        if !systemText.isEmpty {
            body["system"] = [["type": "text", "text": systemText, "cache_control": ["type": "ephemeral"]]]
        }
        if !tools.isEmpty { body["tools"] = tools.map(Self.anthropicToolWireObject) }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func countGeminiInputTokens(
        profile: ProviderProfile,
        credential: ProviderCredential,
        model: String,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition]
    ) async throws -> ProviderInputTokenCount {
        guard let endpoint = URL(string: profile.endpoint),
              endpoint.host?.lowercased() == "generativelanguage.googleapis.com",
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw APIError.message("Gemini exact token counting requires the official Gemini endpoint.")
        }
        let leafModel = model.split(separator: "/").last.map(String.init) ?? model
        components.path = "/v1beta/models/\(leafModel):countTokens"
        components.query = nil
        guard let url = components.url else { throw APIError.message("Invalid Gemini token-count endpoint") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = credential.token, !token.isEmpty { request.setValue(token, forHTTPHeaderField: "x-goog-api-key") }
        request.httpBody = try Self.geminiInputTokenCountBody(model: leafModel, messages: messages, tools: tools)
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let payload = try decoder.decode(GeminiInputTokenCountResponse.self, from: data)
        return ProviderInputTokenCount(inputTokens: payload.totalTokens, provider: .google, requestedModel: model)
    }

    static func geminiInputTokenCountBody(
        model: String,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition]
    ) throws -> Data {
        let systemText = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let contents: [[String: Any]] = messages.filter { $0.role != "system" }.map { message in
            var parts: [[String: Any]] = []
            if !message.contentForRequest.isEmpty { parts.append(["text": message.contentForRequest]) }
            parts.append(contentsOf: message.imageAttachments.map {
                ["inlineData": ["mimeType": $0.mimeType, "data": $0.data.base64EncodedString()]]
            })
            return ["role": message.role == "assistant" ? "model" : "user", "parts": parts]
        }
        // The model is encoded in the REST path (`models/{id}:countTokens`),
        // not inside GenerateContentRequest.
        var generationRequest: [String: Any] = ["contents": contents]
        if !systemText.isEmpty { generationRequest["systemInstruction"] = ["parts": [["text": systemText]]] }
        if !tools.isEmpty {
            generationRequest["tools"] = [["functionDeclarations": tools.map(Self.geminiToolWireObject)]]
        }
        return try JSONSerialization.data(withJSONObject: ["generateContentRequest": generationRequest])
    }

    private struct OllamaShowRequest: Encodable {
        let model: String
    }

    private static func curatedContextEvidence(modelID: String, scope: ModelEvidenceScope) -> [ContextLimitEvidence] {
        guard let value = ContextWindowTable.contextLength(for: modelID) else { return [] }
        return [ContextLimitEvidence(
            value: value,
            source: .curatedFamily,
            scope: scope,
            exactModelMatch: false,
            detail: "VelaChat documented family fallback"
        )]
    }

    /// Runtime allocations from `/api/ps`, keyed by every exact model name
    /// Ollama provides. This is intentionally separate from `/api/show`'s
    /// maximum model capacity: the allocated `context_length` is the limit a
    /// request can actually use right now.
    private func fetchOllamaRunningContexts(profile: ProviderProfile) async throws -> [String: Int] {
        let base = try baseURL(for: profile.endpoint)
        let url = base.deletingLastPathComponent().appendingPathComponent("api/ps")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let payload = try decoder.decode(OllamaProcessesResponse.self, from: data)
        var result: [String: Int] = [:]
        for item in payload.models {
            guard let value = item.contextLength, value > 0 else { continue }
            if let name = item.name, !name.isEmpty { result[name.lowercased()] = value }
            if let model = item.model, !model.isEmpty { result[model.lowercased()] = value }
        }
        return result
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
    public struct OllamaPullProgress: Decodable, Sendable {
        public let status: String
        public let digest: String?
        public let total: Int64?
        public let completed: Int64?
        public let error: String?
    }

    private struct OllamaPullRequest: Encodable {
        let model: String
        let stream: Bool
    }

    /// Streams live pull progress for an Ollama model — the same NDJSON
    /// `/api/pull` endpoint the `ollama pull` CLI itself uses, so the
    /// progress shown here is exactly what the terminal would show.
    public func pullOllamaModel(profile: ProviderProfile, name: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let base = try baseURL(for: profile.endpoint)
                    let url = base.deletingLastPathComponent().appendingPathComponent("api/pull")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = Limits.streamIdleTimeout  // idle: reset by every received byte
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

    public func streamChat(
        profile: ProviderProfile,
        credential: ProviderCredential,
        model: String,
        thinking: ThinkingLevel = .auto,
        modelInfo: RemoteModel? = nil,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition] = [],
        toolContext: ToolCatalog.ExecutionContext? = nil,
        conversationKey: UUID? = nil,
        purpose: UsagePurpose = .chat,
        requestedOutputTokens: Int? = nil,
        telemetryRequestedModel: String? = nil,
        onEvent: @escaping @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        try Self.requireCredential(profile: profile, credential: credential)
        let usageRequestedModel = telemetryRequestedModel ?? model

        if profile.kind == .codex && credential.isCodexOAuth {
            try await streamCodex(profile: profile, model: model, credential: credential, thinking: thinking, messages: messages, tools: tools, toolContext: toolContext, purpose: purpose, onEvent: onEvent)
            return
        }

        if profile.kind == .claudeCode {
            try await streamClaudeCode(profile: profile, model: model, messages: messages, toolContext: toolContext, purpose: purpose, onEvent: onEvent)
            return
        }

        if profile.kind == .chatGPT {
            // The web conduit reports no token counts, but the turn still
            // happened: emit one metrics-free row so ChatGPT chats appear
            // in turn counts instead of vanishing from usage entirely.
            // Nil metrics mean "unreported", never zero (see RequestUsage).
            let startedAt = Date()
            do {
                try await ChatGPTWebChat.stream(conversationKey: conversationKey, model: model, thinking: thinking, messages: messages, onEvent: onEvent)
            } catch {
                onEvent(.requestUsage(RequestUsage(
                    providerID: profile.id,
                    requestedModelID: model,
                    effectiveModelID: model,
                    purpose: purpose,
                    outcome: Task.isCancelled ? .cancelled : .failed,
                    latencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
                )))
                throw error
            }
            onEvent(.requestUsage(RequestUsage(
                providerID: profile.id,
                requestedModelID: model,
                effectiveModelID: model,
                purpose: purpose,
                outcome: .succeeded,
                latencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
            )))
            return
        }

        if profile.kind == .anthropic {
            try await streamAnthropic(profile: profile, model: model, credential: credential, thinking: thinking, modelInfo: modelInfo, messages: messages, tools: tools, toolContext: toolContext, purpose: purpose, requestedOutputTokens: requestedOutputTokens, onEvent: onEvent)
            return
        }

        // Note for anyone adding caching here: OpenAI-compatible providers
        // cache automatically on an exact prefix match and expose no knob at
        // all. Anthropic's `cache_control` blocks are not part of this wire
        // format — sending them to an OpenAI-shaped endpoint is at best
        // ignored and at worst a 400 on strict-schema gateways. "OpenAI-
        // compatible" is a claim, not a guarantee (see AGENTS.md).
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
        // Adaptive budget: up to 10 rounds, but a round of tool calls
        // identical to earlier ones short-circuits — repetition is the
        // loop-detection signal, not just a hard cap.
        let maxRounds = Limits.maxToolRounds
        var usageTotals = ToolLoopUsage()
        var toolsDisabled = false
        var seenCallSignatures = Set<String>()
        var lastFinishReason: String?
        // Tool-result messages still being replayed verbatim, with the round
        // that produced them. Every round resends the whole exchange, so a
        // large result from round 2 is re-billed in rounds 3…N — that is the
        // quadratic term. Entries leave this list once condensed, which also
        // makes the rewrite idempotent.
        var verbatimToolResults: [(round: Int, index: Int)] = []
        for round in 0..<maxRounds {
            var stillVerbatim: [(round: Int, index: Int)] = []
            for entry in verbatimToolResults {
                if ToolResultReplay.shouldCondense(round: entry.round, currentRound: round) {
                    wireMessages[entry.index].text = ToolResultReplay.condensed(wireMessages[entry.index].text)
                } else {
                    stillVerbatim.append(entry)
                }
            }
            verbatimToolResults = stillVerbatim
            let url = try endpointURL(profile: profile, path: "chat/completions")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = Limits.streamIdleTimeout  // idle: reset by every received byte
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            addHeaders(to: &request, profile: profile, credential: credential)

            let includeStreamingUsage = shouldIncludeStreamingUsage(for: profile)
            let body = ChatCompletionBody(
                model: model,
                messages: wireMessages,
                stream: true,
                temperature: thinking == .off ? 0.7 : nil,
                reasoningEffort: settings.reasoningEffort,
                reasoning: settings.reasoning,
                thinking: settings.thinking,
                think: settings.think,
                keepAlive: profile.kind == .ollama ? "10m" : nil,
                streamOptions: includeStreamingUsage ? StreamOptions(includeUsage: true) : nil
            )
            request.httpBody = try Self.encodeWithTools(body, tools: (round < maxRounds - 1 && !toolsDisabled) ? tools : [])

            let requestUsageID = UUID()
            let requestStartedAt = Date()
            var didEmitRequestUsage = false
            var latestRoundUsage: StreamChunk.Usage?
            var effectiveModel = model
            var requestQuota: QuotaSnapshot?
            defer {
                if !didEmitRequestUsage {
                    onEvent(.requestUsage(Self.compatibleRequestUsage(
                        id: requestUsageID,
                        profile: profile,
                        requestedModel: usageRequestedModel,
                        effectiveModel: effectiveModel,
                        purpose: round == 0 ? purpose : .toolRound,
                        outcome: Task.isCancelled ? .cancelled : .failed,
                        usage: latestRoundUsage,
                        latencyMilliseconds: Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                        quota: requestQuota
                    )))
                }
            }
            let (bytes, response, retriedWithoutUsage) = try await openChatCompletionStream(
                request: request,
                profile: profile,
                includedUsage: includeStreamingUsage
            )
            if retriedWithoutUsage {
                onEvent(.requestUsage(RequestUsage(
                    providerID: profile.id,
                    requestedModelID: usageRequestedModel,
                    effectiveModelID: model,
                    purpose: round == 0 ? purpose : .toolRound,
                    outcome: .failed
                )))
            }
            if let http = response as? HTTPURLResponse, let quota = QuotaSnapshot(headers: http.allHeaderFields) {
                requestQuota = quota
                onEvent(.quota(quota))
            }

            var consecutiveParseFailures = 0
            var pendingToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
            var sawToolCalls = false
            var textForThisRound = ""
            var refusalForThisRound = ""

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
                if let reportedModel = chunk.model, !reportedModel.isEmpty { effectiveModel = reportedModel }
                if let usage = chunk.usage {
                    latestRoundUsage = latestRoundUsage.map { $0.merging(usage) } ?? usage
                }
                guard let choice = chunk.choices.first else {
                    if let usage = chunk.usage {
                        let totals = usageTotals.observe(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens)
                        onEvent(.usage(prompt: totals.prompt, completion: totals.completion, cachedTokens: totals.cached, cacheCreation: totals.cacheCreation))
                    }
                    continue
                }
                if let reason = choice.finishReason, !reason.isEmpty { lastFinishReason = reason }
                let content = choice.delta.contentText
                let reasoning = choice.delta.reasoningText
                if !content.isEmpty { textForThisRound += content }
                if !content.isEmpty || !reasoning.isEmpty {
                    onEvent(.delta(content: content, reasoning: reasoning))
                }
                if let refusal = choice.delta.refusal, !refusal.isEmpty { refusalForThisRound += refusal }
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
                    let totals = usageTotals.observe(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens)
                    onEvent(.usage(prompt: totals.prompt, completion: totals.completion, cachedTokens: totals.cached, cacheCreation: totals.cacheCreation))
                }
            }

            onEvent(.requestUsage(Self.compatibleRequestUsage(
                id: requestUsageID,
                profile: profile,
                requestedModel: usageRequestedModel,
                effectiveModel: effectiveModel,
                purpose: round == 0 ? purpose : .toolRound,
                outcome: refusalForThisRound.isEmpty ? .succeeded : .refused,
                usage: latestRoundUsage,
                latencyMilliseconds: Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                quota: requestQuota
            )))
            didEmitRequestUsage = true
            if effectiveModel.caseInsensitiveCompare(model) != .orderedSame {
                onEvent(.modelMetadata(RuntimeModelMetadata(
                    requestedModel: usageRequestedModel,
                    effectiveModel: effectiveModel
                )))
            }

            guard sawToolCalls, !pendingToolCalls.isEmpty, let toolContext, round < maxRounds - 1, !toolsDisabled else {
                // An official refusal is the round's answer — emitted whole,
                // once, so the transcript renders one typed refusal row
                // rather than a stream of fragments.
                if !refusalForThisRound.isEmpty {
                    onEvent(.refusal(refusalForThisRound))
                }
                onEvent(.finished(reason: lastFinishReason))
                return
            }
            usageTotals.finishRound()

            let calls = pendingToolCalls.sorted { $0.key < $1.key }.map(\.value)
            // The model's own preamble text from this round is replayed with
            // the tool calls — dropping it (as this loop originally did)
            // made the model lose its own train of thought between rounds.
            wireMessages.append(APIMessage(
                role: "assistant",
                text: textForThisRound,
                imageDataURLs: [],
                toolCalls: calls.map { .init(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments)) }
            ))
            // Loop detection: a round consisting entirely of calls already
            // made (same tool, same arguments) is a stuck model — answer
            // the calls synthetically, tell it to stop, and pull the tools.
            let signatures = calls.map { "\($0.name)|\($0.arguments)" }
            let allRepeated = signatures.allSatisfy(seenCallSignatures.contains)
            seenCallSignatures.formUnion(signatures)
            if allRepeated {
                for call in calls {
                    wireMessages.append(APIMessage(role: "tool", text: "Duplicate of an identical earlier call — its result has not changed. Answer with what you already have.", imageDataURLs: [], toolCallID: call.id))
                }
                wireMessages.append(APIMessage(role: "system", text: "You repeated identical tool calls. Stop calling tools and answer now.", imageDataURLs: []))
                let noteID = UUID()
                onEvent(.activityStarted(id: noteID, name: "note", argument: "Stopped a repeating tool loop"))
                onEvent(.activityFinished(id: noteID, result: "Identical tool calls were repeated; the model was asked to answer directly.", isError: false))
                toolsDisabled = true
                continue
            }
            for call in calls {
                let activityID = UUID()
                onEvent(.activityStarted(id: activityID, name: call.name, argument: ToolCatalog.displayArgument(from: call.arguments)))
                let result = await ToolCatalog.execute(name: call.name, argumentsJSON: call.arguments, context: toolContext)
                onEvent(.activityFinished(id: activityID, result: result, isError: result.hasPrefix("Error")))
                verbatimToolResults.append((round: round, index: wireMessages.count))
                wireMessages.append(APIMessage(role: "tool", text: result, imageDataURLs: [], toolCallID: call.id))
            }
            if round == maxRounds - 2 {
                // Next round is the last: it goes out without tools plus this
                // nudge, so the reply always ends in text instead of dying
                // silently with unanswered tool calls.
                wireMessages.append(APIMessage(role: "system", text: "Tool budget for this reply is exhausted — answer now with what you have.", imageDataURLs: []))
                let noteID = UUID()
                onEvent(.activityStarted(id: noteID, name: "note", argument: "Paused tool use — answering with what it has"))
                onEvent(.activityFinished(id: noteID, result: "The per-reply tool budget (\(Limits.maxToolRounds) rounds) was reached.", isError: false))
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

    /// The Responses API takes FLAT tool objects — `{"type":"function",
    /// "name":…,"parameters":…}` — not chat-completions' nested `function`
    /// wrapper. Same post-encode JSON merge as `encodeWithTools`.
    private static func encodeCodexBody(_ body: CodexResponsesBody, tools: [ToolCatalog.Definition]) throws -> Data {
        let encoded = try JSONEncoder().encode(body)
        guard !tools.isEmpty else { return encoded }
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return encoded }
        object["tools"] = tools.map(responsesToolWireObject)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func responsesToolWireObject(_ tool: ToolCatalog.Definition) -> [String: Any] {
        let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] ?? [:]
        return [
            "type": "function",
            "name": tool.name,
            "description": tool.wireDescription,
            "parameters": parameters
        ]
    }

    private static func geminiToolWireObject(_ tool: ToolCatalog.Definition) -> [String: Any] {
        let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] ?? [:]
        return [
            "name": tool.name,
            "description": tool.wireDescription,
            "parameters": parameters
        ]
    }

    private static func toolWireObject(_ tool: ToolCatalog.Definition) -> [String: Any] {
        let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] ?? [:]
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.wireDescription,
                "parameters": parameters
            ]
        ]
    }

    public func streamChatEvents(
        profile: ProviderProfile,
        credential: ProviderCredential,
        model: String,
        thinking: ThinkingLevel = .auto,
        modelInfo: RemoteModel? = nil,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition] = [],
        toolContext: ToolCatalog.ExecutionContext? = nil,
        conversationKey: UUID? = nil,
        purpose: UsagePurpose = .chat,
        requestedOutputTokens: Int? = nil,
        telemetryRequestedModel: String? = nil
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
                        toolContext: toolContext,
                        conversationKey: conversationKey,
                        purpose: purpose,
                        requestedOutputTokens: requestedOutputTokens,
                        telemetryRequestedModel: telemetryRequestedModel
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

    public func streamChatEvents(
        profile: ProviderProfile,
        credential: ProviderCredential,
        preparedRequest: PreparedRequest,
        toolContext: ToolCatalog.ExecutionContext? = nil,
        conversationKey: UUID? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        streamChatEvents(
            profile: profile,
            credential: credential,
            model: preparedRequest.wireModel,
            thinking: preparedRequest.thinking,
            modelInfo: preparedRequest.modelInfo,
            messages: preparedRequest.messages,
            tools: preparedRequest.tools,
            toolContext: toolContext,
            conversationKey: conversationKey,
            purpose: preparedRequest.purpose,
            requestedOutputTokens: preparedRequest.requestedOutputTokens,
            telemetryRequestedModel: preparedRequest.requestedModel
        )
    }

    public func sendNonStreaming(
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
            keepAlive: profile.kind == .ollama ? "10m" : nil,
            streamOptions: nil
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

    private func shouldIncludeStreamingUsage(for profile: ProviderProfile) -> Bool {
        guard let key = ModelEvidenceScope.fingerprint(endpoint: profile.endpoint) else { return true }
        streamUsageCapabilityLock.lock()
        defer { streamUsageCapabilityLock.unlock() }
        return streamUsageCapabilityByEndpoint[key] ?? true
    }

    private func rememberStreamingUsageSupport(_ supported: Bool, for profile: ProviderProfile) {
        guard let key = ModelEvidenceScope.fingerprint(endpoint: profile.endpoint) else { return }
        streamUsageCapabilityLock.lock()
        streamUsageCapabilityByEndpoint[key] = supported
        streamUsageCapabilityLock.unlock()
    }

    /// Starts a chat-completions stream and performs the one safe compatibility
    /// retry allowed for arbitrary gateways: if the server rejects
    /// `stream_options.include_usage` before streaming starts, resend the same
    /// body without that option and remember the endpoint capability. No retry
    /// happens after a successful status, so generated content is never doubled.
    private func openChatCompletionStream(
        request: URLRequest,
        profile: ProviderProfile,
        includedUsage: Bool
    ) async throws -> (bytes: URLSession.AsyncBytes, response: URLResponse, retriedWithoutUsage: Bool) {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            if includedUsage { rememberStreamingUsageSupport(true, for: profile) }
            return (bytes, response, false)
        }

        var errorData = Data()
        for try await byte in bytes {
            errorData.append(byte)
            if errorData.count >= 8_192 { break }
        }
        let errorText = String(data: errorData, encoding: .utf8)?.lowercased() ?? ""
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let optionNamed = errorText.contains("stream_options") || errorText.contains("include_usage")
        let schemaRejected = errorText.contains("unknown") || errorText.contains("unsupported") ||
            errorText.contains("unrecognized") || errorText.contains("extra") || errorText.contains("not permitted")
        if includedUsage, [400, 404, 422].contains(status), optionNamed, schemaRejected {
            rememberStreamingUsageSupport(false, for: profile)
            var retry = request
            if let body = request.httpBody,
               var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                object.removeValue(forKey: "stream_options")
                retry.httpBody = try JSONSerialization.data(withJSONObject: object)
            }
            let (retryBytes, retryResponse) = try await session.bytes(for: retry)
            try await Self.checkStream(response: retryResponse, bytes: retryBytes)
            return (retryBytes, retryResponse, true)
        }

        try Self.check(response: response, data: errorData)
        throw APIError.message("The provider rejected the streaming request.")
    }

    private func baseURL(for value: String) throws -> URL {
        var string = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !string.contains("://") { string = "http://" + string }
        while string.hasSuffix("/") { string.removeLast() }
        guard let url = URL(string: string), url.host != nil else {
            throw APIError.message("Invalid endpoint URL: \(value)")
        }
        // Local-only mode is enforced here rather than in the picker: every
        // provider request, model fetch, and quota probe funnels through
        // this one function, so a stale view or a background refresh cannot
        // route around it.
        try EgressPolicy.check(url)
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
        case .appleIntelligence, .chatGPT, .claudeCode:
            // ChatGPT Web takes its effort in the conversation body, not
            // OpenAI-compatible request fields.
            return RequestSettings(reasoningEffort: nil, reasoning: nil, thinking: nil, think: nil)
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
        // never consulted for them. Perplexity doesn't take a reasoning
        // parameter at all. (Preview was a third member of this list until
        // the offline provider kind was retired.)
        case .codex, .perplexity, .anthropic:
            return RequestSettings(reasoningEffort: nil, reasoning: nil, thinking: nil, think: nil)
        }
    }

    private static func supportedReasoningEfforts(from parameters: [String]) -> [String] {
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
        } else if !profile.kind.isLocal, let token = credential.token, !token.isEmpty {
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

    private static func usageQuota(from snapshot: QuotaSnapshot?) -> UsageQuotaEvidence? {
        guard let snapshot else { return nil }
        return UsageQuotaEvidence(
            provenance: .responseHeaders,
            observedAt: snapshot.capturedAt,
            requestsRemaining: snapshot.requestsRemaining,
            requestsLimit: snapshot.requestsLimit,
            tokensRemaining: snapshot.tokensRemaining,
            tokensLimit: snapshot.tokensLimit,
            resetAt: snapshot.resetAt
        )
    }

    /// OpenAI-style `prompt_tokens` already includes cache-hit/cache-write
    /// input. Keep that canonical logical total intact and preserve the cache
    /// lanes alongside it for cost/coverage analysis; callers must not add the
    /// cache lanes to `inputTokens` again.
    private static func compatibleRequestUsage(
        id: UUID,
        profile: ProviderProfile,
        requestedModel: String,
        effectiveModel: String?,
        purpose: UsagePurpose,
        outcome: UsageOutcome,
        usage: StreamChunk.Usage?,
        latencyMilliseconds: Int,
        quota: QuotaSnapshot?
    ) -> RequestUsage {
        let hasMetrics = usage.map {
            $0.promptTokens != nil || $0.completionTokens != nil ||
                $0.cachedTokens != nil || $0.completionTokensDetails?.reasoningTokens != nil ||
                $0.promptTokensDetails?.cacheWriteTokens != nil
        } ?? false
        return RequestUsage(
            id: id,
            providerID: profile.id,
            requestedModelID: requestedModel,
            effectiveModelID: effectiveModel ?? requestedModel,
            purpose: purpose,
            outcome: outcome,
            inputTokens: LogicalInputUsage.tokens(
                reportedInput: usage?.promptTokens,
                cacheRead: usage?.cachedTokens,
                cacheWrite: usage?.promptTokensDetails?.cacheWriteTokens,
                reportedInputIncludesCache: true
            ),
            outputTokens: usage?.completionTokens,
            reasoningTokens: usage?.completionTokensDetails?.reasoningTokens,
            cacheReadTokens: usage?.cachedTokens,
            cacheWrite5mTokens: usage?.promptTokensDetails?.cacheWriteTokens,
            latencyMilliseconds: latencyMilliseconds,
            metricProvenance: hasMetrics ? .providerReported : nil,
            cost: usage?.cost.map(CostEvidence.providerReported),
            quota: usageQuota(from: quota)
        )
    }

    private static func codexRequestUsage(
        id: UUID,
        profile: ProviderProfile,
        requestedModel: String,
        effectiveModel: String?,
        purpose: UsagePurpose,
        outcome: UsageOutcome,
        usage: CodexResponseEvent.Response.Usage?,
        latencyMilliseconds: Int,
        quota: QuotaSnapshot?
    ) -> RequestUsage {
        let hasMetrics = usage.map {
            $0.inputTokens != nil || $0.outputTokens != nil ||
                $0.inputTokensDetails?.cachedTokens != nil ||
                $0.outputTokensDetails?.reasoningTokens != nil
        } ?? false
        return RequestUsage(
            id: id,
            providerID: profile.id,
            requestedModelID: requestedModel,
            effectiveModelID: effectiveModel ?? requestedModel,
            purpose: purpose,
            outcome: outcome,
            inputTokens: LogicalInputUsage.tokens(
                reportedInput: usage?.inputTokens,
                cacheRead: usage?.inputTokensDetails?.cachedTokens,
                cacheWrite: nil,
                reportedInputIncludesCache: true
            ),
            outputTokens: usage?.outputTokens,
            reasoningTokens: usage?.outputTokensDetails?.reasoningTokens,
            cacheReadTokens: usage?.inputTokensDetails?.cachedTokens,
            latencyMilliseconds: latencyMilliseconds,
            metricProvenance: hasMetrics ? .providerReported : nil,
            quota: usageQuota(from: quota)
        )
    }

    private static func anthropicRequestUsage(
        id: UUID,
        profile: ProviderProfile,
        requestedModel: String,
        effectiveModel: String?,
        purpose: UsagePurpose,
        outcome: UsageOutcome,
        usage: AnthropicStreamEvent.Usage?,
        latencyMilliseconds: Int,
        quota: QuotaSnapshot?
    ) -> RequestUsage {
        let creation = usage?.creationTokens
        let logicalInput = LogicalInputUsage.tokens(
            reportedInput: usage?.inputTokens,
            cacheRead: usage?.cacheReadInputTokens,
            cacheWrite: creation?.total,
            reportedInputIncludesCache: false
        )
        let hasMetrics = logicalInput != nil || usage?.outputTokens != nil
        return RequestUsage(
            id: id,
            providerID: profile.id,
            requestedModelID: requestedModel,
            effectiveModelID: effectiveModel ?? requestedModel,
            purpose: purpose,
            outcome: outcome,
            inputTokens: logicalInput,
            outputTokens: usage?.outputTokens,
            cacheReadTokens: usage?.cacheReadInputTokens,
            cacheWrite5mTokens: creation?.ephemeral5m,
            cacheWrite1hTokens: creation?.ephemeral1h,
            latencyMilliseconds: latencyMilliseconds,
            metricProvenance: hasMetrics ? .providerReported : nil,
            quota: usageQuota(from: quota)
        )
    }

    private func streamCodex(
        profile: ProviderProfile,
        model: String,
        credential: ProviderCredential,
        thinking: ThinkingLevel,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition] = [],
        toolContext: ToolCatalog.ExecutionContext? = nil,
        purpose: UsagePurpose,
        onEvent: @escaping @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/responses") else {
            throw APIError.message("Invalid Codex endpoint")
        }
        // Hardcoded host, so it never passes through `baseURL(for:)` and
        // needs its own check.
        try EgressPolicy.check(url)
        var inputItems: [CodexInputItem] = messages.map { message in
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
            return .message(
                role: message.role == "system" ? "developer" : message.role,
                content: contents
            )
        }

        // Same multi-round tool loop as the other two paths — the Responses
        // API's variant: flat `{"type":"function",…}` tool objects (NOT
        // chat-completions' nested `function` wrapper), calls streamed via
        // `response.output_item.added` + `response.function_call_arguments.
        // delta`, and replayed as typed `function_call` /
        // `function_call_output` input items keyed by `call_id`.
        let maxRounds = Limits.maxToolRounds
        var usageTotals = ToolLoopUsage()
        var toolsDisabled = false
        var seenCallSignatures = Set<String>()
        // Same replay economy as the other two loops: the Responses API
        // resends every input item on each round, so an older round's bulky
        // `function_call_output` is re-billed for the rest of the reply.
        var verbatimToolOutputs: [(round: Int, index: Int)] = []
        for round in 0..<maxRounds {
            var stillVerbatim: [(round: Int, index: Int)] = []
            for entry in verbatimToolOutputs {
                if ToolResultReplay.shouldCondense(round: entry.round, currentRound: round) {
                    inputItems[entry.index] = inputItems[entry.index].condensingToolOutput()
                } else {
                    stillVerbatim.append(entry)
                }
            }
            verbatimToolOutputs = stillVerbatim
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = Limits.streamIdleTimeout  // idle: reset by every received byte
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            addHeaders(to: &request, profile: ProviderProfile(kind: .codex, name: "Codex", endpoint: "", model: model), credential: credential)
            request.httpBody = try Self.encodeCodexBody(
                CodexResponsesBody(model: model, thinking: thinking, input: inputItems),
                tools: (round < maxRounds - 1 && !toolsDisabled) ? tools : []
            )

            let requestUsageID = UUID()
            let requestStartedAt = Date()
            var didEmitRequestUsage = false
            var latestRequestUsage: CodexResponseEvent.Response.Usage?
            var effectiveModel = model
            var requestQuota: QuotaSnapshot?
            defer {
                if !didEmitRequestUsage {
                    onEvent(.requestUsage(Self.codexRequestUsage(
                        id: requestUsageID,
                        profile: profile,
                        requestedModel: model,
                        effectiveModel: effectiveModel,
                        purpose: round == 0 ? purpose : .toolRound,
                        outcome: Task.isCancelled ? .cancelled : .failed,
                        usage: latestRequestUsage,
                        latencyMilliseconds: Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                        quota: requestQuota
                    )))
                }
            }
            let (bytes, response) = try await session.bytes(for: request)
            try await Self.checkStream(response: response, bytes: bytes)
            if let http = response as? HTTPURLResponse, let quota = QuotaSnapshot(headers: http.allHeaderFields) {
                requestQuota = quota
                onEvent(.quota(quota))
            }
            var consecutiveParseFailures = 0
            // Calls accumulate keyed by the stream's item id; order of
            // arrival is preserved for execution/replay.
            var pendingCalls: [(itemID: String, callID: String, name: String, arguments: String)] = []
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
                case "response.output_item.added":
                    if let item = event.item, item.type == "function_call" {
                        pendingCalls.append((itemID: item.id ?? "", callID: item.callId ?? item.id ?? "", name: item.name ?? "", arguments: item.arguments ?? ""))
                    }
                case "response.function_call_arguments.delta":
                    if let delta = event.delta, let itemID = event.itemId,
                       let index = pendingCalls.firstIndex(where: { $0.itemID == itemID }) {
                        pendingCalls[index].arguments += delta
                    }
                case "response.output_item.done":
                    // The completed item carries the sealed arguments —
                    // prefer them over whatever deltas accumulated.
                    if let item = event.item, item.type == "function_call",
                       let index = pendingCalls.firstIndex(where: { $0.itemID == (item.id ?? "") }) {
                        if let sealed = item.arguments, !sealed.isEmpty { pendingCalls[index].arguments = sealed }
                        if let callID = item.callId, !callID.isEmpty { pendingCalls[index].callID = callID }
                    }
                case "response.completed":
                    if let reportedModel = event.response?.model, !reportedModel.isEmpty { effectiveModel = reportedModel }
                    if let usage = event.response?.usage {
                        latestRequestUsage = usage
                        let totals = usageTotals.observe(prompt: usage.inputTokens, completion: usage.outputTokens, cached: usage.inputTokensDetails?.cachedTokens)
                        onEvent(.usage(prompt: totals.prompt, completion: totals.completion, cachedTokens: totals.cached, cacheCreation: totals.cacheCreation))
                    }
                default:
                    continue
                }
            }

            onEvent(.requestUsage(Self.codexRequestUsage(
                id: requestUsageID,
                profile: profile,
                requestedModel: model,
                effectiveModel: effectiveModel,
                purpose: round == 0 ? purpose : .toolRound,
                outcome: .succeeded,
                usage: latestRequestUsage,
                latencyMilliseconds: Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                quota: requestQuota
            )))
            didEmitRequestUsage = true
            if effectiveModel.caseInsensitiveCompare(model) != .orderedSame {
                onEvent(.modelMetadata(RuntimeModelMetadata(
                    requestedModel: model,
                    effectiveModel: effectiveModel
                )))
            }

            guard !pendingCalls.isEmpty, let toolContext, round < maxRounds - 1, !toolsDisabled else {
                onEvent(.finished(reason: nil))
                return
            }
            usageTotals.finishRound()
            for call in pendingCalls {
                inputItems.append(.functionCall(callID: call.callID, name: call.name, arguments: call.arguments))
            }
            let signatures = pendingCalls.map { "\($0.name)|\($0.arguments)" }
            let allRepeated = signatures.allSatisfy(seenCallSignatures.contains)
            seenCallSignatures.formUnion(signatures)
            if allRepeated {
                for call in pendingCalls {
                    inputItems.append(.functionCallOutput(callID: call.callID, output: "Duplicate of an identical earlier call — its result has not changed. Answer with what you already have."))
                }
                inputItems.append(.message(role: "developer", content: [.text("You repeated identical tool calls. Stop calling tools and answer now.", isOutput: false)]))
                let noteID = UUID()
                onEvent(.activityStarted(id: noteID, name: "note", argument: "Stopped a repeating tool loop"))
                onEvent(.activityFinished(id: noteID, result: "Identical tool calls were repeated; the model was asked to answer directly.", isError: false))
                toolsDisabled = true
                continue
            }
            for call in pendingCalls {
                let activityID = UUID()
                onEvent(.activityStarted(id: activityID, name: call.name, argument: ToolCatalog.displayArgument(from: call.arguments)))
                let result = await ToolCatalog.execute(name: call.name, argumentsJSON: call.arguments, context: toolContext)
                onEvent(.activityFinished(id: activityID, result: result, isError: result.hasPrefix("Error")))
                verbatimToolOutputs.append((round: round, index: inputItems.count))
                inputItems.append(.functionCallOutput(callID: call.callID, output: result))
            }
            if round == maxRounds - 2 {
                inputItems.append(.message(role: "developer", content: [.text("Tool budget for this reply is exhausted — answer now with what you have.", isOutput: false)]))
                let noteID = UUID()
                onEvent(.activityStarted(id: noteID, name: "note", argument: "Paused tool use — answering with what it has"))
                onEvent(.activityFinished(id: noteID, result: "The per-reply tool budget (\(Limits.maxToolRounds) rounds) was reached.", isError: false))
            }
        }
    }

    /// Builds Anthropic URLs from the profile's editable endpoint (default
    /// `https://api.anthropic.com/v1`) instead of a hardcoded host, so
    /// proxies/gateways actually work when the user edits the field.
    private static func anthropicURL(profile: ProviderProfile, path: String) -> URL? {
        let base = profile.endpoint.hasSuffix("/") ? String(profile.endpoint.dropLast()) : profile.endpoint
        return URL(string: base + path)
    }

    private func fetchAnthropicModels(profile: ProviderProfile, credential: ProviderCredential) async throws -> [RemoteModel] {
        guard let url = Self.anthropicURL(profile: profile, path: "/models?limit=100") else {
            throw APIError.message("Invalid Anthropic endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.discoveryTimeout(for: profile.kind)
        addHeaders(to: &request, profile: profile, credential: credential)
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let payload = try decoder.decode(AnthropicModelListResponse.self, from: data)
        return payload.data.map { item in
            let scope = ModelEvidenceScope(profile: profile, requestedModel: item.id, effectiveModel: item.id)
            return RemoteModel(
                id: item.id,
                name: item.displayName,
                contextLength: item.contextWindow ?? item.inputTokenLimit,
                maxOutputTokens: item.maxOutputTokens ?? item.outputTokenLimit,
                contextLimitEvidence: Self.curatedContextEvidence(modelID: item.id, scope: scope),
                evidenceScope: scope,
                scalarEvidenceSource: .providerCatalog,
                scalarEvidenceDetail: "Anthropic models catalog"
            )
        }
    }

    private func fetchGeminiModels(profile: ProviderProfile, credential: ProviderCredential) async throws -> [RemoteModel] {
        guard let endpoint = URL(string: profile.endpoint),
              endpoint.host?.lowercased() == "generativelanguage.googleapis.com",
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw APIError.message("Gemini native metadata is unavailable for this gateway.")
        }
        components.path = "/v1beta/models"
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
        guard let url = components.url else { throw APIError.message("Invalid Gemini endpoint") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.discoveryTimeout(for: profile.kind)
        if let token = credential.token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-goog-api-key")
        }
        request.setValue("VelaChat/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        let payload = try decoder.decode(GeminiModelListResponse.self, from: data)
        return payload.models.compactMap { item in
            guard item.supportedGenerationMethods?.contains("generateContent") != false else { return nil }
            let id = item.name.split(separator: "/").last.map(String.init) ?? item.name
            let scope = ModelEvidenceScope(profile: profile, requestedModel: id, effectiveModel: id)
            return RemoteModel(
                id: id,
                name: item.displayName,
                description: item.description,
                contextLength: item.inputTokenLimit,
                maxOutputTokens: item.outputTokenLimit,
                contextLimitEvidence: Self.curatedContextEvidence(modelID: id, scope: scope),
                evidenceScope: scope,
                scalarEvidenceSource: .providerCatalog,
                scalarEvidenceDetail: "Gemini models.list input/output token limits"
            )
        }
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
        profile: ProviderProfile,
        model: String,
        credential: ProviderCredential,
        thinking: ThinkingLevel,
        modelInfo: RemoteModel?,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition] = [],
        toolContext: ToolCatalog.ExecutionContext? = nil,
        purpose: UsagePurpose,
        requestedOutputTokens: Int?,
        onEvent: @escaping @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        guard let url = Self.anthropicURL(profile: profile, path: "/messages") else {
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
        let modelOutputLimit = max(1, modelInfo?.maxOutputTokens ?? 8_192)
        let baseMaxTokens = min(modelOutputLimit, max(1, requestedOutputTokens ?? min(modelOutputLimit, 8_192)))
        let maxTokens = anthropicThinking.map {
            min(modelOutputLimit, max(baseMaxTokens, $0.budgetTokens + 4_096))
        } ?? baseMaxTokens

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

        let maxRounds = Limits.maxToolRounds
        var usageTotals = ToolLoopUsage()
        var toolsDisabled = false
        var seenCallSignatures = Set<String>()
        // See the matching list in `streamChat`: turns holding tool results
        // still replayed verbatim, with the round that produced them.
        // Entries leave once condensed, so the rewrite runs exactly once.
        var verbatimToolResultTurns: [(round: Int, index: Int)] = []
        for round in 0..<maxRounds {
            var stillVerbatim: [(round: Int, index: Int)] = []
            for entry in verbatimToolResultTurns {
                if ToolResultReplay.shouldCondense(round: entry.round, currentRound: round) {
                    Self.condenseToolResults(in: &turnsJSON, at: entry.index)
                } else {
                    stillVerbatim.append(entry)
                }
            }
            verbatimToolResultTurns = stillVerbatim
            // Breakpoint 2 of 2 (see `AnthropicPromptCache`). Re-placed every
            // round rather than left where it was: a breakpoint only matches
            // within roughly 20 content blocks of itself, so one pinned to
            // the head of a long tool loop quietly stops earning anything.
            // Stripping before re-adding is what holds the request's total at
            // two — this one plus the system block's — well under Anthropic's
            // hard limit of four per request.
            AnthropicPromptCache.markLatestTurn(&turnsJSON)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = Limits.streamIdleTimeout  // idle: reset by every received byte
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
                // Breakpoint 1 of 2 (see `AnthropicPromptCache`). A marker on
                // the system block also covers `tools` — they're rendered
                // ahead of it in Anthropic's own documented request order —
                // so this is one marker for the whole static head, not one
                // per section. Below the model's minimum cacheable size it's
                // simply a no-op (`cache_creation_input_tokens: 0`), never an
                // error, so it's safe to always attach rather than track each
                // model's exact threshold (512–4096 tokens, and not
                // monotonic across model generations).
                bodyJSON["system"] = [
                    ["type": "text", "text": systemText, "cache_control": ["type": "ephemeral"]]
                ]
            }
            if let anthropicThinking {
                bodyJSON["thinking"] = ["type": "enabled", "budget_tokens": anthropicThinking.budgetTokens]
            }
            if !tools.isEmpty, round < maxRounds - 1 { bodyJSON["tools"] = tools.map(Self.anthropicToolWireObject) }
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyJSON)

            let requestUsageID = UUID()
            let requestStartedAt = Date()
            var didEmitRequestUsage = false
            var latestRequestUsage: AnthropicStreamEvent.Usage?
            var effectiveModel = model
            var requestQuota: QuotaSnapshot?
            defer {
                if !didEmitRequestUsage {
                    onEvent(.requestUsage(Self.anthropicRequestUsage(
                        id: requestUsageID,
                        profile: profile,
                        requestedModel: model,
                        effectiveModel: effectiveModel,
                        purpose: round == 0 ? purpose : .toolRound,
                        outcome: Task.isCancelled ? .cancelled : .failed,
                        usage: latestRequestUsage,
                        latencyMilliseconds: Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                        quota: requestQuota
                    )))
                }
            }
            let (bytes, response) = try await session.bytes(for: request)
            try await Self.checkStream(response: response, bytes: bytes)
            if let http = response as? HTTPURLResponse, let quota = QuotaSnapshot(headers: http.allHeaderFields) {
                requestQuota = quota
                onEvent(.quota(quota))
            }

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
                    if let reportedModel = event.message?.model, !reportedModel.isEmpty { effectiveModel = reportedModel }
                    if let usage = event.message?.usage {
                        latestRequestUsage = latestRequestUsage.map { $0.merging(usage) } ?? usage
                        let totals = usageTotals.observe(prompt: usage.inputTokens, completion: usage.outputTokens, cached: usage.cacheReadInputTokens, cacheCreation: usage.creationTokens)
                        onEvent(.usage(prompt: totals.prompt, completion: totals.completion, cachedTokens: totals.cached, cacheCreation: totals.cacheCreation))
                    }
                case "message_delta":
                    if let usage = event.usage {
                        latestRequestUsage = latestRequestUsage.map { $0.merging(usage) } ?? usage
                        let totals = usageTotals.observe(prompt: nil, completion: usage.outputTokens, cached: usage.cacheReadInputTokens, cacheCreation: usage.creationTokens)
                        onEvent(.usage(prompt: totals.prompt, completion: totals.completion, cachedTokens: totals.cached, cacheCreation: totals.cacheCreation))
                    }
                case "error":
                    if let message = event.error?.message { throw APIError.message(message) }
                default:
                    continue
                }
            }

            onEvent(.requestUsage(Self.anthropicRequestUsage(
                id: requestUsageID,
                profile: profile,
                requestedModel: model,
                effectiveModel: effectiveModel,
                purpose: round == 0 ? purpose : .toolRound,
                outcome: .succeeded,
                usage: latestRequestUsage,
                latencyMilliseconds: Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                quota: requestQuota
            )))
            didEmitRequestUsage = true
            if effectiveModel.caseInsensitiveCompare(model) != .orderedSame {
                onEvent(.modelMetadata(RuntimeModelMetadata(
                    requestedModel: model,
                    effectiveModel: effectiveModel
                )))
            }

            guard !toolBlocks.isEmpty, let toolContext, round < maxRounds - 1, !toolsDisabled else {
                onEvent(.finished(reason: nil))
                return
            }
            usageTotals.finishRound()

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

            let signatures = calls.map { "\($0.name)|\($0.json)" }
            let allRepeated = signatures.allSatisfy(seenCallSignatures.contains)
            seenCallSignatures.formUnion(signatures)
            if allRepeated {
                var duplicateResults: [[String: Any]] = []
                for call in calls {
                    duplicateResults.append(["type": "tool_result", "tool_use_id": call.id, "content": "Duplicate of an identical earlier call — its result has not changed. Answer with what you already have."])
                }
                duplicateResults.append(["type": "text", "text": "(You repeated identical tool calls. Stop calling tools and answer now.)"])
                turnsJSON.append(["role": "user", "content": duplicateResults])
                let noteID = UUID()
                onEvent(.activityStarted(id: noteID, name: "note", argument: "Stopped a repeating tool loop"))
                onEvent(.activityFinished(id: noteID, result: "Identical tool calls were repeated; the model was asked to answer directly.", isError: false))
                toolsDisabled = true
                continue
            }

            var toolResultContent: [[String: Any]] = []
            for call in calls {
                let activityID = UUID()
                onEvent(.activityStarted(id: activityID, name: call.name, argument: ToolCatalog.displayArgument(from: call.json)))
                let result = await ToolCatalog.execute(name: call.name, argumentsJSON: call.json, context: toolContext)
                onEvent(.activityFinished(id: activityID, result: result, isError: result.hasPrefix("Error")))
                toolResultContent.append(["type": "tool_result", "tool_use_id": call.id, "content": result])
            }
            verbatimToolResultTurns.append((round: round, index: turnsJSON.count))
            turnsJSON.append(["role": "user", "content": toolResultContent])
            if round == maxRounds - 2 {
                turnsJSON.append(["role": "user", "content": [["type": "text", "text": "(Tool budget for this reply is exhausted — answer now with what you have.)"]]])
                let noteID = UUID()
                onEvent(.activityStarted(id: noteID, name: "note", argument: "Paused tool use — answering with what it has"))
                onEvent(.activityFinished(id: noteID, result: "The per-reply tool budget (\(Limits.maxToolRounds) rounds) was reached.", isError: false))
            }
        }
    }

    /// Rewrites one replayed turn's `tool_result` blocks down to a
    /// summary. Only touches `tool_result` blocks, so an assistant's own
    /// text in the same turn is never trimmed.
    private static func condenseToolResults(in turns: inout [[String: Any]], at index: Int) {
        guard turns.indices.contains(index),
              var blocks = turns[index]["content"] as? [[String: Any]] else { return }
        for blockIndex in blocks.indices {
            guard blocks[blockIndex]["type"] as? String == "tool_result",
                  let text = blocks[blockIndex]["content"] as? String else { continue }
            blocks[blockIndex]["content"] = ToolResultReplay.condensed(text)
        }
        turns[index]["content"] = blocks
    }

    private static func anthropicToolWireObject(_ tool: ToolCatalog.Definition) -> [String: Any] {
        let schema = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] ?? [:]
        return ["name": tool.name, "description": tool.wireDescription, "input_schema": schema]
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

    public static func check(response: URLResponse?, data: Data?) throws {
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
    public static func checkStream(response: URLResponse?, bytes: URLSession.AsyncBytes) async throws {
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
    public static func discoveryTimeout(for kind: ProviderKind) -> TimeInterval {
        switch kind {
        case .ollama, .lmStudio, .compatible: 20
        default: 8
        }
    }

    public static func requireCredential(profile: ProviderProfile, credential: ProviderCredential) throws {
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

private struct OpenAIInputTokenCountResponse: Decodable {
    let inputTokens: Int
    enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens" }
}

private struct AnthropicInputTokenCountResponse: Decodable {
    let inputTokens: Int
    enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens" }
}

private struct GeminiInputTokenCountResponse: Decodable {
    let totalTokens: Int
}

/// A plain string `content` when there are no images (every request looked
/// like this before attachments existed, and still does for the vast
/// majority) — otherwise the standard OpenAI vision content-part array:
/// `[{"type":"text","text":...},{"type":"image_url","image_url":{"url":...}}]`.
private struct APIMessage: Encodable {
    let role: String
    /// `var` because the tool loop rewrites older rounds' results down to a
    /// summary before replaying them — see `ToolResultReplay`.
    var text: String
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
    let streamOptions: StreamOptions?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, reasoning, thinking, think
        case reasoningEffort = "reasoning_effort"
        case keepAlive = "keep_alive"
        case streamOptions = "stream_options"
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
        if let streamOptions { try container.encode(streamOptions, forKey: .streamOptions) }
    }
}

private struct StreamOptions: Encodable {
    let includeUsage: Bool
    enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
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

/// OpenRouter `/models` payload. Internal (not private) so the catalog
/// tests can decode fixtures against the real structs.
struct ModelListResponse: Decodable {
    struct Architecture: Decodable {
        let inputModalities: [String]?
        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
        }
    }

    struct TopProvider: Decodable {
        let contextLength: Int?
        let maxCompletionTokens: Int?
        enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
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
        /// Native Gemini metadata uses camelCase for these two fields.
        let inputTokenLimit: Int?
        let outputTokenLimit: Int?
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
            case inputTokenLimit, outputTokenLimit
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

/// OpenRouter single-model lookup (`GET /api/v1/model/:slug`): the same
/// Item shape as the bulk list, wrapped in a `data` object.
struct SingleModelResponse: Decodable {
    let data: ModelListResponse.Item
}

/// OpenRouter key info (`GET /api/v1/auth/key`): `{data: {label, usage,
/// limit}}`, usage/limit in credits. Internal for fixture tests.
struct OpenRouterKeyResponse: Decodable {
    struct KeyInfo: Decodable {
        let label: String?
        let usage: Double?
        let limit: Double?
    }
    let data: KeyInfo?
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

private struct OllamaProcessesResponse: Decodable {
    struct Item: Decodable {
        let name: String?
        let model: String?
        let contextLength: Int?
        enum CodingKeys: String, CodingKey {
            case name, model
            case contextLength = "context_length"
        }
    }
    let models: [Item]
}

private struct GeminiModelListResponse: Decodable {
    struct Item: Decodable {
        let name: String
        let displayName: String?
        let description: String?
        let inputTokenLimit: Int?
        let outputTokenLimit: Int?
        let supportedGenerationMethods: [String]?
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
            /// OpenAI's structured refusal field — set when their safety
            /// classifier (or a policy layer) blocked the answer and sent
            /// an official "no" instead of content. Most OpenAI-compatible
            /// providers never send it, which decodes as nil and changes
            /// nothing.
            let refusal: String?
            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
                case refusal
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
            let cacheWriteTokens: Int?
            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
                case cacheWriteTokens = "cache_write_tokens"
            }
        }
        struct CompletionTokensDetails: Decodable {
            let reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }
        let promptTokens: Int?
        let completionTokens: Int?
        let promptTokensDetails: PromptTokensDetails?
        let completionTokensDetails: CompletionTokensDetails?
        /// DeepSeek reports its own (also automatic) disk-based cache the
        /// same way, but as a flat field with a different name rather than
        /// OpenAI's nested shape.
        let promptCacheHitTokens: Int?
        /// OpenRouter includes provider-computed request cost in usage when
        /// available. Other compatible providers simply omit it.
        let cost: Double?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptTokensDetails = "prompt_tokens_details"
            case completionTokensDetails = "completion_tokens_details"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
            case cost
        }
        var cachedTokens: Int? { promptTokensDetails?.cachedTokens ?? promptCacheHitTokens }

        func merging(_ newer: Usage) -> Usage {
            Usage(
                promptTokens: newer.promptTokens ?? promptTokens,
                completionTokens: newer.completionTokens ?? completionTokens,
                promptTokensDetails: newer.promptTokensDetails ?? promptTokensDetails,
                completionTokensDetails: newer.completionTokensDetails ?? completionTokensDetails,
                promptCacheHitTokens: newer.promptCacheHitTokens ?? promptCacheHitTokens,
                cost: newer.cost ?? cost
            )
        }
    }
    let choices: [Choice]
    let usage: Usage?
    let id: String?
    let model: String?
}

private struct CodexResponsesBody: Encodable {
    let model: String
    let input: [CodexInputItem]
    let stream = true
    let store = false
    let reasoning: CodexReasoning?

    enum CodingKeys: String, CodingKey {
        case model, input, stream, store, reasoning
    }

    init(model: String, thinking: ThinkingLevel, input: [CodexInputItem]) {
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

/// A Responses-API `input` item: a plain chat message, or a replayed tool
/// exchange — `function_call` (what the model asked for) followed by
/// `function_call_output` (what came back), matched by `call_id`.
private enum CodexInputItem: Encodable {
    case message(role: String, content: [CodexInputContent])
    case functionCall(callID: String, name: String, arguments: String)
    case functionCallOutput(callID: String, output: String)

    private enum CodingKeys: String, CodingKey {
        case type, role, content, name, arguments, output
        case callID = "call_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let role, let content):
            try container.encode("message", forKey: .type)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        case .functionCall(let callID, let name, let arguments):
            try container.encode("function_call", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        case .functionCallOutput(let callID, let output):
            try container.encode("function_call_output", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(output, forKey: .output)
        }
    }

    /// The same item with an older round's tool output shortened for replay
    /// (see `ToolResultReplay`). Anything that isn't a tool output is
    /// returned untouched — the model's own turns are never trimmed.
    func condensingToolOutput() -> CodexInputItem {
        guard case .functionCallOutput(let callID, let output) = self else { return self }
        return .functionCallOutput(callID: callID, output: ToolResultReplay.condensed(output))
    }
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
            struct InputDetails: Decodable {
                let cachedTokens: Int?
                enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
            }
            struct OutputDetails: Decodable {
                let reasoningTokens: Int?
                enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
            }
            let inputTokens: Int?
            let outputTokens: Int?
            let inputTokensDetails: InputDetails?
            let outputTokensDetails: OutputDetails?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case inputTokensDetails = "input_tokens_details"
                case outputTokensDetails = "output_tokens_details"
            }
        }
        let usage: Usage?
        let model: String?
        let id: String?
    }
    /// A streamed output item — only `function_call` items are read.
    struct Item: Decodable {
        let type: String?
        let id: String?
        let callId: String?
        let name: String?
        let arguments: String?
        enum CodingKeys: String, CodingKey {
            case type, id, name, arguments
            case callId = "call_id"
        }
    }
    let type: String
    let delta: String?
    let response: Response?
    let item: Item?
    let itemId: String?

    enum CodingKeys: String, CodingKey {
        case type, delta, response, item
        case itemId = "item_id"
    }
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
        let contextWindow: Int?
        let inputTokenLimit: Int?
        let maxOutputTokens: Int?
        let outputTokenLimit: Int?
        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case contextWindow = "context_window"
            case inputTokenLimit = "input_token_limit"
            case maxOutputTokens = "max_output_tokens"
            case outputTokenLimit = "output_token_limit"
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
        /// Anthropic EXCLUDES cache reads from this — see
        /// `ProviderKind.promptTokensIncludeCached`.
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        /// The TTL split. Present on real responses (verified against a
        /// recorded session); absent on older API versions, in which case
        /// the flat `cacheCreationInputTokens` is all there is.
        let cacheCreation: CacheCreationDetail?

        struct CacheCreationDetail: Decodable {
            let ephemeral5m: Int?
            let ephemeral1h: Int?
            enum CodingKeys: String, CodingKey {
                case ephemeral5m = "ephemeral_5m_input_tokens"
                case ephemeral1h = "ephemeral_1h_input_tokens"
            }
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheCreation = "cache_creation"
        }

        /// The split when the API gave one. When only the flat total is
        /// present it is attributed to the 5-minute tier, which is the
        /// default TTL — and the cheaper of the two, so this can only ever
        /// under-state cost, never invent one.
        var creationTokens: CacheCreationTokens? {
            if let cacheCreation {
                return CacheCreationTokens(ephemeral5m: cacheCreation.ephemeral5m, ephemeral1h: cacheCreation.ephemeral1h)
            }
            guard let cacheCreationInputTokens else { return nil }
            return CacheCreationTokens(ephemeral5m: cacheCreationInputTokens, ephemeral1h: nil)
        }

        func merging(_ newer: Usage) -> Usage {
            Usage(
                inputTokens: newer.inputTokens ?? inputTokens,
                outputTokens: newer.outputTokens ?? outputTokens,
                cacheReadInputTokens: newer.cacheReadInputTokens ?? cacheReadInputTokens,
                cacheCreationInputTokens: newer.cacheCreationInputTokens ?? cacheCreationInputTokens,
                cacheCreation: newer.cacheCreation ?? cacheCreation
            )
        }
    }
    struct MessageEnvelope: Decodable {
        let usage: Usage?
        let model: String?
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

/// Sums token usage across the rounds of one reply's tool loop. Within a
/// single round providers report cumulative totals for that request (so
/// the latest value wins); each finished round's totals then bank into
/// the base so the .usage events the app stores always carry the whole
/// reply's spend — previously every round overwrote the last, and a
/// five-round tool reply recorded only its final hop (~5x undercount).
public struct ToolLoopUsage {
    private var basePrompt = 0, baseCompletion = 0, baseCached = 0
    private var base5m = 0, base1h = 0
    private var roundPrompt: Int?, roundCompletion: Int?, roundCached: Int?
    private var round5m: Int?, round1h: Int?

    /// Feed one provider-reported usage payload; returns the running
    /// whole-reply totals to emit (nil where nothing was ever reported,
    /// so unknown never masquerades as zero).
    ///
    /// Within one round the latest report *replaces* the previous one —
    /// providers send cumulative usage, so summing intermediate events
    /// would multiply the count. Across rounds `finishRound()` folds the
    /// finished round into the base, because each round is its own
    /// billed request.
    public mutating func observe(
        prompt: Int?,
        completion: Int?,
        cached: Int?,
        cacheCreation: CacheCreationTokens? = nil
    ) -> (prompt: Int?, completion: Int?, cached: Int?, cacheCreation: CacheCreationTokens?) {
        if let prompt { roundPrompt = prompt }
        if let completion { roundCompletion = completion }
        if let cached { roundCached = cached }
        if let value = cacheCreation?.ephemeral5m { round5m = value }
        if let value = cacheCreation?.ephemeral1h { round1h = value }
        func total(_ base: Int, _ round: Int?) -> Int? {
            base == 0 && round == nil ? nil : base + (round ?? 0)
        }
        let creation = CacheCreationTokens(
            ephemeral5m: total(base5m, round5m),
            ephemeral1h: total(base1h, round1h)
        )
        return (
            total(basePrompt, roundPrompt),
            total(baseCompletion, roundCompletion),
            total(baseCached, roundCached),
            creation.total == nil ? nil : creation
        )
    }

    /// Call between rounds — folds the finished round into the base.
    public mutating func finishRound() {
        basePrompt += roundPrompt ?? 0
        baseCompletion += roundCompletion ?? 0
        baseCached += roundCached ?? 0
        base5m += round5m ?? 0
        base1h += round1h ?? 0
        round5m = nil
        round1h = nil
        roundPrompt = nil
        roundCompletion = nil
        roundCached = nil
    }
}
