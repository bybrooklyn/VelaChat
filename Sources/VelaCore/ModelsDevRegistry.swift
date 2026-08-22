import Foundation

/// Model metadata from models.dev (MIT) — context windows, per-token
/// pricing, capability flags — for providers whose own `/models` endpoint
/// reports none of it.
///
/// The conflict rule is the plan's, and it is load-bearing: **the
/// provider's own catalog always wins.** This registry only fills fields a
/// live `RemoteModel` left `nil`, never overwrites an observed value. The
/// same discipline applies to Ollama's `/api/show` capabilities and
/// OpenRouter's published prices: observed beats derived (house rule 7).
///
/// Three layers of availability:
/// 1. A live fetch of `models.dev/api.json` (the full 190-provider set),
///    cached on disk in Application Support.
/// 2. The cached copy from a previous run.
/// 3. A vendored snapshot bundled with the app — pruned to the providers
///    VelaChat ships presets for, so first-run/offline installs still get
///    real numbers instead of blank popovers.
public enum ModelsDevRegistry {

    // MARK: - Decoding (forgiving by design)

    struct ProviderEntry: Decodable {
        struct Model: Decodable {
            struct Limit: Decodable {
                let context: Int?
                let output: Int?
            }
            struct Cost: Decodable {
                /// Dollars per million tokens, as published.
                let input: Double?
                let output: Double?
            }
            let id: String?
            let name: String?
            let description: String?
            let reasoning: Bool?
            let toolCall: Bool?
            let attachment: Bool?
            let modalities: Modalities?
            let limit: Limit?
            let cost: Cost?

            enum CodingKeys: String, CodingKey {
                case id, name, description, reasoning, attachment
                case toolCall = "tool_call"
                case modalities, limit, cost
            }
        }

        struct Modalities: Decodable {
            let input: [String]?

            var supportsVision: Bool? {
                input.map { $0.contains { $0.lowercased() == "image" } }
            }
        }

        let models: [String: Model]?
    }

    // MARK: - State

    private static let lock = NSLock()
    private static var providers: [String: ProviderEntry] = [:]

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("VelaChat", isDirectory: true)
            .appendingPathComponent("models-dev.json")
    }

    /// Loads, once: the disk cache if present, else the vendored snapshot.
    private static func ensureLoaded() {
        lock.lock()
        defer { lock.unlock() }
        guard providers.isEmpty else { return }
        if let url = cacheURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: ProviderEntry].self, from: data), !decoded.isEmpty {
            providers = decoded
            return
        }
        if let url = Bundle.module.url(forResource: "models-dev-snapshot", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: ProviderEntry].self, from: data), !decoded.isEmpty {
            providers = decoded
        }
    }

    // MARK: - Refresh

    /// Fetches the full live registry and caches it on disk. Fire-and-
    /// forget from startup: failure is invisible (the snapshot/cached copy
    /// keeps working) — never a user-facing error.
    public static func refreshIfStale(maxAge: TimeInterval = 7 * 86_400) async {
        ensureLoaded()
        if let url = cacheURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge {
            return
        }
        guard let source = URL(string: "https://models.dev/api.json") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: source)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let decoded = try? JSONDecoder().decode([String: ProviderEntry].self, from: data),
                  !decoded.isEmpty else { return }
            if let destination = cacheURL {
                try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: destination)
            }
            store(decoded)
        } catch {
            // Offline or blocked — whatever is already loaded stands.
        }
    }

    private static func store(_ decoded: [String: ProviderEntry]) {
        lock.lock()
        defer { lock.unlock() }
        providers = decoded
    }

    // MARK: - Lookup & enrichment

    /// The models.dev provider key for a VelaChat provider kind, plus the
    /// base-URL hints that let custom "OpenAI-compatible" endpoints reach
    /// their real entry when they point at a known host.
    private static func providerKey(kind: ProviderKind, baseURL: String?) -> String? {
        switch kind {
        case .openAI, .codex, .chatGPT: return "openai"
        case .anthropic: return "anthropic"
        case .google: return "google"
        case .deepSeek: return "deepseek"
        case .openRouter: return "openrouter"
        case .groq: return "groq"
        case .mistral: return "mistral"
        case .xai: return "xai"
        case .perplexity: return "perplexity"
        case .compatible:
            guard let host = baseURL.flatMap(URL.init(string:))?.host?.lowercased() else { return nil }
            let hints: [(String, String)] = [
                ("groq", "groq"), ("mistral", "mistral"), ("x.ai", "xai"),
                ("perplexity", "perplexity"), ("deepseek", "deepseek"),
                ("openrouter", "openrouter"),
            ]
            return hints.first(where: { host.contains($0.0) })?.1
        default:
            return nil
        }
    }

    /// Fills only what the live model left unknown. An observed value —
    /// from the provider's own catalog, OpenRouter's pricing, Ollama's
    /// `/api/show` capabilities — is never replaced by the registry's.
    /// Capability flags can only ever be *upgraded* to true: `RemoteModel`
    /// stores plain bools (an absent flag was already run through
    /// `inferCapabilities`), so false means "no evidence of", and external
    /// evidence is exactly what this exists to add.
    public static func enrich(_ models: [RemoteModel], kind: ProviderKind, baseURL: String?) -> [RemoteModel] {
        ensureLoaded()
        guard let key = providerKey(kind: kind, baseURL: baseURL),
              let entry = lockedProvider(forKey: key)?.models else { return models }
        return models.map { model in
            guard let metadata = entry[model.id] else { return model }
            return RemoteModel(
                id: model.id,
                ownedBy: model.ownedBy,
                name: model.name ?? metadata.name,
                description: model.description ?? metadata.description,
                contextLength: model.contextLength ?? metadata.limit?.context,
                maxOutputTokens: model.maxOutputTokens ?? metadata.limit?.output,
                parameterSize: model.parameterSize,
                sizeBytes: model.sizeBytes,
                quantizationLevel: model.quantizationLevel,
                isCloudHosted: model.isCloudHosted,
                supportsReasoning: model.supportsReasoning || (metadata.reasoning == true),
                supportsVision: model.supportsVision || (metadata.modalities?.supportsVision == true),
                supportsTools: model.supportsTools || (metadata.toolCall == true),
                supportedEfforts: model.supportedEfforts,
                isLocal: model.isLocal,
                inputPricePerMillion: model.inputPricePerMillion ?? metadata.cost?.input,
                outputPricePerMillion: model.outputPricePerMillion ?? metadata.cost?.output
            )
        }
    }

    private static func lockedProvider(forKey key: String) -> ProviderEntry? {
        lock.lock()
        defer { lock.unlock() }
        return providers[key]
    }
}
