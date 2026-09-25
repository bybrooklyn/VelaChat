import Foundation

/// Model metadata from models.dev (MIT) — context windows, per-token
/// pricing, capability flags — for providers whose own `/models` endpoint
/// reports none of it.
///
/// The conflict rule is the plan's, and it is load-bearing: **the
/// provider's own catalog always wins.** Registry evidence is retained even
/// when it conflicts, so the UI can disclose the disagreement, but the
/// resolver keeps it below provider-published/runtime evidence. The same
/// discipline applies to Ollama's `/api/show` capabilities and OpenRouter's
/// published prices: observed beats derived (house rule 7).
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
                let reasoning: Double?
                let cacheRead: Double?
                let cacheWrite: Double?
                let tiers: [Tier]?
                let contextOver200K: ContextRates?

                struct ContextRates: Decodable {
                    let input: Double?
                    let output: Double?
                    let cacheRead: Double?
                    let cacheWrite: Double?

                    enum CodingKeys: String, CodingKey {
                        case input, output
                        case cacheRead = "cache_read"
                        case cacheWrite = "cache_write"
                    }
                }

                struct Tier: Decodable {
                    struct Descriptor: Decodable {
                        let type: String?
                        let size: Int?
                    }
                    let input: Double?
                    let output: Double?
                    let cacheRead: Double?
                    let cacheWrite: Double?
                    let tier: Descriptor?

                    enum CodingKeys: String, CodingKey {
                        case input, output, tier
                        case cacheRead = "cache_read"
                        case cacheWrite = "cache_write"
                    }
                }

                enum CodingKeys: String, CodingKey {
                    case input, output, reasoning, tiers
                    case cacheRead = "cache_read"
                    case cacheWrite = "cache_write"
                    case contextOver200K = "context_over_200k"
                }
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
    private enum Backing { case live, cache, bundled }
    private static var backing: Backing = .bundled

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
            backing = .cache
            return
        }
        if let url = Bundle.module.url(forResource: "models-dev-snapshot", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: ProviderEntry].self, from: data), !decoded.isEmpty {
            providers = decoded
            backing = .bundled
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
            store(decoded, backing: .live)
        } catch {
            // Offline or blocked — whatever is already loaded stands.
        }
    }

    private static func store(_ decoded: [String: ProviderEntry], backing newBacking: Backing) {
        lock.lock()
        defer { lock.unlock() }
        providers = decoded
        backing = newBacking
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

    /// Adds exact registry evidence without replacing provider evidence.
    /// Compatibility accessors still resolve the provider value first; any
    /// disagreement remains available in `contextResolution.conflicts`.
    /// Capability flags can only ever be *upgraded* to true: `RemoteModel`
    /// stores plain bools (an absent flag was already run through
    /// `inferCapabilities`), so false means "no evidence of", and external
    /// evidence is exactly what this exists to add.
    public static func enrich(_ models: [RemoteModel], kind: ProviderKind, baseURL: String?) -> [RemoteModel] {
        ensureLoaded()
        guard let key = providerKey(kind: kind, baseURL: baseURL),
              let (provider, registryBacking) = lockedProvider(forKey: key),
              let entry = provider.models else { return models }
        let evidenceSource: ModelEvidenceSource = switch registryBacking {
        case .live: .modelsDevLive
        case .cache: .modelsDevCache
        case .bundled: .bundledSnapshot
        }
        return models.map { model in
            let metadataID: String = {
                if entry[model.id] != nil { return model.id }
                if kind == .openRouter, model.id.lowercased().hasSuffix(":online") {
                    return String(model.id.dropLast(":online".count))
                }
                return model.id
            }()
            guard let metadata = entry[metadataID] else { return model }
            let scope = model.contextLimitEvidence.first?.scope
                ?? model.outputLimitEvidence.first?.scope
                ?? ModelEvidenceScope(
                    endpointFingerprint: baseURL.flatMap { ModelEvidenceScope.fingerprint(endpoint: $0) },
                    requestedModel: model.id,
                    effectiveModel: model.id
                )
            var contexts = model.contextLimitEvidence
            if let value = metadata.limit?.context, value > 0 {
                contexts.append(ContextLimitEvidence(
                    value: value,
                    source: evidenceSource,
                    scope: scope,
                    detail: "models.dev exact model metadata"
                ))
            }
            var outputs = model.outputLimitEvidence
            if let value = metadata.limit?.output, value > 0 {
                outputs.append(OutputLimitEvidence(
                    value: value,
                    source: evidenceSource,
                    scope: scope,
                    detail: "models.dev exact model metadata"
                ))
            }
            var prices = model.pricingEvidence
            if metadata.cost != nil {
                let contextTier = metadata.cost?.tiers?.first(where: { $0.tier?.type == "context" })
                let longRates = metadata.cost?.contextOver200K
                prices.append(ModelPricingEvidence(
                    inputPerMillion: metadata.cost?.input,
                    outputPerMillion: metadata.cost?.output,
                    reasoningPerMillion: metadata.cost?.reasoning,
                    cacheReadPerMillion: metadata.cost?.cacheRead,
                    cacheWritePerMillion: metadata.cost?.cacheWrite,
                    longContextInputPerMillion: contextTier?.input ?? longRates?.input,
                    longContextOutputPerMillion: contextTier?.output ?? longRates?.output,
                    longContextCacheReadPerMillion: contextTier?.cacheRead ?? longRates?.cacheRead,
                    longContextCacheWritePerMillion: contextTier?.cacheWrite ?? longRates?.cacheWrite,
                    longContextThresholdTokens: contextTier?.tier?.size ?? (longRates == nil ? nil : 200_000),
                    source: evidenceSource,
                    detail: "models.dev exact model metadata"
                ))
            }
            return RemoteModel(
                id: model.id,
                ownedBy: model.ownedBy,
                name: model.name ?? metadata.name,
                description: model.description ?? metadata.description,
                parameterSize: model.parameterSize,
                sizeBytes: model.sizeBytes,
                quantizationLevel: model.quantizationLevel,
                isCloudHosted: model.isCloudHosted,
                supportsReasoning: model.supportsReasoning || (metadata.reasoning == true),
                supportsVision: model.supportsVision || (metadata.modalities?.supportsVision == true),
                supportsTools: model.supportsTools || (metadata.toolCall == true),
                supportedEfforts: model.supportedEfforts,
                isLocal: model.isLocal,
                contextLimitEvidence: contexts,
                outputLimitEvidence: outputs,
                pricingEvidence: prices
            )
        }
    }

    private static func lockedProvider(forKey key: String) -> (ProviderEntry, Backing)? {
        lock.lock()
        defer { lock.unlock() }
        guard let provider = providers[key] else { return nil }
        return (provider, backing)
    }

    /// Test seam for precedence/conflict coverage without touching the real
    /// Application Support cache.
    static func loadForTesting(_ data: Data, source: ModelEvidenceSource) throws {
        let decoded = try JSONDecoder().decode([String: ProviderEntry].self, from: data)
        let testBacking: Backing = switch source {
        case .modelsDevLive: .live
        case .modelsDevCache: .cache
        default: .bundled
        }
        store(decoded, backing: testBacking)
    }
}
