import Foundation
import SwiftUI
import AppKit
import Observation

// MARK: - Providers

enum ThinkingLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto = "Auto"
    case off = "Off"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case extraHigh = "Extra High"
    case max = "Max"

    var id: String { rawValue }

    /// Labels follow the current ChatGPT/Codex vocabulary while keeping the
    /// wire values accepted by OpenAI-compatible APIs internal.
    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .extraHigh: "Extra High"
        case .max: "Max"
        }
    }

    var symbol: String {
        switch self {
        case .auto: "wand.and.stars"
        case .off: "bolt.slash"
        case .low: "hare"
        case .medium: "figure.walk"
        case .high: "brain"
        case .extraHigh: "sparkles"
        case .max: "flame"
        }
    }

    /// OpenAI and OpenRouter values. `nil` means leave the provider default.
    var requestValue: String? {
        switch self {
        case .auto: nil
        case .off: "none"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .extraHigh: "xhigh"
        case .max: "max"
        }
    }

    /// Codex's Responses API expects an explicit effort even for Auto.
    var codexValue: String {
        requestValue ?? "medium"
    }

    var detail: String {
        switch self {
        case .auto: "Leave the provider’s native default unchanged"
        case .off: "Disable extra thinking when the provider supports it"
        case .low: "A lighter reasoning pass"
        case .medium: "Balanced reasoning and latency"
        case .high: "Deeper reasoning for complex work"
        case .extraHigh: "Extra depth for long-running work"
        case .max: "The provider’s deepest available setting"
        }
    }

    var wireLabel: String {
        switch self {
        case .auto: "Provider default"
        case .off: "none / disabled"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .extraHigh: "xhigh"
        case .max: "max"
        }
    }

    var rank: Int {
        switch self {
        case .off: 0
        case .low: 1
        case .auto: 2
        case .medium: 3
        case .high: 4
        case .extraHigh: 5
        case .max: 6
        }
    }
}

/// How a provider reaches the live web. Providers that search natively are
/// preferred over VelaChat's own SearXNG fallback, because the model gets the
/// results inline (with citations) instead of a pre-stuffed context block.
enum NativeWebSearch {
    case none
    /// Search is intrinsic to every request — Perplexity's Sonar models.
    case always
    /// OpenRouter turns search on per-request via the `:online` model suffix.
    case onlineSuffix
}

enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case appleIntelligence = "Apple Intelligence"
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case google = "Google Gemini"
    case deepSeek = "DeepSeek"
    case openRouter = "OpenRouter"
    case groq = "Groq"
    case mistral = "Mistral"
    case xai = "xAI"
    case perplexity = "Perplexity"
    case codex = "Codex"
    case chatGPT = "ChatGPT"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case blockrun = "blockrun.ai"
    case compatible = "OpenAI Compatible"

    var id: String { rawValue }

    /// Brand color, used for the logo tile and any accenting.
    var tint: Color {
        switch self {
        case .appleIntelligence: Color(hex: 0xE8E4F0)
        case .openAI, .codex, .chatGPT: Color(hex: 0x10A37F)
        case .anthropic: Color(hex: 0xD97757)
        case .google: Color(hex: 0x4285F4)
        case .deepSeek: Color(hex: 0x4D6BFE)
        case .openRouter: Color(hex: 0x6467F2)
        case .groq: Color(hex: 0xF55036)
        case .mistral: Color(hex: 0xFA520F)
        case .xai: Color(hex: 0xE8E8E8)
        case .perplexity: Color(hex: 0x20B8CD)
        case .ollama: Color(hex: 0xC8C8C8)
        case .lmStudio: Color(hex: 0x7B5BF5)
        case .blockrun: Color(hex: 0x2ED47A)
        case .compatible: Color(hex: 0x5B9BD5)
        }
    }

    var shortDescription: String {
        switch self {
        case .appleIntelligence: "On-device Apple Intelligence — private, free, works offline"
        case .openAI: "OpenAI’s own API — the OpenAI-compatible standard"
        case .anthropic: "Claude, via Anthropic’s native Messages API"
        case .google: "Gemini, via Google’s OpenAI-compatible endpoint"
        case .deepSeek: "DeepSeek hosted API"
        case .openRouter: "One key, hundreds of models"
        case .groq: "Very fast inference on open models"
        case .mistral: "Mistral hosted API"
        case .xai: "Grok models from xAI"
        case .perplexity: "Answers with built-in live web search"
        case .codex: "Use your Codex CLI login"
        case .chatGPT: "Your ChatGPT account — sign in, no API key"
        case .ollama: "Local models on this Mac"
        case .lmStudio: "Local models via LM Studio"
        case .blockrun: "No key, no sign-up — free models only, IP rate-limited"
        case .compatible: "Any other OpenAI-compatible server"
        }
    }

    /// Every hosted provider here speaks the same `/chat/completions` shape
    /// that OpenAI defined — surfaced in the UI so the relationship between
    /// "OpenAI" and "OpenAI Compatible" reads as one family, not two ideas.
    var speaksOpenAIProtocol: Bool { self != .codex && self != .appleIntelligence && self != .chatGPT }

    var isLocal: Bool { self == .ollama || self == .lmStudio || self == .appleIntelligence }

    /// Whether this provider's reported prompt/input token count already
    /// includes tokens served from cache.
    ///
    /// This is a real wire-format difference, not a preference:
    /// Anthropic's `input_tokens` **excludes** `cache_read_input_tokens`
    /// (verified against a recorded live session), while OpenAI-style
    /// `prompt_tokens` **includes** `prompt_tokens_details.cached_tokens`.
    /// Pricing the same numbers under the wrong assumption is wrong in
    /// opposite directions — see `UsageSummary.costUSD(for:promptIncludesCached:)`.
    var promptTokensIncludeCached: Bool {
        switch self {
        case .anthropic: false
        default: true
        }
    }

    /// How usage is presented for this provider family. Subscription
    /// plans show their real provider-reported windows; metered (API-key)
    /// providers show locally counted meters + live rate-limit headers;
    /// local providers cost nothing and show no gauge at all.
    enum UsageStyle { case subscription, metered, local }
    var usageStyle: UsageStyle {
        switch self {
        case .codex, .chatGPT: .subscription
        case .ollama, .lmStudio, .appleIntelligence: .local
        default: .metered
        }
    }

    /// Where the provider's real logo lives — fetched at runtime by
    /// `RemoteLogoLoader` (own site first, Google favicons fallback).
    /// `nil` means hand-drawn mark only.
    var logoDomain: String? {
        switch self {
        case .openAI, .codex: "openai.com"
        case .chatGPT: "chatgpt.com"
        case .anthropic: "anthropic.com"
        case .google: "gemini.google.com"
        case .deepSeek: "deepseek.com"
        case .openRouter: "openrouter.ai"
        case .groq: "groq.com"
        case .mistral: "mistral.ai"
        case .xai: "x.ai"
        case .perplexity: "perplexity.ai"
        case .ollama: "ollama.com"
        case .lmStudio: "lmstudio.ai"
        case .blockrun: "blockrun.ai"
        case .compatible, .appleIntelligence: nil
        }
    }

    var nativeWebSearch: NativeWebSearch {
        switch self {
        case .perplexity: .always
        case .openRouter: .onlineSuffix
        default: .none
        }
    }

    var isBuiltIn: Bool { self != .compatible }

    var requiresKey: Bool {
        switch self {
        // ChatGPT signs in with a browser session, never an API key.
        case .ollama, .lmStudio, .blockrun, .appleIntelligence, .chatGPT: false
        default: true
        }
    }

    /// Where to get a key, shown inline in the provider editor.
    var consoleURL: URL? {
        switch self {
        case .openAI, .codex: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .google: URL(string: "https://aistudio.google.com/apikey")
        case .deepSeek: URL(string: "https://platform.deepseek.com")
        case .openRouter: URL(string: "https://openrouter.ai/keys")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .mistral: URL(string: "https://console.mistral.ai/api-keys")
        case .xai: URL(string: "https://console.x.ai")
        case .perplexity: URL(string: "https://www.perplexity.ai/settings/api")
        case .ollama: URL(string: "https://ollama.com")
        case .lmStudio: URL(string: "https://lmstudio.ai")
        case .blockrun: URL(string: "https://blockrun.ai")
        case .compatible, .appleIntelligence, .chatGPT: nil
        }
    }

    /// A last-resort value used only when a server does not publish a catalog.
    /// Normal operation always replaces this with a live discovered model.
    var automaticFallbackModel: String {
        switch self {
        case .appleIntelligence: "on-device"
        case .openAI: "gpt-5.6-terra"
        case .anthropic: "claude-sonnet-5"
        case .google: "gemini-3-pro"
        case .deepSeek: "deepseek-v4-flash"
        case .openRouter: "openai/gpt-5.6-terra"
        case .groq: "llama-3.3-70b-versatile"
        case .mistral: "mistral-large-latest"
        case .xai: "grok-4"
        case .perplexity: "sonar-pro"
        case .codex: "gpt-5.6-sol"
        case .chatGPT: "auto"
        case .ollama: "qwen3:8b"
        case .lmStudio: "local-model"
        case .blockrun: "nvidia/nemotron-nano-9b-v2"
        case .compatible: "default"
        }
    }
}

struct ProviderProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: ProviderKind
    var name: String
    var endpoint: String
    /// Empty means automatic model selection. It is intentionally not a
    /// required user setting.
    var model: String
    var enabled: Bool

    init(id: UUID = UUID(), kind: ProviderKind, name: String, endpoint: String, model: String = "", enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.enabled = enabled
    }

    var displayEndpoint: String {
        endpoint.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func defaults() -> [ProviderProfile] {
        [
            ProviderProfile(kind: .appleIntelligence, name: "Apple Intelligence", endpoint: "appleintelligence://local", model: "on-device"),
            ProviderProfile(kind: .openAI, name: "OpenAI", endpoint: "https://api.openai.com/v1"),
            ProviderProfile(kind: .anthropic, name: "Anthropic", endpoint: "https://api.anthropic.com/v1"),
            ProviderProfile(kind: .google, name: "Google Gemini", endpoint: "https://generativelanguage.googleapis.com/v1beta/openai"),
            ProviderProfile(kind: .deepSeek, name: "DeepSeek", endpoint: "https://api.deepseek.com"),
            ProviderProfile(kind: .openRouter, name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1"),
            ProviderProfile(kind: .groq, name: "Groq", endpoint: "https://api.groq.com/openai/v1"),
            ProviderProfile(kind: .mistral, name: "Mistral", endpoint: "https://api.mistral.ai/v1"),
            ProviderProfile(kind: .xai, name: "xAI", endpoint: "https://api.x.ai/v1"),
            ProviderProfile(kind: .perplexity, name: "Perplexity", endpoint: "https://api.perplexity.ai"),
            ProviderProfile(kind: .codex, name: "Codex", endpoint: "https://api.openai.com/v1"),
            ProviderProfile(kind: .chatGPT, name: "ChatGPT", endpoint: "https://chatgpt.com"),
            ProviderProfile(kind: .ollama, name: "Ollama", endpoint: "http://127.0.0.1:11434/v1"),
            ProviderProfile(kind: .lmStudio, name: "LM Studio", endpoint: "http://127.0.0.1:1234/v1"),
            ProviderProfile(kind: .blockrun, name: "blockrun.ai", endpoint: "https://blockrun.ai/api/v1"),
        ]
    }
}

/// Metadata returned by a provider's catalog. The picker is generated from
/// this shape rather than from a frozen list of model IDs.
struct RemoteModel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String?
    let ownedBy: String?
    let description: String?
    let contextLength: Int?
    let maxOutputTokens: Int?
    let parameterSize: String?
    let sizeBytes: Int64?
    /// Ollama-specific: the GGUF quantization actually running (`"Q4_K_M"`,
    /// `"Q8_0"`, …) — real data straight from `/api/tags`' `details.
    /// quantization_level`, not inferred.
    let quantizationLevel: String?
    /// True for an Ollama model tagged `:cloud` — it runs on Ollama's own
    /// servers via your local Ollama as an authenticated proxy, not on this
    /// Mac. The only documented way to tell the two apart is the tag suffix
    /// itself; there's no separate "is cloud" field in Ollama's API.
    let isCloudHosted: Bool
    let supportsReasoning: Bool
    let supportsVision: Bool
    let supportsTools: Bool
    let supportedEfforts: [String]
    let isLocal: Bool
    /// Real per-provider pricing only — OpenRouter's and blockrun.ai's own
    /// catalogs both publish genuine per-model $/1M-token pricing; every
    /// other provider's `/models` response doesn't (verified, not assumed:
    /// checking DeepSeek/Groq/Mistral without a key just 401s, so there's
    /// nothing to read even if it existed). `nil` here means "unknown," not
    /// "free" — the UI must never imply a number that was never observed.
    let inputPricePerMillion: Double?
    let outputPricePerMillion: Double?

    init(
        id: String,
        ownedBy: String? = nil,
        name: String? = nil,
        description: String? = nil,
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        parameterSize: String? = nil,
        sizeBytes: Int64? = nil,
        quantizationLevel: String? = nil,
        isCloudHosted: Bool = false,
        supportsReasoning: Bool? = nil,
        supportsVision: Bool? = nil,
        supportsTools: Bool? = nil,
        supportedEfforts: [String] = [],
        isLocal: Bool = false,
        inputPricePerMillion: Double? = nil,
        outputPricePerMillion: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.ownedBy = ownedBy
        self.description = description
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.parameterSize = parameterSize
        self.sizeBytes = sizeBytes
        self.quantizationLevel = quantizationLevel
        self.isCloudHosted = isCloudHosted
        self.supportedEfforts = supportedEfforts.map { $0.lowercased() }
        self.isLocal = isLocal && !isCloudHosted
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion

        let inferred = ModelCatalog.inferCapabilities(for: id)
        self.supportsReasoning = supportsReasoning ?? inferred.reasoning
        self.supportsVision = supportsVision ?? inferred.vision
        self.supportsTools = supportsTools ?? inferred.tools
    }

    /// A coarse $/$$/$$$ read on cost, from real per-provider pricing only
    /// — see `inputPricePerMillion`. `nil` when no real pricing is known,
    /// never guessed. Thresholds are $/1M input tokens.
    var priceTier: String? {
        guard let inputPricePerMillion else { return nil }
        if inputPricePerMillion <= 0 { return "Free" }
        if inputPricePerMillion < 1 { return "$" }
        if inputPricePerMillion < 5 { return "$$" }
        return "$$$"
    }

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        switch id.lowercased() {
        case "deepseek-v4-flash": return "DeepSeek V4 Flash"
        case "deepseek-v4-pro": return "DeepSeek V4 Pro"
        case "gpt-oss:20b": return "GPT-OSS 20B"
        default: break
        }
        let leaf = id.split(separator: "/").last.map(String.init) ?? id
        return leaf
            .replacingOccurrences(of: ":", with: " · ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    var providerModelID: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    var contextLabel: String? {
        guard let contextLength else { return nil }
        if contextLength >= 1_000_000 { return "\(contextLength / 1_000_000)M context" }
        if contextLength >= 1_000 { return "\(contextLength / 1_000)K context" }
        return "\(contextLength) context"
    }

    var diskSizeLabel: String? {
        guard let sizeBytes else { return nil }
        let gigabytes = Double(sizeBytes) / 1_000_000_000
        return gigabytes >= 1 ? String(format: "%.1f GB", gigabytes) : String(format: "%.0f MB", gigabytes * 1_000)
    }

    var sizeLabel: String? {
        if let parameterSize, !parameterSize.isEmpty { return parameterSize }
        return diskSizeLabel
    }

    /// Parameter count, quantization, and real disk footprint together —
    /// as close as VelaChat gets to "what resources this will use," built
    /// only from what Ollama's own `/api/tags` actually reports rather than
    /// a computed RAM/VRAM guess.
    var resourceLabel: String? {
        let parts = [parameterSize, quantizationLevel, diskSizeLabel].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var capabilityLabels: [String] {
        var labels: [String] = []
        if supportsReasoning { labels.append("Reasoning") }
        if supportsVision { labels.append("Vision") }
        if supportsTools { labels.append("Tools") }
        if isCloudHosted { labels.append("Cloud") }
        else if isLocal { labels.append("Local") }
        return labels
    }

    func thinkingLevels(for provider: ProviderKind) -> [ThinkingLevel] {
        let lowerID = id.lowercased()
        let hasProviderSignal: Bool
        switch provider {
        case .appleIntelligence:
            hasProviderSignal = false
        case .deepSeek:
            // DeepSeek’s /models response intentionally exposes only IDs and
            // ownership. Its current V4 models have a documented thinking
            // ladder even when the catalog omits parameter metadata.
            hasProviderSignal = lowerID.contains("deepseek-v4") || lowerID.contains("reasoner")
        case .codex, .openAI:
            hasProviderSignal = lowerID.contains("gpt-5") || lowerID.contains("o1") || lowerID.contains("o3") || lowerID.contains("o4")
        case .chatGPT:
            // ChatGPT models always carry account-discovered efforts in
            // supportedEfforts; there is no ID-based inference to do.
            hasProviderSignal = false
        case .ollama, .lmStudio:
            hasProviderSignal = lowerID.contains("qwen3") || lowerID.contains("gpt-oss") || lowerID.contains("deepseek-r") || lowerID.contains("reason")
        case .anthropic:
            hasProviderSignal = lowerID.contains("claude")
        case .google:
            hasProviderSignal = lowerID.contains("gemini-3") || lowerID.contains("thinking")
        case .xai:
            hasProviderSignal = lowerID.contains("grok-4") || lowerID.contains("grok-3-mini")
        case .openRouter, .compatible, .groq, .mistral, .perplexity, .blockrun:
            hasProviderSignal = false
        }

        guard supportsReasoning || !supportedEfforts.isEmpty || hasProviderSignal else {
            return [.auto]
        }

        let known = supportedEfforts.compactMap(Self.level(for:))
        if !known.isEmpty {
            return [.auto] + known.sorted { $0.rank < $1.rank }
        }

        // Do not present one universal ladder. These are the documented
        // provider defaults when a catalog does not describe the enum.
        switch provider {
        case .appleIntelligence:
            return [.auto]
        case .deepSeek:
            return [.auto, .off, .low, .high, .max]
        case .ollama, .lmStudio:
            return [.auto, .off, .low, .medium, .high]
        case .codex, .openAI:
            return [.auto, .off, .low, .medium, .high, .extraHigh, .max]
        case .openRouter, .compatible, .anthropic, .google, .xai, .blockrun:
            return [.auto, .off, .low, .medium, .high]
        case .groq, .mistral, .perplexity, .chatGPT:
            return [.auto]
        }
    }

    private static func level(for effort: String) -> ThinkingLevel? {
        switch effort.lowercased() {
        // "instant" is ChatGPT's word for no extended reasoning; "pro" is
        // its deepest route — both map onto the existing ladder ends.
        case "none", "off", "disabled", "instant": .off
        case "low", "light": .low
        case "medium", "standard": .medium
        case "high": .high
        case "xhigh", "extra_high", "extra-high": .extraHigh
        case "max", "pro": .max
        default: nil
        }
    }
}

struct ConnectionResult {
    let ok: Bool
    let message: String
    let models: [RemoteModel]
}

/// Curated data is only used for providers without a public model endpoint
/// (Codex OAuth) or when an endpoint is offline. Live catalogs always win.
enum ModelCatalog {
    static func curated(for kind: ProviderKind) -> [RemoteModel] {
        switch kind {
        case .codex:
            return [
                RemoteModel(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", description: "Flagship model for complex coding and research.", supportsReasoning: true, supportsTools: true, supportedEfforts: ["low", "medium", "high", "xhigh", "max"]),
                RemoteModel(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", description: "Balanced GPT-5.6 model for everyday work.", supportsReasoning: true, supportsTools: true, supportedEfforts: ["low", "medium", "high", "xhigh", "max"]),
                RemoteModel(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", description: "Fast, affordable model for focused tasks.", supportsReasoning: true, supportsTools: true, supportedEfforts: ["low", "medium", "high", "xhigh", "max"]),
                RemoteModel(id: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark", description: "Fast coding iteration model.", supportsReasoning: true, supportsTools: true, supportedEfforts: ["low", "medium", "high"]),
                RemoteModel(id: "gpt-5.5", name: "GPT-5.5", description: "Previous-generation frontier model.", supportsReasoning: true, supportsTools: true, supportedEfforts: ["low", "medium", "high", "xhigh", "max"]),
            ]
        case .deepSeek:
            return [
                RemoteModel(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", contextLength: 1_000_000, maxOutputTokens: 384_000, supportsReasoning: true, supportsTools: true, supportedEfforts: ["none", "low", "high", "max"]),
                RemoteModel(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", contextLength: 1_000_000, maxOutputTokens: 384_000, supportsReasoning: true, supportsTools: true, supportedEfforts: ["none", "low", "high", "max"]),
            ]
        case .openAI:
            return [
                RemoteModel(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", supportsReasoning: true, supportsVision: true, supportsTools: true, supportedEfforts: ["none", "low", "medium", "high", "xhigh", "max"]),
                RemoteModel(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", supportsReasoning: true, supportsVision: true, supportsTools: true, supportedEfforts: ["none", "low", "medium", "high", "xhigh", "max"]),
                RemoteModel(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", supportsReasoning: true, supportsVision: true, supportsTools: true, supportedEfforts: ["none", "low", "medium", "high", "xhigh", "max"]),
                RemoteModel(id: "gpt-4.1-mini", name: "GPT-4.1 mini", supportsVision: true, supportsTools: true),
            ]
        case .ollama:
            return [
                RemoteModel(id: "gpt-oss:20b", name: "GPT-OSS 20B", supportsReasoning: true, supportsTools: true, supportedEfforts: ["low", "medium", "high", "max"], isLocal: true),
                RemoteModel(id: "qwen3:8b", name: "Qwen 3 8B", supportsReasoning: true, supportsTools: true, supportedEfforts: ["low", "medium", "high", "max"], isLocal: true),
                RemoteModel(id: "gemma4", name: "Gemma 4", supportsReasoning: true, supportsVision: true, supportsTools: true, supportedEfforts: ["low", "medium", "high", "max"], isLocal: true),
            ]
        default:
            return []
        }
    }

    static func automaticModel(for kind: ProviderKind) -> RemoteModel {
        let id = kind.automaticFallbackModel
        return RemoteModel(id: id, name: "Automatic · \(id)", supportsReasoning: kind == .deepSeek || kind == .codex)
    }

    static func bestModel(for profile: ProviderProfile, models: [RemoteModel]) -> RemoteModel? {
        guard !models.isEmpty else { return nil }
        if !profile.model.isEmpty,
           !isLegacyAutomaticModel(profile.model),
           let exact = models.first(where: { $0.id == profile.model }) {
            return exact
        }

        let usable = models.filter { model in
            let lower = model.id.lowercased()
            return !["embedding", "moderation", "rerank", "whisper", "tts", "dall-e", "image"].contains(where: lower.contains)
        }
        let candidates = usable.isEmpty ? models : usable
        return candidates.max { score($0, for: profile.kind) < score($1, for: profile.kind) }
    }

    /// A catalog that omits `context_length` entirely (most do) shouldn't
    /// leave the context popover with nothing to show.
    ///
    /// The table itself lives in `ContextWindowTable`, which is also what
    /// the context readout falls back to for providers whose catalogs
    /// never reach this parsing path at all. One table, so the number a
    /// model gets can't depend on which provider happened to list it.
    static func curatedContextLength(for id: String) -> Int? {
        ContextWindowTable.contextLength(for: id)
    }

    static func isLegacyAutomaticModel(_ value: String) -> Bool {
        switch value.lowercased() {
        case "deepseek-chat", "deepseek-reasoner", "deepseek/deepseek-chat", "gpt-4o-mini", "gpt-5-codex", "llama3.2", "local-model", "default":
            return true
        default:
            return false
        }
    }

    static func inferCapabilities(for id: String) -> (reasoning: Bool, vision: Bool, tools: Bool) {
        let lower = id.lowercased()
        let reasoning = lower.contains("reason") || lower.contains("think") || lower.contains("r1") || lower.contains("o1") || lower.contains("o3") || lower.contains("o4") || lower.contains("qwen3") || lower.contains("qwen-qwq") || lower.contains("gpt-5") || lower.contains("deepseek-v") || lower.contains("claude")
        let vision = lower.contains("vision") || lower.contains("-vl") || lower.contains("gemini") || lower.contains("gpt-4o") || lower.contains("gpt-4.1") || lower.contains("pixtral") || lower.contains("claude")
        let tools = lower.contains("gpt-5") || lower.contains("gpt-4.1") || lower.contains("deepseek-v4") || lower.contains("qwen3") || lower.contains("gpt-oss") || lower.contains("claude") || lower.contains("gemini")
        return (reasoning, vision, tools)
    }

    /// Not private — the model picker uses this same heuristic to sort each
    /// provider's list strongest-to-weakest, instead of alphabetically.
    static func score(_ model: RemoteModel, for kind: ProviderKind) -> Int {
        let lower = model.id.lowercased()
        var score = model.supportsTools ? 20 : 0
        if model.supportsReasoning { score += 12 }
        if model.contextLength ?? 0 >= 100_000 { score += 4 }
        switch kind {
        case .appleIntelligence:
            score += 10
        case .codex:
            if lower.contains("gpt-5.6-sol") { score += 100 }
            else if lower.contains("gpt-5.6-terra") { score += 90 }
            else if lower.contains("gpt-5.6-luna") { score += 80 }
            else if lower.contains("gpt-5") { score += 40 }
        case .chatGPT:
            if lower == "auto" { score += 100 }
            else if lower.contains("gpt-5.6-sol") { score += 95 }
            else if lower.contains("gpt-5.6") { score += 85 }
            else if lower.contains("gpt-5") { score += 60 }
        case .deepSeek:
            if lower.contains("v4-flash") { score += 100 }
            else if lower.contains("v4-pro") { score += 90 }
            else if lower.contains("reasoner") { score += 60 }
            else if lower.contains("chat") { score += 40 }
        case .openAI:
            if lower.contains("gpt-5.6-terra") { score += 100 }
            else if lower.contains("gpt-5.6-luna") { score += 95 }
            else if lower.contains("gpt-5.6-sol") { score += 90 }
            else if lower.contains("gpt-5") { score += 60 }
            else if lower.contains("gpt-4.1") { score += 45 }
        case .ollama, .lmStudio:
            if lower.contains("gpt-oss") { score += 100 }
            else if lower.contains("qwen3") { score += 90 }
            else if lower.contains("gemma4") { score += 85 }
            else if lower.contains("llama") { score += 70 }
        case .openRouter, .blockrun:
            if lower.contains("gpt-5.6") { score += 100 }
            else if lower.contains("deepseek-v4") { score += 95 }
            else if lower.contains("claude") || lower.contains("gemini") { score += 80 }
            else if lower.contains("gpt-5") { score += 70 }
        case .anthropic:
            if lower.contains("opus") { score += 100 }
            else if lower.contains("sonnet") { score += 95 }
            else if lower.contains("haiku") { score += 70 }
        case .google:
            if lower.contains("gemini-3-pro") { score += 100 }
            else if lower.contains("gemini-3") { score += 90 }
            else if lower.contains("flash") { score += 70 }
        case .xai:
            if lower.contains("grok-4") { score += 100 }
            else if lower.contains("grok-3") { score += 80 }
        case .perplexity:
            if lower.contains("sonar-pro") { score += 100 }
            else if lower.contains("sonar") { score += 80 }
        case .groq, .mistral, .compatible:
            break
        }
        return score
    }
}

// MARK: - Chat

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String
    var content: String
    var reasoning: String?
    var error: String?
    var isStreaming: Bool
    let createdAt: Date
    /// The provider/model that actually generated this specific message —
    /// stamped at send time, not read live off whatever's currently
    /// selected. Without this, switching providers mid-conversation
    /// retroactively relabeled every earlier reply with the new provider's
    /// name. `nil` on messages saved before this field existed, or on user
    /// messages, which don't have a generating provider.
    var providerName: String?
    var modelID: String?
    /// Bookmarked within this conversation — distinct from pinning a whole
    /// conversation in the sidebar. Lets a long thread's important reply be
    /// jumped back to directly instead of scrolled for.
    var isPinned: Bool = false
    /// Files attached when this (user) message was sent — images get real
    /// multimodal wiring, everything else is folded into the outgoing text.
    var attachments: [Attachment] = []
    /// Real token usage for this reply, when the provider reported it —
    /// persisted (unlike `AppModel.usageByMessage`, the live in-memory
    /// cache) so lifetime usage statistics survive a relaunch.
    var usage: UsageSummary?
    /// Superseded replies from before an edit-and-regenerate, most recently
    /// superseded first. Elements never carry their own alternates — edit
    /// history stays a flat list on the current message rather than a tree.
    var alternates: [ChatMessage] = []
    /// The ordered render timeline (text runs + activity lines) — see
    /// `MessageSegment`. Empty on user messages and on assistant messages
    /// saved before this field existed; `content` remains canonical.
    var segments: [MessageSegment] = []
    /// For `role: "notice"` cards only: "info", "success", or "warning"
    /// (the default) — a success toast should not wear a warning triangle.
    var noticeKind: String?
    /// Redactions applied to `content` before this message was sent. The
    /// message stores the redacted text — what actually went out — so the
    /// transcript never claims to have sent something it didn't, and the
    /// secret itself is never written to disk. These spans are what the
    /// transcript renders as chips.
    var redactions: [RedactionSpan] = []

    init(role: String, content: String, reasoning: String? = nil, error: String? = nil, isStreaming: Bool = false, providerName: String? = nil, modelID: String? = nil, isPinned: Bool = false, attachments: [Attachment] = [], alternates: [ChatMessage] = []) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.providerName = providerName
        self.modelID = modelID
        self.attachments = attachments
        self.error = error
        self.isStreaming = isStreaming
        self.createdAt = Date()
        self.isPinned = isPinned
        self.alternates = alternates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        isStreaming = try container.decode(Bool.self, forKey: .isStreaming)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        usage = try container.decodeIfPresent(UsageSummary.self, forKey: .usage)
        alternates = try container.decodeIfPresent([ChatMessage].self, forKey: .alternates) ?? []
        segments = try container.decodeIfPresent([MessageSegment].self, forKey: .segments) ?? []
        noticeKind = try container.decodeIfPresent(String.self, forKey: .noticeKind)
        redactions = try container.decodeIfPresent([RedactionSpan].self, forKey: .redactions) ?? []
    }

    /// Full-field copy initializer — the only way to reproduce a message
    /// with a chosen id/createdAt (the memberwise init hardcodes both).
    init(id: UUID, role: String, content: String, reasoning: String?, error: String?, isStreaming: Bool, createdAt: Date, providerName: String?, modelID: String?, isPinned: Bool, attachments: [Attachment], usage: UsageSummary?, alternates: [ChatMessage], segments: [MessageSegment], noticeKind: String?, redactions: [RedactionSpan] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.error = error
        self.isStreaming = isStreaming
        self.createdAt = createdAt
        self.providerName = providerName
        self.modelID = modelID
        self.isPinned = isPinned
        self.attachments = attachments
        self.usage = usage
        self.alternates = alternates
        self.segments = segments
        self.noticeKind = noticeKind
        self.redactions = redactions
    }

    /// A copy with a fresh identity (alternates re-id'd too) — used by
    /// conversation branching, where duplicated ids across two live
    /// conversations would confuse every id-keyed lookup.
    func duplicatedWithFreshID() -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            content: content,
            reasoning: reasoning,
            error: error,
            isStreaming: false,
            createdAt: createdAt,
            providerName: providerName,
            modelID: modelID,
            isPinned: isPinned,
            attachments: attachments,
            usage: usage,
            alternates: alternates.map { $0.duplicatedWithFreshID() },
            segments: segments,
            noticeKind: noticeKind,
            redactions: redactions
        )
    }

    /// If this message's content contains a well-formed ```ask-user fenced
    /// block, splits it into the prose before the block and the parsed
    /// question — `nil` while the block isn't complete yet (still
    /// streaming) or isn't present at all. Parsed on demand rather than
    /// stored, since it's cheap and only ever needed at render time.
    var askQuestion: (prefix: String, payload: AskUserQuestionPayload, suffix: String)? {
        AskUserQuestionPayload.parse(from: content)
    }

    /// Local-only UI artifacts — `"notice"` cards and `"compaction"`
    /// markers — never real conversation content. Anywhere that builds
    /// what actually gets sent to a provider, or asks "has this
    /// conversation really been used," needs to look past both.
    var isSynthetic: Bool { role == "notice" || role == "compaction" }

    /// Text content plus any non-image attachments folded in as labeled
    /// blocks — the wire-format-agnostic way file attachments reach every
    /// provider, since it works over plain text with no special request
    /// shape needed. Images are handled separately (`imageAttachments`),
    /// since they need real multimodal content parts, not text.
    var contentForRequest: String {
        let included = attachments.filter { $0.isIncluded && $0.kind != .image }
        guard !included.isEmpty else { return content }
        let blocks = included.compactMap { attachment -> String? in
            guard let text = attachment.textContent else { return nil }
            return "--- Attached file: \(attachment.filename) ---\n\(text)"
        }
        guard !blocks.isEmpty else { return content }
        let joined = blocks.joined(separator: "\n\n")
        return content.isEmpty ? joined : "\(content)\n\n\(joined)"
    }

    /// Included image attachments, in order — real multimodal content for
    /// vision-capable models.
    var imageAttachments: [Attachment] {
        attachments.filter { $0.isIncluded && $0.kind == .image }
    }
}

/// The model asks a multiple-choice question mid-reply instead of guessing —
/// the same shape Claude Code's own `AskUserQuestion` tool uses, adapted to
/// a fenced-block convention any OpenAI-compatible or Anthropic model can
/// use without real function calling. Taught to the model via a fixed
/// system-prompt instruction (`AppModel.askUserQuestionInstruction`).
struct AskUserQuestionPayload: Decodable, Equatable {
    struct Option: Decodable, Equatable, Identifiable {
        var id: String { label }
        let label: String
        let description: String?
        /// At most one per question — rendered with a "(Recommended)" tag.
        var recommended: Bool = false

        private enum CodingKeys: String, CodingKey { case label, description, recommended }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try AskUserQuestionPayload.lenientString(container, forKey: .label)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            recommended = AskUserQuestionPayload.lenientBool(container, forKey: .recommended, default: false)
        }
    }

    struct Question: Decodable, Equatable, Identifiable {
        var id: String { question }
        /// Short chip label ("Approach", "Scope") shown above the question
        /// in multi-question cards.
        let header: String?
        let question: String
        let options: [Option]
        var multiSelect: Bool = false

        private enum CodingKeys: String, CodingKey { case header, question, options, multiSelect }

        init(header: String?, question: String, options: [Option], multiSelect: Bool) {
            self.header = header
            self.question = question
            self.options = options
            self.multiSelect = multiSelect
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            header = try container.decodeIfPresent(String.self, forKey: .header)
            question = try container.decode(String.self, forKey: .question)
            options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
            multiSelect = AskUserQuestionPayload.lenientBool(container, forKey: .multiSelect, default: false)
        }
    }

    /// 1–4 questions per card. The legacy single-question JSON shape
    /// (top-level question/options/multiSelect) still decodes, as one
    /// entry here — older transcripts keep rendering.
    let questions: [Question]
    var allowNotes: Bool = true

    private enum CodingKeys: String, CodingKey {
        case question, options, multiSelect, allowNotes, questions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowNotes = try container.decodeIfPresent(Bool.self, forKey: .allowNotes) ?? true
        if let multi = try container.decodeIfPresent([Question].self, forKey: .questions) {
            questions = Array(multi.prefix(4))
        } else {
            let question = try container.decode(String.self, forKey: .question)
            let options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
            let multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
            questions = [Question(header: nil, question: question, options: options, multiSelect: multiSelect)]
        }
    }

    /// Rebuilds a payload with a trimmed `questions` list — used by `parse`
    /// to drop individually-malformed questions without needing a public
    /// memberwise initializer (this type otherwise only decodes).
    private init(questions: [Question], allowNotes: Bool) {
        self.questions = questions
        self.allowNotes = allowNotes
    }

    /// What the card's one primary button does at a given position.
    ///
    /// Every question used to share a single `Send`, which was a trap on a
    /// multi-question card: answering the first one and pressing the obvious
    /// button fired the whole card off with the rest blank, and nothing said
    /// the other tabs were still there. The button now advances until the
    /// last question, so reaching `Send` is deliberate.
    ///
    /// It lives here, as data, rather than as a branch inside the view so
    /// the progression can be tested without a running SwiftUI hierarchy —
    /// the property that matters (every intermediate press advances, *only*
    /// the last submits) is exactly the kind that silently regresses.
    enum PrimaryAction: Equatable {
        case next(index: Int)
        case send

        var title: String {
            switch self {
            case .next: "Next"
            case .send: "Send"
            }
        }
    }

    static func primaryAction(activeIndex: Int, questionCount: Int) -> PrimaryAction {
        guard activeIndex < questionCount - 1 else { return .send }
        return .next(index: activeIndex + 1)
    }

    /// A real payload was once rejected outright and fell through to the
    /// generic Markdown code-block renderer (raw JSON in a box titled
    /// "Ask-User") because a *type*, not a shape, was off: a model emitted
    /// `"recommended": "true"` (a string) or `"multiSelect": 1` instead of a
    /// real JSON boolean. `JSONDecoder` fails a whole `decode` call on one
    /// such mismatch — there's no partial-credit — so one wrong-shaped field
    /// three questions deep sank an otherwise well-formed card. Confirmed
    /// with a standalone harness against `JSONDecoder` directly before
    /// writing this: `"true"`/`"1"`/`"yes"` (any case) and nonzero ints all
    /// decode as `true` here instead of throwing.
    private static func lenientBool<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        default defaultValue: Bool
    ) -> Bool {
        if let bool = try? container.decodeIfPresent(Bool.self, forKey: key) { return bool }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return ["true", "1", "yes"].contains(text.lowercased())
        }
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) { return number != 0 }
        return defaultValue
    }

    /// Same idea for a required string field — an option `label` sometimes
    /// arrives as a bare JSON number (`3` instead of `"3"`) when the choices
    /// themselves are numeric. Genuinely missing/malformed input still
    /// throws the real decode error via the final fallback, rather than
    /// being masked.
    private static func lenientString<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> String {
        if let text = try? container.decode(String.self, forKey: key) { return text }
        if let integer = try? container.decode(Int.self, forKey: key) { return String(integer) }
        if let number = try? container.decode(Double.self, forKey: key) {
            return number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(number)) : String(number)
        }
        return try container.decode(String.self, forKey: key)
    }

    /// The opening tag: case-insensitive and tolerant of 4+ backtick fences
    /// (a model nesting an example inside its own description sometimes
    /// widens the outer fence) — but still anchored to the *start of a
    /// line* with nothing else on it besides optional trailing whitespace.
    /// That anchor is deliberately not relaxed further: it's what stops a
    /// sentence like "use ```ask-user to signal a question" from opening a
    /// card, and loosening it to tolerate JSON glued onto the same line
    /// would reopen exactly that hole. A fully single-line block (fence,
    /// JSON, and closing fence with no line breaks at all) is therefore
    /// still correctly left as plain text — a much rarer shape than any of
    /// the cases fixed below, and not worth that trade.
    private static let openFencePattern = #"(?mi)^`{3,}[ \t]*ask-user[ \t]*$"#
    /// The well-formed close: 3+ backticks alone at the start of a line.
    /// Unlike the old pattern, trailing content glued onto that same line
    /// (a model continuing its sentence right after the fence, with no
    /// blank line) no longer prevents a match — it just becomes part of the
    /// suffix, which was already being preserved for the newline-separated
    /// case.
    private static let closeFenceAtLineStartPattern = #"(?m)^`{3,}"#
    /// Fallback for a model that closes the block on the very same line the
    /// JSON ends on (no newline between `}` and the closing fence at all,
    /// so it isn't at a line start). Only ever consulted after a real
    /// ```ask-user open has already matched, so it can't turn unrelated
    /// prose elsewhere in the message into a false positive.
    private static let closeFenceAnywherePattern = #"`{3,}"#

    private static func closingFenceRange(in content: String, after openEnd: String.Index) -> Range<String.Index>? {
        let searchRange = openEnd..<content.endIndex
        if let match = content.range(of: closeFenceAtLineStartPattern, options: .regularExpression, range: searchRange) {
            return match
        }
        return content.range(of: closeFenceAnywherePattern, options: .regularExpression, range: searchRange)
    }

    /// Fences must sit at the start of a line — prose that merely *mentions*
    /// the ```ask-user format (e.g. the model explaining the convention) no
    /// longer swallows the whole reply into a card. Text after the closing
    /// fence is preserved, not silently dropped.
    static func parse(from content: String) -> (prefix: String, payload: AskUserQuestionPayload, suffix: String)? {
        guard let openMatch = content.range(of: openFencePattern, options: .regularExpression),
              let closeMatch = closingFenceRange(in: content, after: openMatch.upperBound) else {
            return nil
        }
        let jsonText = content[openMatch.upperBound..<closeMatch.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AskUserQuestionPayload.self, from: data),
              !payload.questions.isEmpty else {
            return nil
        }
        // One malformed question (missing/too-few options) used to sink the
        // whole card even when the rest were fine — drop just the bad ones
        // and keep going as long as at least one real question survives.
        let validQuestions = payload.questions.filter { !$0.question.isEmpty && $0.options.count >= 2 }
        guard !validQuestions.isEmpty else { return nil }
        let usable = validQuestions.count == payload.questions.count
            ? payload
            : AskUserQuestionPayload(questions: validQuestions, allowNotes: payload.allowNotes)
        let prefix = String(content[content.startIndex..<openMatch.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(content[closeMatch.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (prefix, usable, suffix)
    }

    /// True while a line-start ```ask-user fence has opened but not closed —
    /// the streaming state where the raw JSON must be hidden behind a
    /// placeholder instead of typing itself out on screen.
    static func hasUnterminatedFence(in content: String) -> Bool {
        guard let openMatch = content.range(of: openFencePattern, options: .regularExpression) else {
            return false
        }
        return closingFenceRange(in: content, after: openMatch.upperBound) == nil
    }

    /// The prose before an unterminated fence — shown above the
    /// "Preparing a question…" placeholder while streaming.
    static func prefixBeforeUnterminatedFence(in content: String) -> String {
        guard let openMatch = content.range(of: openFencePattern, options: .regularExpression) else {
            return content
        }
        return String(content[content.startIndex..<openMatch.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
@Observable
final class Conversation: Identifiable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var providerID: UUID?
    var model: String
    var createdAt: Date
    var updatedAt: Date

    var draftText: String
    /// Staged for the next send, not yet part of any message — deliberately
    /// not persisted across a relaunch (unlike `draftText`), so an unsent
    /// image doesn't bloat saved history on disk before it's even sent.
    var draftAttachments: [Attachment] = []
    var titleIsCustom: Bool
    var isPinned: Bool
    /// Skills invoked via the `/` menu, by folder path (stable across
    /// relaunches, unlike an in-memory `Skill` reference) — their bodies get
    /// appended as extra system context on every request for the rest of
    /// this conversation, the same shape custom instructions already use.
    var activeSkillPaths: [String]
    /// User-chosen local folder acting as this conversation's workspace
    /// root (file tools + run_command operate inside it). `nil` = the
    /// synthetic per-conversation directory.
    var workspaceRootPath: String?
    /// Session-scoped run_command trust: armed "allow all" plus exact
    /// commands the user marked always-allowed. Deliberately not
    /// persisted — trust re-arms per app run.
    var allowAllCommands = false
    var alwaysAllowedCommands: Set<String> = []

    var isGenerating: Bool = false
    var generationProviderName: String = ""
    var generationTask: Task<Void, Never>?
    /// The assistant message ID the *current* generation is for — checked
    /// by `finishGeneration`/`failGeneration` before they mutate
    /// `isGenerating`/`generationTask`. Without this, a Stop immediately
    /// followed by a new Send let the just-cancelled task's completion
    /// handler (which runs asynchronously, after the new generation has
    /// already started) stomp the new generation's state once it woke up
    /// on its cancellation. Ephemeral, like `generationTask` — not
    /// persisted.
    var currentGenerationID: UUID?

    init(id: UUID = UUID(), title: String = "New conversation", messages: [ChatMessage] = [], providerID: UUID? = nil, model: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), draftText: String = "", titleIsCustom: Bool = false, isPinned: Bool = false, activeSkillPaths: [String] = [], workspaceRootPath: String? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.providerID = providerID
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.draftText = draftText
        self.titleIsCustom = titleIsCustom
        self.isPinned = isPinned
        self.activeSkillPaths = activeSkillPaths
        self.workspaceRootPath = workspaceRootPath
    }

    /// The directory every workspace tool (and run_command) resolves
    /// against — the user's chosen folder when one is attached, else the
    /// synthetic per-conversation dir.
    var workspaceRoot: URL {
        if let workspaceRootPath, FileManager.default.fileExists(atPath: workspaceRootPath) {
            return URL(fileURLWithPath: workspaceRootPath, isDirectory: true)
        }
        return SandboxManager.directory(for: id)
    }

    /// `"notice"`-role messages are synthetic, local-only UI cards (errors
    /// like "choose a provider first" rendered inline in the transcript
    /// instead of a banner) — never real conversation content. Anywhere that
    /// asks "has this conversation actually been used" or "what's the real
    /// exchange so far" needs to look past them, or an unrelated notice
    /// would make an otherwise-empty conversation look used, break first-
    /// message title-setting, or throw off the AI-retitling trigger.
    var realMessages: [ChatMessage] { messages.filter { !$0.isSynthetic } }

    var pinnedMessages: [ChatMessage] { messages.filter(\.isPinned) }

    /// The most recent compaction marker, if this conversation has been
    /// compacted at least once — everything up to and including it collapses
    /// into its `content` (the generated summary) for future requests;
    /// everything after it stays full, real messages.
    var lastCompactionIndex: Int? { messages.lastIndex(where: { $0.role == "compaction" }) }

    /// A failed or still-empty-but-streaming last message used to render as
    /// "No messages yet" — indistinguishable from a genuinely new,
    /// never-used conversation, which hides real failures from the sidebar.
    var lastMessage: String {
        guard let last = realMessages.last else { return "No messages yet" }
        if let error = last.error, !error.isEmpty { return "⚠ \(error)" }
        if last.isStreaming { return last.content.isEmpty ? "Generating…" : last.content }
        if !last.content.isEmpty { return last.content }
        // A genuinely empty, non-error, non-streaming last message (e.g. a
        // reply that came back with no content) — fall back to the most
        // recent message that has something to show rather than claiming
        // the conversation was never used.
        return realMessages.last(where: { !$0.content.isEmpty })?.content ?? "No messages yet"
    }
}

struct SavedConversation: Codable {
    let id: UUID
    let title: String
    let messages: [ChatMessage]
    let providerID: UUID?
    let model: String
    let createdAt: Date
    let updatedAt: Date
    var draftText: String = ""
    var titleIsCustom: Bool = false
    var isPinned: Bool = false
    var activeSkillPaths: [String] = []
    /// User-chosen local folder acting as this conversation's workspace
    /// root instead of the synthetic per-conversation directory.
    var workspaceRootPath: String?

    init(id: UUID, title: String, messages: [ChatMessage], providerID: UUID?, model: String, createdAt: Date, updatedAt: Date, draftText: String = "", titleIsCustom: Bool = false, isPinned: Bool = false, activeSkillPaths: [String] = [], workspaceRootPath: String? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.providerID = providerID
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.draftText = draftText
        self.titleIsCustom = titleIsCustom
        self.isPinned = isPinned
        self.activeSkillPaths = activeSkillPaths
        self.workspaceRootPath = workspaceRootPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        providerID = try container.decodeIfPresent(UUID.self, forKey: .providerID)
        model = try container.decode(String.self, forKey: .model)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        draftText = try container.decodeIfPresent(String.self, forKey: .draftText) ?? ""
        titleIsCustom = try container.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        activeSkillPaths = try container.decodeIfPresent([String].self, forKey: .activeSkillPaths) ?? []
        workspaceRootPath = try container.decodeIfPresent(String.self, forKey: .workspaceRootPath)
    }
}

/// A provider's live rate-limit/quota state, parsed from response headers
/// when the provider sends them (Anthropic's anthropic-ratelimit-*,
/// OpenAI-style x-ratelimit-*). Session-only — never persisted.
struct QuotaSnapshot: Sendable, Equatable, Codable {
    /// A subscription-style usage window (Codex/ChatGPT plans): percent
    /// used of a rolling window, e.g. 5-hour and weekly.
    struct Window: Sendable, Equatable, Codable {
        var usedPercent: Double
        var windowMinutes: Int?
        var resetAt: Date?

        var label: String {
            switch windowMinutes {
            case .some(let minutes) where minutes >= 10_000: return "Weekly limit"
            case .some(let minutes) where minutes >= 60: return "\(minutes / 60)-hour limit"
            case .some(let minutes): return "\(minutes)-minute limit"
            case nil: return "Usage limit"
            }
        }
    }

    var requestsRemaining: Int?
    var requestsLimit: Int?
    var tokensRemaining: Int?
    var tokensLimit: Int?
    var resetAt: Date?
    /// Codex subscription windows, verified live against the real
    /// backend's x-codex-* headers.
    var primaryWindow: Window?
    var secondaryWindow: Window?
    var planName: String?
    var capturedAt = Date()

    init?(headers rawHeaders: [AnyHashable: Any]) {
        var headers: [String: String] = [:]
        for (headerKey, headerValue) in rawHeaders {
            headers[String(describing: headerKey).lowercased()] = String(describing: headerValue)
        }
        func int(_ names: [String]) -> Int? {
            for name in names { if let value = headers[name].flatMap(Int.init) { return value } }
            return nil
        }
        requestsRemaining = int(["anthropic-ratelimit-requests-remaining", "x-ratelimit-remaining-requests"])
        requestsLimit = int(["anthropic-ratelimit-requests-limit", "x-ratelimit-limit-requests"])
        tokensRemaining = int(["anthropic-ratelimit-tokens-remaining", "anthropic-ratelimit-input-tokens-remaining", "x-ratelimit-remaining-tokens"])
        tokensLimit = int(["anthropic-ratelimit-tokens-limit", "anthropic-ratelimit-input-tokens-limit", "x-ratelimit-limit-tokens"])
        for name in ["anthropic-ratelimit-requests-reset", "anthropic-ratelimit-tokens-reset", "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens"] {
            guard let raw = headers[name] else { continue }
            if let date = ISO8601DateFormatter().date(from: raw) {
                resetAt = date
                break
            }
            if let seconds = Self.durationSeconds(raw) {
                resetAt = Date().addingTimeInterval(seconds)
                break
            }
        }
        func codexWindow(_ prefix: String) -> Window? {
            guard let used = headers["x-codex-\(prefix)-used-percent"].flatMap(Double.init) else { return nil }
            let minutes = headers["x-codex-\(prefix)-window-minutes"].flatMap(Int.init)
            if minutes == 0 { return nil }
            let reset = headers["x-codex-\(prefix)-reset-at"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            return Window(usedPercent: used, windowMinutes: minutes, resetAt: reset)
        }
        primaryWindow = codexWindow("primary")
        secondaryWindow = codexWindow("secondary")
        if let plan = headers["x-codex-plan-type"], !plan.isEmpty {
            planName = plan.capitalized
        }
        if requestsRemaining == nil, tokensRemaining == nil, resetAt == nil,
           primaryWindow == nil, secondaryWindow == nil { return nil }
    }

    /// OpenAI reset strings look like "1s", "6m0s", "7.66s".
    private static func durationSeconds(_ raw: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var matched = false
        for character in raw {
            if character.isNumber || character == "." {
                number.append(character)
            } else {
                guard let value = TimeInterval(number) else { return nil }
                switch character {
                case "h": total += value * 3600
                case "m": total += value * 60
                case "s": total += value
                default: return nil
                }
                number = ""
                matched = true
            }
        }
        return matched ? total : nil
    }

    /// 0…1 used fraction, from whichever limit pair is known.
    var usedFraction: Double? {
        if let remaining = requestsRemaining, let limit = requestsLimit, limit > 0 {
            return 1 - Double(remaining) / Double(limit)
        }
        if let remaining = tokensRemaining, let limit = tokensLimit, limit > 0 {
            return 1 - Double(remaining) / Double(limit)
        }
        return nil
    }
}

/// Cache-write tokens split by TTL tier. Writes are billed at 1.25x
/// (5-minute) and 2x (1-hour) base input, so the split is not cosmetic —
/// collapsing it would misprice by up to 60%.
struct CacheCreationTokens: Sendable, Equatable {
    var ephemeral5m: Int?
    var ephemeral1h: Int?

    var total: Int? {
        guard ephemeral5m != nil || ephemeral1h != nil else { return nil }
        return (ephemeral5m ?? 0) + (ephemeral1h ?? 0)
    }
}

enum ChatStreamEvent: Sendable {
    case delta(content: String, reasoning: String)
    /// `cachedTokens`: real provider-reported cache-hit tokens — OpenAI's
    /// `usage.prompt_tokens_details.cached_tokens`, DeepSeek's
    /// `prompt_cache_hit_tokens`, or Anthropic's `cache_read_input_tokens`.
    /// `nil` when the provider doesn't report it at all (not the same as
    /// zero — zero means "reported, no hit this time").
    /// `cacheCreation`: cache *writes*, split by TTL tier. Only Anthropic
    /// reports this (`cache_creation.ephemeral_5m_input_tokens` /
    /// `ephemeral_1h_input_tokens`, confirmed against a recorded live
    /// session); everyone else sends `nil`, which stays distinct from a
    /// reported zero.
    case usage(prompt: Int?, completion: Int?, cachedTokens: Int?, cacheCreation: CacheCreationTokens?)
    /// The reply's terminal state, when the provider reports one —
    /// "length" (normalized from length/max_tokens) drives auto-continue.
    case finished(reason: String?)
    /// A tool call began executing — the transcript shows a running
    /// activity line at the exact point in the reply where the model
    /// paused. The multi-round request/response exchange happens inside
    /// `CompatibleChatClient`; callers never see raw wire messages.
    case activityStarted(id: UUID, name: String, argument: String)
    /// The matching call finished (or failed — the error text still goes
    /// back to the model as the tool result so it can retry).
    case activityFinished(id: UUID, result: String, isError: Bool)
    /// Live rate-limit headers seen on a response.
    case quota(QuotaSnapshot)
}

struct UsageSummary: Codable, Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    /// Real provider-reported cache-hit tokens (cache *reads*) — see
    /// `ChatStreamEvent.usage`. Only ever what the provider actually
    /// reported, never estimated.
    var cachedTokens: Int?
    /// Cache *writes*, split by TTL tier. Anthropic reports these as
    /// `cache_creation.ephemeral_5m_input_tokens` /
    /// `ephemeral_1h_input_tokens`; verified against a recorded live
    /// session. OpenAI-compatible providers report neither, so `nil`
    /// stays meaningfully distinct from `0` — "not reported" is not
    /// "none were written".
    var cacheCreation5mTokens: Int?
    var cacheCreation1hTokens: Int?
    /// A cost the provider computed itself (OpenRouter, and Claude Code's
    /// `total_cost_usd`). Preferred over local math when present, and
    /// labelled as provider-reported so it is never confused with a
    /// figure VelaChat derived.
    var providerReportedCostUSD: Double?
    /// Batch requests bill at half rate.
    var isBatch: Bool = false

    var label: String? {
        guard let completionTokens else { return nil }
        var text: String
        if let promptTokens { text = "\(promptTokens + completionTokens) tokens" } else { text = "\(completionTokens) tokens" }
        if let cachedTokens, cachedTokens > 0 { text += " · \(cachedTokens) cached" }
        return text
    }

    /// Cache writes across both tiers, or `nil` when the provider reported
    /// neither. Kept separate from `cachedTokens` (reads) because they are
    /// billed at opposite ends of the scale: reads at 0.10×, writes at
    /// 1.25×/2×.
    var cacheCreationTokens: Int? {
        guard cacheCreation5mTokens != nil || cacheCreation1hTokens != nil else { return nil }
        return (cacheCreation5mTokens ?? 0) + (cacheCreation1hTokens ?? 0)
    }
}

struct WebSearchResult: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let url: String
    let snippet: String
}

struct WebSearchRecord {
    let query: String
    let results: [WebSearchResult]
}

