import Foundation

/// Every `UserDefaults` key VelaChat writes, in one place.
///
/// These strings were previously repeated as literals across ten files,
/// which made two things easy to get wrong: silently reading a key nobody
/// writes (a typo compiles fine), and losing data during a rename because
/// nothing showed you every use. Adding a key here is the only way to add
/// one, and `Defaults` gives the small typed accessors the call sites
/// actually want.
public enum DefaultsKey {
    // Appearance and layout
    public static let accentPreset = "velachat.accent-preset"
    public static let messageWidth = "velachat.message-width"
    public static let density = "velachat.density"
    public static let sidebarWidth = "velachat.sidebar-width"
    public static let sidebarRail = "velachat.sidebar-rail"
    public static let inspectorWidth = "velachat.inspector-width"
    public static let hoverTimestamps = "velachat.hover-timestamps-enabled"

    // Onboarding and conversations
    public static let hasOnboarded = "velachat.has-onboarded"
    public static let conversations = "velachat.conversations"
    public static let autoTitle = "velachat.auto-title-enabled"
    public static let customInstructions = "velachat.custom-instructions"
    public static let promptSnippets = "velachat.prompt-snippets"
    /// The pre-`MemoryStore` fact array. Read exactly once, by
    /// `LegacyMemoryMigration`, and removed the moment every fact is
    /// verified inside the store — facts have one home now.
    public static let memories = "velachat.memories"
    /// Set once `memories` has been migrated into `MemoryStore` and
    /// deleted. Unset means the legacy array is still authoritative and
    /// must not be touched (precedent: `skillsMigrationV1`).
    public static let memoriesMigrationV1 = "velachat.memories-migration-v1"
    /// Per-provider memory permission, suffixed with the provider's UUID.
    public static let memoryAllowedPrefix = "velachat.memory-allowed."
    /// Opt-in hosted embeddings for memory. OFF unless the user turns it
    /// on: enabling it means memory text leaves this Mac.
    public static let remoteEmbeddingsEnabled = "velachat.remote-embeddings-enabled"
    public static let remoteEmbeddingEndpoint = "velachat.remote-embedding-endpoint"
    public static let remoteEmbeddingModel = "velachat.remote-embedding-model"
    /// Which provider profile's key authenticates the embedding endpoint.
    public static let remoteEmbeddingProvider = "velachat.remote-embedding-provider"

    // Providers
    public static let providerProfiles = "velachat.provider-profiles"
    public static let selectedProvider = "velachat.selected-provider"
    public static let explicitProviderSelection = "velachat.explicit-provider-selection"
    public static let modelCatalogs = "velachat.model-catalogs"
    public static let modelFavorites = "velachat.model-favorites"
    public static let modelRecents = "velachat.model-recents"
    public static let contextWindowOverrides = "velachat.context-window-overrides"
    /// Context windows read out of a provider's own error text. Kept apart
    /// from the manual overrides above so a learned number can never
    /// silently replace a human's explicit correction — see
    /// `ContextWindowResolver` for the precedence that distinction buys.
    public static let learnedContextWindows = "velachat.learned-context-windows"
    /// Per-model characters-per-token ratios fitted from provider-reported
    /// `prompt_tokens` (`TokenCalibrationStore`). Small numbers only.
    public static let tokenRatios = "velachat.token-ratios"
    public static let thinkingLevel = "velachat.thinking-level"
    public static let usageLedger = "velachat.usage-ledger"
    public static let quotaSnapshots = "velachat.quota-snapshots"
    /// Recently attached project folders — plain path strings, most recent
    /// first (the bookmark is re-created fresh on every reattach).
    public static let recentProjects = "velachat.recent-projects"
    /// Session-scoped "allow file edits in this folder" answers for the
    /// write gate. Deliberately session-only: trust resets with the app.
    public static let workspaceWriteApprovals = "velachat.workspace-write-approvals"

    // ChatGPT provider
    public static let chatGPTDeviceID = "velachat.chatgpt-device-id"
    public static let chatGPTImportBrowser = "velachat.chatgpt-import-browser"

    // Tools and agent abilities
    public static let workspaceEnabled = "velachat.workspace-enabled"
    public static let conversationSearchEnabled = "velachat.conversation-search-enabled"
    public static let webSearchEnabled = "velachat.web-search-enabled"
    public static let searchEndpoint = "velachat.search-endpoint"
    public static let scheduleToolEnabled = "velachat.schedule-tool-enabled"
    public static let clipboardToolEnabled = "velachat.clipboard-tool-enabled"
    public static let agentToolsEnabled = "velachat.agent-tools-enabled"
    public static let commandToolEnabled = "velachat.command-tool-enabled"
    /// Per-attached-folder run_command allow rules (see `CommandTrust`).
    /// Small prefix strings keyed by folder path — never command output.
    public static let commandAllowRules = "velachat.command-allow-rules"
    /// Whether a substantial-looking draft is offered planning mode.
    public static let planningSuggestion = "velachat.planning-suggestion"
    public static let subagentsEnabled = "velachat.subagents-enabled"
    public static let subagentApproval = "velachat.subagent-approval"
    public static let subagentModel = "velachat.subagent-model"
    public static let appleIntelligenceEnabled = "velachat.apple-intelligence-enabled"

    // Egress controls
    public static let redactionEnabled = "velachat.redaction-enabled"
    public static let redactionRules = "velachat.redaction-rules"
    public static let localOnlyMode = "velachat.local-only-mode"

    // Extensions
    public static let mcpServers = "velachat.mcp-servers"
    public static let customSkillPaths = "velachat.custom-skill-paths"
    public static let skillsMigrationV1 = "velachat.skills-migration-v1"

    /// The prefix a full reset purges — every key above shares it, and the
    /// reset path relies on that rather than an enumerated list it could
    /// fall behind on.
    public static let prefix = "velachat."
}

/// Small typed helpers so call sites stop repeating the
/// "read it, but only if it was ever written" dance around `Bool`
/// (`UserDefaults.bool(forKey:)` returns false for a missing key, which
/// silently turns every default-on setting off).
public enum Defaults {
    private static var store: UserDefaults { .standard }

    /// A stored `Bool`, or `fallback` when the user has never set it.
    public static func bool(_ key: String, default fallback: Bool) -> Bool {
        store.object(forKey: key) == nil ? fallback : store.bool(forKey: key)
    }

    public static func set(_ value: Bool, _ key: String) { store.set(value, forKey: key) }

    public static func string(_ key: String) -> String? { store.string(forKey: key) }
    public static func set(_ value: String?, _ key: String) { store.set(value, forKey: key) }

    public static func data(_ key: String) -> Data? { store.data(forKey: key) }
    public static func set(_ value: Data?, _ key: String) { store.set(value, forKey: key) }

    public static func double(_ key: String) -> Double { store.double(forKey: key) }
    public static func set(_ value: Double, _ key: String) { store.set(value, forKey: key) }

    public static func stringArray(_ key: String) -> [String]? { store.stringArray(forKey: key) }
    public static func set(_ value: [String], _ key: String) { store.set(value, forKey: key) }

    public static func has(_ key: String) -> Bool { store.object(forKey: key) != nil }
    public static func remove(_ key: String) { store.removeObject(forKey: key) }

    /// Encodes a `Codable` value, or removes the key when it is nil.
    public static func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            store.removeObject(forKey: key)
            return
        }
        store.set(data, forKey: key)
    }

    /// Decodes a `Codable` value. Persisted caches are deliberately
    /// forgiving — a decode failure means "refetch", never a crash.
    public static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
