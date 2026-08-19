import Foundation

/// Every `UserDefaults` key VelaChat writes, in one place.
///
/// These strings were previously repeated as literals across ten files,
/// which made two things easy to get wrong: silently reading a key nobody
/// writes (a typo compiles fine), and losing data during a rename because
/// nothing showed you every use. Adding a key here is the only way to add
/// one, and `Defaults` gives the small typed accessors the call sites
/// actually want.
enum DefaultsKey {
    // Appearance and layout
    static let accentPreset = "velachat.accent-preset"
    static let messageWidth = "velachat.message-width"
    static let density = "velachat.density"
    static let sidebarWidth = "velachat.sidebar-width"
    static let sidebarRail = "velachat.sidebar-rail"
    static let inspectorWidth = "velachat.inspector-width"
    static let hoverTimestamps = "velachat.hover-timestamps-enabled"

    // Onboarding and conversations
    static let hasOnboarded = "velachat.has-onboarded"
    static let conversations = "velachat.conversations"
    static let autoTitle = "velachat.auto-title-enabled"
    static let customInstructions = "velachat.custom-instructions"
    static let promptSnippets = "velachat.prompt-snippets"
    static let memories = "velachat.memories"

    // Providers
    static let providerProfiles = "velachat.provider-profiles"
    static let selectedProvider = "velachat.selected-provider"
    static let explicitProviderSelection = "velachat.explicit-provider-selection"
    static let modelCatalogs = "velachat.model-catalogs"
    static let modelFavorites = "velachat.model-favorites"
    static let modelRecents = "velachat.model-recents"
    static let contextWindowOverrides = "velachat.context-window-overrides"
    static let thinkingLevel = "velachat.thinking-level"
    static let usageLedger = "velachat.usage-ledger"
    static let quotaSnapshots = "velachat.quota-snapshots"

    // ChatGPT provider
    static let chatGPTDeviceID = "velachat.chatgpt-device-id"
    static let chatGPTImportBrowser = "velachat.chatgpt-import-browser"

    // Tools and agent abilities
    static let workspaceEnabled = "velachat.workspace-enabled"
    static let conversationSearchEnabled = "velachat.conversation-search-enabled"
    static let webSearchEnabled = "velachat.web-search-enabled"
    static let searchEndpoint = "velachat.search-endpoint"
    static let scheduleToolEnabled = "velachat.schedule-tool-enabled"
    static let clipboardToolEnabled = "velachat.clipboard-tool-enabled"
    static let agentToolsEnabled = "velachat.agent-tools-enabled"
    static let commandToolEnabled = "velachat.command-tool-enabled"
    static let subagentsEnabled = "velachat.subagents-enabled"
    static let subagentApproval = "velachat.subagent-approval"
    static let subagentModel = "velachat.subagent-model"
    static let appleIntelligenceEnabled = "velachat.apple-intelligence-enabled"

    // Extensions
    static let mcpServers = "velachat.mcp-servers"
    static let customSkillPaths = "velachat.custom-skill-paths"
    static let skillsMigrationV1 = "velachat.skills-migration-v1"

    /// The prefix a full reset purges — every key above shares it, and the
    /// reset path relies on that rather than an enumerated list it could
    /// fall behind on.
    static let prefix = "velachat."
}

/// Small typed helpers so call sites stop repeating the
/// "read it, but only if it was ever written" dance around `Bool`
/// (`UserDefaults.bool(forKey:)` returns false for a missing key, which
/// silently turns every default-on setting off).
enum Defaults {
    private static var store: UserDefaults { .standard }

    /// A stored `Bool`, or `fallback` when the user has never set it.
    static func bool(_ key: String, default fallback: Bool) -> Bool {
        store.object(forKey: key) == nil ? fallback : store.bool(forKey: key)
    }

    static func set(_ value: Bool, _ key: String) { store.set(value, forKey: key) }

    static func string(_ key: String) -> String? { store.string(forKey: key) }
    static func set(_ value: String?, _ key: String) { store.set(value, forKey: key) }

    static func data(_ key: String) -> Data? { store.data(forKey: key) }
    static func set(_ value: Data?, _ key: String) { store.set(value, forKey: key) }

    static func double(_ key: String) -> Double { store.double(forKey: key) }
    static func set(_ value: Double, _ key: String) { store.set(value, forKey: key) }

    static func stringArray(_ key: String) -> [String]? { store.stringArray(forKey: key) }
    static func set(_ value: [String], _ key: String) { store.set(value, forKey: key) }

    static func has(_ key: String) -> Bool { store.object(forKey: key) != nil }
    static func remove(_ key: String) { store.removeObject(forKey: key) }

    /// Encodes a `Codable` value, or removes the key when it is nil.
    static func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            store.removeObject(forKey: key)
            return
        }
        store.set(data, forKey: key)
    }

    /// Decodes a `Codable` value. Persisted caches are deliberately
    /// forgiving — a decode failure means "refetch", never a crash.
    static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
