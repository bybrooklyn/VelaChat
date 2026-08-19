import Foundation
import Observation
import KeyboardShortcuts
import SwiftUI
import AVFoundation
import AppKit
import UserNotifications
import Network

@MainActor
@Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case chat = "Chat"
        case settings = "Settings"

        var id: String { rawValue }
    }

    static let appVersion = "1.0"

    /// Teaches the model a real capability it has — asking the user a
    /// multiple-choice question instead of guessing — the same idea as
    /// Claude Code's own `AskUserQuestion` tool, adapted to a fenced-block
    /// convention so it works over plain chat completions without needing
    /// real function calling. `AskUserQuestionPayload.parse` (Models.swift)
    /// is the matching reader; `AskUserQuestionCard` (ChatView.swift) is the
    /// interactive card rendered from it.
    static let askUserQuestionInstruction = """
        # Asking the user
        When a real decision or ambiguity is worth pausing on — not for \
        routine replies — ask with a fenced block in exactly this shape, \
        nothing before or after it:

        ```ask-user
        {"questions": [{"header": "Approach", "question": "Which approach should I take?", "multiSelect": false, "options": [{"label": "Short option name", "description": "One-sentence explanation", "recommended": true}, {"label": "Another option", "description": "One-sentence explanation"}]}], "allowNotes": true}
        ```

        Rules: 1–4 questions per block, each with 2–4 mutually distinct \
        options. `header` is a very short chip label (max ~12 chars, e.g. \
        "Scope", "Auth"). Mark at most ONE option per question \
        `"recommended": true` — the one you'd pick — and list it first. \
        Set `"multiSelect": true` only when several options genuinely \
        combine. Batch related decisions into one block instead of asking \
        one at a time across replies. The user's selections (and any note) \
        come back as their next message. Never use this for questions a \
        tool or the conversation itself can answer.
        """

    // The old fenced ```remember``` propose-and-confirm flow is gone: the
    // model manages memory itself through the real save_memory /
    // search_memory / edit_memory tools (ToolCatalog), every write shows as
    // a visible activity line, and Settings → Memory is the user's control
    // surface.

    let providers = ProviderStore()
    let usage = UsageStore()
    let mcp = McpManager()
    let skills = SkillsStore()
    var promptSnippets: [PromptSnippet] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(promptSnippets) {
                UserDefaults.standard.set(data, forKey: DefaultsKey.promptSnippets)
            }
        }
    }
    /// Global, editable, included in every request — see `MemoryItem`.
    var memories: [MemoryItem] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(memories) {
                UserDefaults.standard.set(data, forKey: DefaultsKey.memories)
            }
        }
    }
    var messageWidth: MessageWidthPreset = .comfortable {
        didSet { UserDefaults.standard.set(messageWidth.rawValue, forKey: DefaultsKey.messageWidth) }
    }
    var density: DensityPreset = .comfortable {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: DefaultsKey.density) }
    }
    var section: Section = .chat
    /// Drives NavigationSplitView's column state so the app's own toggle
    /// (sidebar header + floating chip) fully replaces the system toolbar
    /// button — the toolbar band itself is hidden.
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// Narrow icon-rail mode instead of a full collapse. Persisted.
    var isSidebarRail = false {
        didSet { UserDefaults.standard.set(isSidebarRail, forKey: DefaultsKey.sidebarRail) }
    }
    /// Fixed rail width — also the column width while railed.
    static let sidebarRailWidth: CGFloat = 60
    /// The accent hue, observable so picking a swatch actually repaints the
    /// app (Theme reads UserDefaults statically and can't notify anyone) —
    /// RootView re-renders on change via .id.
    var accentPreset: AccentPreset = AccentPreset.current {
        didSet { AccentPreset.current = accentPreset }
    }
    /// First-launch flow gate. Existing installs are migrated to true
    /// silently in init so only genuinely new users see onboarding.
    var hasOnboarded = false {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: DefaultsKey.hasOnboarded) }
    }
    var conversations: [Conversation] = []
    var activeConversationID: UUID?
    /// A transient, non-error status shown near the composer while it's
    /// true (e.g. "Finding a model…") — self-clears on success or failure.
    /// Real errors don't use this; they're posted into the transcript via
    /// `postNotice(_:to:)` instead, so they're never a banner that vanishes
    /// on its own and are always visible in the conversation itself.
    var statusMessage: String?
    /// A new chat that hasn't earned a sidebar row yet — promoted into
    /// `conversations` (with a spring insert) on its first message, and
    /// simply dropped if the user clicks away without using it. Never
    /// persisted.
    var pendingConversation: Conversation?
    var thinkingLevel: ThinkingLevel = .auto {
        didSet { UserDefaults.standard.set(thinkingLevel.rawValue, forKey: DefaultsKey.thinkingLevel) }
    }
    var usageByMessage: [UUID: UsageSummary] = [:]
    var customInstructions: String = "" {
        didSet { UserDefaults.standard.set(customInstructions, forKey: DefaultsKey.customInstructions) }
    }
    var isCommandPaletteShown = false
    /// The transcript find bar (⌘F). Sidebar search moved to ⇧⌘F.
    var isChatFindShown = false
    /// The row briefly outlined after a find-jump.
    var chatFindHighlightID: UUID?
    var speakingMessageID: UUID?
    var searchEndpoint: String = "" {
        didSet { UserDefaults.standard.set(searchEndpoint, forKey: DefaultsKey.searchEndpoint) }
    }
    /// Sticky like ChatGPT's search toggle — stays on across sends until the
    /// user turns it off, not a one-shot-per-message flag. Persisted, so
    /// "sticky" survives a relaunch too.
    var isWebSearchEnabled = false {
        didSet { UserDefaults.standard.set(isWebSearchEnabled, forKey: DefaultsKey.webSearchEnabled) }
    }
    /// Gates the `write_file`/`read_file`/`list_workspace_files` tools —
    /// on by default since they're path-validated into a private,
    /// per-conversation, app-managed folder with no relationship to the
    /// user's real files unless explicitly written there by hand; a real
    /// shell-execution tool would be a materially different risk and isn't
    /// offered at all (see `SandboxManager`).
    var isWorkspaceEnabled = true {
        didSet { UserDefaults.standard.set(isWorkspaceEnabled, forKey: DefaultsKey.workspaceEnabled) }
    }
    /// Gates `search_conversations` — the tool that lets the model read
    /// excerpts of other conversations. On by default; the off switch exists
    /// because it's a real privacy boundary, not because it's risky.
    var isConversationSearchEnabled = true {
        didSet { UserDefaults.standard.set(isConversationSearchEnabled, forKey: DefaultsKey.conversationSearchEnabled) }
    }
    /// Automatic model-generated chat titles after the first exchange.
    var isAutoTitleEnabled = true {
        didSet { UserDefaults.standard.set(isAutoTitleEnabled, forKey: DefaultsKey.autoTitle) }
    }
    /// Hover timestamps on messages.
    var isHoverTimestampsEnabled = true {
        didSet { UserDefaults.standard.set(isHoverTimestampsEnabled, forKey: DefaultsKey.hoverTimestamps) }
    }
    /// Apple Intelligence is OPT-IN: off by default, nothing on-device runs
    /// and the provider stays hidden until the user flips this.
    var isAppleIntelligenceEnabled = false {
        didSet { UserDefaults.standard.set(isAppleIntelligenceEnabled, forKey: DefaultsKey.appleIntelligenceEnabled) }
    }
    /// True only when opted in AND the on-device model is actually usable.
    var canUseAppleIntelligence: Bool { isAppleIntelligenceEnabled && AppleIntelligence.isAvailable }
    /// get_schedule tool (EventKit read) — the system permission prompt is
    /// the real gate; this just removes the tool entirely.
    var isScheduleToolEnabled = true {
        didSet { UserDefaults.standard.set(isScheduleToolEnabled, forKey: DefaultsKey.scheduleToolEnabled) }
    }
    /// read_clipboard tool — clipboard content goes to the provider.
    var isClipboardToolEnabled = true {
        didSet { UserDefaults.standard.set(isClipboardToolEnabled, forKey: DefaultsKey.clipboardToolEnabled) }
    }
    /// Agent abilities: workspace editing/search plus the plan tool.
    var isAgentToolsEnabled = true {
        didSet { UserDefaults.standard.set(isAgentToolsEnabled, forKey: DefaultsKey.agentToolsEnabled) }
    }
    /// run_command — off by default: it executes real shell commands.
    var isCommandToolEnabled = false {
        didSet { UserDefaults.standard.set(isCommandToolEnabled, forKey: DefaultsKey.commandToolEnabled) }
    }
    /// spawn_agents — off by default: each subagent is a real billed
    /// request, and several run at once.
    var isSubagentsEnabled = false {
        didSet { UserDefaults.standard.set(isSubagentsEnabled, forKey: DefaultsKey.subagentsEnabled) }
    }
    /// Ask before each fan-out (they cost several requests at once).
    var isSubagentApprovalRequired = true {
        didSet { UserDefaults.standard.set(isSubagentApprovalRequired, forKey: DefaultsKey.subagentApproval) }
    }
    /// Optional cheaper/faster model for subagents; empty = same model.
    var subagentModelOverride = "" {
        didSet { UserDefaults.standard.set(subagentModelOverride, forKey: DefaultsKey.subagentModel) }
    }

    /// A pending run_command approval, shown as a card in the transcript.
    /// The generation waits on `decide` until the user answers.
    struct CommandApproval: Identifiable {
        let id = UUID()
        let conversationID: UUID
        let command: String
        let directory: URL
        let reason: String
        /// Subagent fan-out reuses this card, but must not offer command
        /// editing or the always-allow paths.
        var isSubagentRequest = false
        let decide: @Sendable (Decision) -> Void

        enum Decision: Sendable {
            case approveOnce(String)
            case approveAlways(String)
            case approveAll(String)
            case deny
        }
    }
    var pendingApproval: CommandApproval?
    /// Live plan steps per assistant message (update_plan) — rendered as
    /// the checklist card in that reply.
    var planByMessage: [UUID: [ToolCatalog.PlanStep]] = [:]
    /// Live network reachability (NWPathMonitor). Drives the offline chip
    /// and lets in-flight sends wait for the network instead of failing.
    var isOnline = true
    private let pathMonitor = NWPathMonitor()

    func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isOnline != online else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.isOnline = online }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "vela.network-path"))
    }

    /// Polls reachability until it returns or the deadline passes. Used by
    /// a queued send that was made while offline — the turn stays on
    /// screen, honestly labeled, and fires the moment the network is back.
    func waitForConnectivity(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isOnline {
            if Date() > deadline || Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return !Task.isCancelled
    }

    /// True for failures worth an automatic, invisible-to-the-answer retry:
    /// network faults and provider-side transience (429/5xx). A 4xx other
    /// than 429 will fail identically on retry and is surfaced immediately.
    nonisolated static func isTransientFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .dataNotAllowed, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        if case APIError.status(let code, _) = error {
            return code == 429 || (500..<600).contains(code)
        }
        return false
    }

    /// Terminal finish reason per reply (transient) — "length" means the
    /// provider cut the reply at its output cap and drives auto-continue.
    var finishReasonByMessage: [UUID: String] = [:]

    /// When each in-flight reply was sent, so time-to-first-token can be
    /// measured rather than guessed at.
    private var sendStartedAt: [UUID: Date] = [:]
    /// Measured TTFT samples, keyed "providerID|modelID". Session-scoped:
    /// what matters is how the app feels now, not a lifetime average that
    /// hides a provider having a bad day.
    private(set) var ttftSamples: [String: [TimeInterval]] = [:]

    /// Work that would otherwise happen inside the first send, moved to
    /// launch where nobody is waiting on it.
    ///
    /// Deliberately does NOT send a model request: warming a provider's
    /// routing with a throwaway completion would spend real tokens and
    /// count against subscription windows for an uncertain gain. Opening
    /// the connection costs nothing and reliably saves the TLS handshake.
    func prewarmForFasterFirstToken() {
        Task { [weak self] in
            guard let self else { return }
            // Cold MCP servers used to spawn inside the generation task,
            // in front of the request — pure added TTFT on the first
            // message. Starting them now makes the tool list cache-warm.
            if !self.mcp.servers.filter({ $0.enabled && !$0.command.isEmpty }).isEmpty {
                _ = await self.mcp.definitionsForSend()
            }
        }
        warmConnection()
    }

    /// Opens (and leaves pooled) a connection to the selected provider so
    /// the first real request skips DNS + TLS. A HEAD to the models path
    /// is the cheapest request that exists on every provider.
    func warmConnection() {
        guard isOnline, let profile = providers.selected, !profile.kind.isLocal else { return }
        let endpoint = profile.endpoint
        Task.detached(priority: .utility) {
            guard let url = URL(string: endpoint) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = Limits.mcpListTimeout
            // The response is irrelevant — even a 404 has done the work of
            // establishing the connection this is here to establish.
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func noteSendStarted(_ assistantID: UUID) {
        sendStartedAt[assistantID] = Date()
    }

    /// Records the interval between sending and the first visible token.
    /// Called from the reveal path, not the network path, so the number
    /// reflects what the user actually waited for.
    func noteFirstToken(for assistantID: UUID, conversation: Conversation) {
        guard let started = sendStartedAt.removeValue(forKey: assistantID) else { return }
        guard let providerID = conversation.providerID else { return }
        let model = conversation.messages.first { $0.id == assistantID }?.modelID ?? conversation.model
        let key = ProviderStore.modelKey(providerID, model)
        ttftSamples[key, default: []].append(Date().timeIntervalSince(started))
        if ttftSamples[key]!.count > 50 { ttftSamples[key]!.removeFirst() }
    }

    /// Median and p90 for a provider+model, or nil without enough samples
    /// to say anything honest.
    func ttftStats(providerID: UUID, model: String) -> (median: TimeInterval, p90: TimeInterval, count: Int)? {
        let samples = ttftSamples[ProviderStore.modelKey(providerID, model)] ?? []
        guard samples.count >= 3 else { return nil }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        return (median, p90, sorted.count)
    }

    var searchByMessage: [UUID: WebSearchRecord] = [:]
    /// Latest live quota data seen per provider — persisted so plan
    /// windows survive a relaunch, shown with an honest "as of" age
    /// (headers only arrive on responses; there is no free refresh).
    var quotaByProvider: [UUID: QuotaSnapshot] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(quotaByProvider) {
                UserDefaults.standard.set(data, forKey: DefaultsKey.quotaSnapshots)
            }
        }
    }

    /// Refresh-on-open for the one provider with a real usage endpoint —
    /// everyone else's quota arrives passively on response headers.
    func refreshChatGPTQuota(_ providerID: UUID) async {
        guard providers.chatGPTSessionPresent else { return }
        guard let snapshot = (try? await ChatGPTWebClient.shared.usageQuota()) ?? nil else { return }
        quotaByProvider[providerID] = snapshot
    }

    private var quotaRefreshTasks: [UUID: Task<Void, Never>] = [:]

    /// Lazy quota refresh, triggered by hovering or opening the gauge.
    /// Debounced by staleness so hovering repeatedly costs nothing, and
    /// deduplicated so a hover already in flight isn't started twice.
    /// `force` (a click) ignores the staleness window but not the dedupe.
    func refreshQuota(for provider: ProviderProfile, force: Bool = false) {
        let staleAfter: TimeInterval = force ? 0 : 120
        if let existing = quotaByProvider[provider.id],
           Date().timeIntervalSince(existing.capturedAt) < staleAfter {
            return
        }
        guard quotaRefreshTasks[provider.id] == nil else { return }
        quotaRefreshTasks[provider.id] = Task { [weak self] in
            defer { self?.quotaRefreshTasks[provider.id] = nil }
            guard let self else { return }
            switch provider.kind {
            case .chatGPT:
                await self.refreshChatGPTQuota(provider.id)
            case .ollama, .lmStudio, .appleIntelligence:
                return  // nothing to ask, nothing to spend
            default:
                // No usage endpoint exists for these — the only honest way
                // to get fresh numbers is a real request whose headers we
                // read. A catalog fetch is the cheapest one available and
                // is something the app already does routinely.
                await self.providers.refreshQuotaHeaders(for: provider.id) { [weak self] snapshot in
                    self?.quotaByProvider[provider.id] = snapshot
                }
            }
        }
    }

    private func restoreQuotaSnapshots() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.quotaSnapshots),
              let saved = try? JSONDecoder().decode([UUID: QuotaSnapshot].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        quotaByProvider = saved.filter { $0.value.capturedAt > cutoff }
    }

    /// True when search is reachable at all: either the provider searches
    /// natively, or a SearXNG endpoint is configured and the model takes tools.
    var canUseWebSearch: Bool {
        guard let kind = selectedProvider?.kind else { return false }
        if !isNativeSearchNone(kind.nativeWebSearch) { return true }
        let hasEndpoint = !searchEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let supportsTools = selectedModelInfo?.supportsTools
            ?? RemoteModel(id: currentModelID).supportsTools
        return hasEndpoint && supportsTools
    }

    /// Explains, in the composer tooltip, which search path a send will take.
    var webSearchDescription: String {
        guard let kind = selectedProvider?.kind else { return "Web search" }
        switch kind.nativeWebSearch {
        case .always: return "\(kind.rawValue) always searches the live web"
        case .onlineSuffix: return "Search the web with OpenRouter’s :online routing"
        case .none: return "Search the web via your SearXNG instance"
        }
    }

    func isNativeSearchNone(_ mode: NativeWebSearch) -> Bool {
        if case .none = mode { return true }
        return false
    }

    private let speechSynthesizer = AVSpeechSynthesizer()
    private let speechDelegate = SpeechSynthesizerDelegate()
    private let historyKey = DefaultsKey.conversations
    private let historyBackupKey = DefaultsKey.conversations + ".backup"
    private var didStart = false
    private var pendingDiscoverySends: Set<UUID> = []
    private var compactingConversationIDs: Set<UUID> = []

    /// Decouples the on-screen reveal pace from provider chunk size: network
    /// events land in an ordered per-message op queue (text, reasoning,
    /// activity lines) and a task drains them in order — text a word at a
    /// time, activities in place — so replies feel like a smooth typewriter
    /// and the timeline order always matches what actually happened.
    private var revealQueues: [UUID: [RevealOp]] = [:]
    private var revealTasks: [UUID: Task<Void, Never>] = [:]
    /// Messages whose stream has ended but whose reveal queue is still
    /// draining — finish work (isStreaming flip, save, notify) runs when
    /// the drain empties instead of snapping the buffer in one frame.
    private var pendingFinish: Set<UUID> = []
    private var historySaveTask: Task<Void, Never>?

    init() {
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.thinkingLevel),
           let saved = ThinkingLevel(rawValue: raw) {
            thinkingLevel = saved
        }
        customInstructions = UserDefaults.standard.string(forKey: DefaultsKey.customInstructions) ?? ""
        searchEndpoint = UserDefaults.standard.string(forKey: DefaultsKey.searchEndpoint) ?? ""
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.promptSnippets),
           let saved = try? JSONDecoder().decode([PromptSnippet].self, from: data) {
            promptSnippets = saved
        }
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.memories),
           let saved = try? JSONDecoder().decode([MemoryItem].self, from: data) {
            memories = saved
        }
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.messageWidth),
           let saved = MessageWidthPreset(rawValue: raw) {
            messageWidth = saved
        }
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.density),
           let saved = DensityPreset(rawValue: raw) {
            density = saved
        }
        isWorkspaceEnabled = Defaults.bool(DefaultsKey.workspaceEnabled, default: isWorkspaceEnabled)
        isConversationSearchEnabled = Defaults.bool(DefaultsKey.conversationSearchEnabled, default: isConversationSearchEnabled)
        isAutoTitleEnabled = Defaults.bool(DefaultsKey.autoTitle, default: isAutoTitleEnabled)
        isHoverTimestampsEnabled = Defaults.bool(DefaultsKey.hoverTimestamps, default: isHoverTimestampsEnabled)
        isAppleIntelligenceEnabled = Defaults.bool(DefaultsKey.appleIntelligenceEnabled, default: false)
        isSidebarRail = Defaults.bool(DefaultsKey.sidebarRail, default: false)
        restoreQuotaSnapshots()
        isAgentToolsEnabled = Defaults.bool(DefaultsKey.agentToolsEnabled, default: isAgentToolsEnabled)
        isCommandToolEnabled = Defaults.bool(DefaultsKey.commandToolEnabled, default: false)
        isSubagentsEnabled = Defaults.bool(DefaultsKey.subagentsEnabled, default: false)
        isSubagentApprovalRequired = Defaults.bool(DefaultsKey.subagentApproval, default: isSubagentApprovalRequired)
        subagentModelOverride = UserDefaults.standard.string(forKey: DefaultsKey.subagentModel) ?? ""
        isScheduleToolEnabled = Defaults.bool(DefaultsKey.scheduleToolEnabled, default: isScheduleToolEnabled)
        isClipboardToolEnabled = Defaults.bool(DefaultsKey.clipboardToolEnabled, default: isClipboardToolEnabled)
        isWebSearchEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.webSearchEnabled)
        hasOnboarded = UserDefaults.standard.bool(forKey: DefaultsKey.hasOnboarded)
        let corruptionNotice = restoreHistory()
        if conversations.isEmpty {
            _ = newConversation()
        }
        // Existing installs never see onboarding — anything already saved
        // marks the app as familiar.
        if !hasOnboarded, !conversations.isEmpty || UserDefaults.standard.data(forKey: historyKey) != nil {
            if conversations.contains(where: { !$0.realMessages.isEmpty }) {
                hasOnboarded = true
            }
        }
        // One-time: auto-discovery of ~/.claude/skills and ~/.codex/skills
        // is gone — skills from there that are ACTIVE in some conversation
        // keep working by becoming explicit custom folders; everything else
        // from those directories stops appearing (intended).
        if !UserDefaults.standard.bool(forKey: DefaultsKey.skillsMigrationV1) {
            UserDefaults.standard.set(true, forKey: DefaultsKey.skillsMigrationV1)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let autoRoots = [home + "/.claude/skills/", home + "/.codex/skills/"]
            let activePaths = Set(conversations.flatMap(\.activeSkillPaths))
            for path in activePaths where autoRoots.contains(where: { path.hasPrefix($0) }) {
                if FileManager.default.fileExists(atPath: path + "/SKILL.md") {
                    skills.addCustomFolder(path)
                }
            }
        }
        // Deferred until here rather than posted inside `restoreHistory()`
        // itself, since there's no guaranteed conversation to attach it to
        // until after the empty-history fallback above has run.
        if let corruptionNotice {
            postNotice(corruptionNotice, to: activeConversation)
        }
        speechSynthesizer.delegate = speechDelegate
        speechDelegate.onFinish = { [weak self] in
            Task { @MainActor in self?.speakingMessageID = nil }
        }
        // History saves are debounced (see `saveHistory`) — quitting inside
        // the debounce window must not lose the last write.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushHistoryNow()
                self?.mcp.stopAll()
            }
        }
    }

    /// Starts (or stops, if already speaking this message) reading a
    /// message aloud via macOS's built-in speech synthesis — no extra API.
    func toggleReadAloud(_ message: ChatMessage) {
        if speakingMessageID == message.id {
            speechSynthesizer.stopSpeaking(at: .immediate)
            speakingMessageID = nil
            return
        }
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(AVSpeechUtterance(string: message.content))
        speakingMessageID = message.id
    }

    var activeConversation: Conversation? {
        guard let activeConversationID else { return nil }
        if let listed = conversations.first(where: { $0.id == activeConversationID }) { return listed }
        // A brand-new chat lives here until its first message — it has a
        // composer and a welcome screen but no sidebar row yet.
        if let pendingConversation, pendingConversation.id == activeConversationID { return pendingConversation }
        return nil
    }

    var isGenerating: Bool { activeConversation?.isGenerating ?? false }
    /// Unlike `isGenerating` (the active conversation only), this covers any
    /// conversation generating in the background — what the menu-bar icon's
    /// pulse reflects, since closing the window to free up screen space
    /// shouldn't mean losing track of an in-flight reply.
    var isAnyGenerating: Bool { conversations.contains { $0.isGenerating } }
    var generationProviderName: String { activeConversation?.generationProviderName ?? "" }

    var selectedProvider: ProviderProfile? { providers.selected }

    /// The exact model for the active thread wins. The provider profile is
    /// the remembered last-used model for new threads.
    var currentModelID: String {
        guard let provider = selectedProvider else { return "" }
        if let conversation = activeConversation,
           conversation.providerID == provider.id,
           !conversation.model.isEmpty {
            return conversation.model
        }
        return provider.model
    }

    var selectedModel: String {
        guard let provider = selectedProvider else { return "Automatic model" }
        if currentModelID.isEmpty, providers.isDiscovering(id: provider.id) { return "Finding a model…" }
        return currentModelID.isEmpty ? "Provider default" : currentModelID
    }

    var selectedModelInfo: RemoteModel? {
        guard let provider = selectedProvider else { return nil }
        return providers.modelInfo(for: provider.id, model: currentModelID)
    }

    var availableThinkingLevels: [ThinkingLevel] {
        guard let provider = selectedProvider else { return [.auto] }
        return providers.thinkingLevels(for: provider.id, model: currentModelID)
    }

    var contextTokenEstimate: Int {
        activeConversation.map(tokenEstimate) ?? 0
    }

    /// Counts only what would actually be sent on the next request — after
    /// a compaction, that's the summary plus whatever came after it, not the
    /// full raw transcript (which never shrinks, since nothing is deleted).
    /// Without this, the context readout — and the auto-compact trigger
    /// below, which reads the same number — would stay pinned near "full"
    /// forever after compacting, since the visible transcript itself never
    /// gets smaller.
    func tokenEstimate(for conversation: Conversation) -> Int {
        let messages: [ChatMessage]
        if let boundary = conversation.lastCompactionIndex {
            messages = Array(conversation.messages[boundary...])
        } else {
            messages = conversation.messages
        }
        return messages.reduce(0) { partial, message in
            // Notices and other local-only cards are never sent, so they
            // must not inflate the readout or trip auto-compaction early.
            // The compaction-summary system message IS sent, and stays
            // counted because it is not synthetic.
            guard !message.isSynthetic else { return partial }
            let attachmentTokens = message.attachments.filter(\.isIncluded).reduce(0) { $0 + $1.estimatedTokens }
            return partial + max(1, message.content.utf8.count / 4) + attachmentTokens
        }
    }

    /// A manual correction always wins over what the catalog reported —
    /// covers both "the catalog didn't publish one at all" and "the catalog
    /// published a wrong one for this deployment."
    var contextWindow: Int? {
        if let provider = selectedProvider,
           let override = providers.contextWindowOverride(providerID: provider.id, model: currentModelID) {
            return override
        }
        return selectedModelInfo?.contextLength
    }

    func contextWindow(for conversation: Conversation) -> Int? {
        guard let providerID = conversation.providerID else { return nil }
        if let override = providers.contextWindowOverride(providerID: providerID, model: conversation.model) {
            return override
        }
        return providers.modelInfo(for: providerID, model: conversation.model)?.contextLength
    }

    var contextWindowIsOverridden: Bool {
        guard let provider = selectedProvider else { return false }
        return providers.contextWindowOverride(providerID: provider.id, model: currentModelID) != nil
    }

    func setContextWindowOverride(_ value: Int?) {
        guard let provider = selectedProvider else { return }
        providers.setContextWindowOverride(value, providerID: provider.id, model: currentModelID)
    }

    var contextTooltip: String {
        let used = formattedTokenCount(contextTokenEstimate)
        guard let contextWindow else {
            return "Context: approximately \(used) tokens in this conversation"
        }
        return "Context: approximately \(used) of \(formattedTokenCount(contextWindow)) tokens"
    }

    func formattedTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    var thinkingIsModelAware: Bool {
        selectedModelInfo != nil
    }

    func setThinkingLevel(_ level: ThinkingLevel) {
        thinkingLevel = availableThinkingLevels.contains(level) ? level : .auto
    }

    func selectProvider(_ profile: ProviderProfile) {
        providers.select(profile.id)
        if let conversation = activeConversation {
            if conversation.providerID != profile.id {
                conversation.providerID = profile.id
                conversation.model = profile.model
            } else if conversation.model.isEmpty, !profile.model.isEmpty {
                conversation.model = profile.model
            }
        }
        if !availableThinkingLevels.contains(thinkingLevel) {
            thinkingLevel = .auto
        }
    }

    func selectModel(_ model: RemoteModel) {
        guard let provider = selectedProvider else { return }
        providers.update(id: provider.id, model: model.id)
        activeConversation?.model = model.id
        if !availableThinkingLevels.contains(thinkingLevel) {
            thinkingLevel = .auto
        }
    }

    /// Used by the model picker when the chosen model belongs to a
    /// different provider than the one currently selected — switches both
    /// together in one action instead of forcing two separate pickers.
    func selectProviderAndModel(_ profile: ProviderProfile, model: RemoteModel) {
        if profile.id != selectedProvider?.id {
            selectProvider(profile)
        }
        providers.update(id: profile.id, model: model.id)
        providers.noteRecent(providerID: profile.id, modelID: model.id)
        activeConversation?.model = model.id
        if !availableThinkingLevels.contains(thinkingLevel) {
            thinkingLevel = .auto
        }
        // Switching providers is a strong signal the next message goes to
        // this one — open its connection while the picker is still closing.
        warmConnection()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        startNetworkMonitor()
        if providers.chatGPTSessionPresent {
            Task { await ChatGPTWebClient.shared.startKeepAlive() }
        }
        prewarmForFasterFirstToken()
        if let active = activeConversation, let providerID = active.providerID {
            providers.select(providerID, markExplicit: false)
        }
        // Clear out empty conversations accumulated by earlier builds that
        // never pruned them.
        pruneUnusedConversations()
        providers.start()
        // Silent if denied — background-reply notifications are a courtesy
        // once the app can actually stay alive with the window closed
        // (see `applicationShouldTerminateAfterLastWindowClosed`), never a
        // requirement. UNUserNotificationCenter itself throws an
        // NSInternalInconsistencyException ("bundleProxyForCurrentProcess is
        // nil") when the running process isn't backed by a real .app bundle
        // registered with LaunchServices — true for `swift run`, which
        // executes the raw binary straight out of `.build/`. Gate on that so
        // `just run`/`swift run` keep working during iteration; `just app`/
        // `just smoke` build a real bundle and get real notifications.
        if AppModel.isRunningAsBundledApp {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// See the comment in `start()` — UNUserNotificationCenter aborts the
    /// process outright if there's no real `.app` bundle behind it.
    static let isRunningAsBundledApp = Bundle.main.bundleURL.pathExtension == "app"

    /// Reuses an existing empty conversation instead of creating another one
    /// — without this, clicking "New" repeatedly permanently littered the
    /// sidebar with empty threads, since nothing ever pruned them.
    @discardableResult
    func newConversation() -> Conversation {
        // Reuse only a PRISTINE current pending chat — reusing anything
        // with a typed draft used to silently drop the user into their
        // own unsent draft when they asked for a new chat.
        if let pending = pendingConversation, isPristine(pending) {
            activeConversationID = pending.id
            return pending
        }
        let provider = providers.selected
        let conversation = Conversation(providerID: provider?.id, model: provider?.model ?? "")
        // A draft-carrying pending chat survives by joining the list;
        // an untouched one is simply replaced.
        if let pending = pendingConversation, !isPristine(pending) {
            promotePending()
        }
        pendingConversation = conversation
        activeConversationID = conversation.id
        return conversation
    }

    private func isPristine(_ conversation: Conversation) -> Bool {
        conversation.realMessages.isEmpty
            && !conversation.isPinned
            && !conversation.titleIsCustom
            && conversation.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && conversation.draftAttachments.isEmpty
            && conversation.messages.isEmpty
    }

    /// Moves the pending chat into the sidebar list — the row springs in.
    @discardableResult
    private func promotePending() -> Conversation? {
        guard let pending = pendingConversation else { return nil }
        pendingConversation = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            conversations.insert(pending, at: 0)
        }
        saveHistory()
        return pending
    }

    /// Promotes before anything is appended to a conversation that isn't
    /// listed yet — first message, first notice, first anything.
    private func ensureListed(_ conversation: Conversation) {
        guard pendingConversation?.id == conversation.id else { return }
        _ = promotePending()
    }

    /// Surfaces an error (or any system notice) as a card inline in the
    /// transcript instead of a banner above the composer, so every error —
    /// including ones with no real message to attach to, like "choose a
    /// provider first" — always shows up in the same place: the
    /// conversation itself. `role: "notice"` is a pure local UI artifact:
    /// never sent to a provider (`send` filters it out of the request), and
    /// excluded from anything that asks "has this conversation actually
    /// been used" (`Conversation.realMessages`).
    @discardableResult
    func postNotice(_ message: String, kind: String = "warning", to conversation: Conversation? = nil) -> ChatMessage {
        let target = conversation ?? activeConversation ?? newConversation()
        ensureListed(target)
        var notice = ChatMessage(role: "notice", content: message)
        notice.noticeKind = kind
        target.messages.append(notice)
        target.updatedAt = Date()
        saveHistory()
        return notice
    }

    // MARK: - GitHub (gh CLI) repo attach

    /// Found gh binary path, checked once per launch. nil = not installed.
    private var cachedGHPath: String??

    private func ghPath() -> String? {
        if let cached = cachedGHPath { return cached }
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        cachedGHPath = .some(found)
        return found
    }

    static func runProcess(_ launchPath: String, _ arguments: [String]) async -> (status: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: (process.terminationStatus, stdout, stderr))
                } catch {
                    continuation.resume(returning: (127, "", error.localizedDescription))
                }
            }
        }
    }

    /// nil = gh missing or not logged in; otherwise "owner/name" list.
    func fetchGitHubRepos() async -> [String]? {
        guard let gh = ghPath() else { return nil }
        let auth = await Self.runProcess(gh, ["auth", "status"])
        guard auth.status == 0 else { return nil }
        let list = await Self.runProcess(gh, ["repo", "list", "--limit", "30", "--json", "nameWithOwner"])
        guard list.status == 0, let data = list.stdout.data(using: .utf8),
              let entries = try? JSONDecoder().decode([[String: String]].self, from: data) else { return [] }
        return entries.compactMap { $0["nameWithOwner"] }
    }

    /// Shallow-clones a repo into the conversation's private workspace so
    /// the read_file/list tools can browse it, then attaches the same git
    /// summary a dragged-in repo folder gets. Size-guarded.
    func cloneGitHubRepo(_ nameWithOwner: String) {
        guard let gh = ghPath() else {
            postNotice("The gh CLI isn't installed.")
            return
        }
        let conversation = activeConversation ?? newConversation()
        ensureListed(conversation)
        let repoName = nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner
        let destination = SandboxManager.directory(for: conversation.id).appendingPathComponent(repoName, isDirectory: true)
        statusMessage = "Cloning \(nameWithOwner)…"
        Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.statusMessage = nil } }
            let result = await Self.runProcess(gh, ["repo", "clone", nameWithOwner, destination.path, "--", "--depth", "1"])
            guard let self else { return }
            guard result.status == 0 else {
                self.postNotice("Couldn't clone \(nameWithOwner): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
                return
            }
            // ~200MB guard — a huge clone would silently eat the disk.
            let size = (try? FileManager.default.allocatedSizeOfDirectory(at: destination)) ?? 0
            if size > 200_000_000 {
                try? FileManager.default.removeItem(at: destination)
                self.postNotice("\(nameWithOwner) is larger than 200 MB — clone removed. Attach a specific folder instead.")
                return
            }
            if let attachment = Attachment.fromGitFolder(url: destination) {
                conversation.draftAttachments.append(attachment)
            }
            self.postNotice("Cloned \(nameWithOwner) into this chat's workspace — the model can browse it with its file tools.", kind: "success", to: conversation)
        }
    }

    /// Wipes everything: chats, memories, snippets, settings, API keys,
    /// workspace files, logo cache, hotkey — then returns to onboarding.
    /// Order matters: in-memory state resets BEFORE the defaults purge,
    /// because property didSets re-write their keys.
    func performFullReset() {
        for conversation in conversations where conversation.isGenerating {
            stopGeneration(for: conversation)
        }
        providers.performFullReset()
        // App Support: workspaces + fetched logos.
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("VelaChat", isDirectory: true))
        }
        KeyboardShortcuts.reset(.summonVelaChat)
        conversations.removeAll()
        pendingConversation = nil
        usageByMessage.removeAll()
        searchByMessage.removeAll()
        memories.removeAll()
        promptSnippets.removeAll()
        customInstructions = ""
        searchEndpoint = ""
        isWebSearchEnabled = false
        isWorkspaceEnabled = true
        isConversationSearchEnabled = true
        isAutoTitleEnabled = true
        isHoverTimestampsEnabled = true
        thinkingLevel = .auto
        messageWidth = .comfortable
        density = .comfortable
        accentPreset = .teal
        // Purge every app default LAST — the resets above just re-wrote
        // some keys via didSet; this sweep removes them all for real.
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(DefaultsKey.prefix) {
            defaults.removeObject(forKey: key)
        }
        section = .chat
        _ = newConversation()
        hasOnboarded = false
    }

    /// The sidebar never fully collapses any more — it narrows to an icon
    /// rail. Besides being easier to get back from, this keeps
    /// `NavigationSplitView`'s column alive: a real collapse made it
    /// re-install its toolbar, which left a blurred band across the
    /// titlebar that survived until relaunch.
    func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.24)) {
            isSidebarRail.toggle()
            sidebarVisibility = .all
        }
    }

    func selectConversation(_ conversation: Conversation) {
        // Leaving a pending chat: a typed draft earns it a row (drafts
        // survive), an untouched one just evaporates.
        if let pending = pendingConversation, pending.id != conversation.id {
            if isPristine(pending) {
                pendingConversation = nil
            } else {
                promotePending()
            }
        }
        activeConversationID = conversation.id
        if let providerID = conversation.providerID {
            providers.select(providerID)
        }
        if !availableThinkingLevels.contains(thinkingLevel) {
            thinkingLevel = .auto
        }
        section = .chat
        pruneUnusedConversations()
    }

    /// An empty "New conversation" left behind after clicking away is pure
    /// sidebar clutter — `newConversation()` would reuse it anyway, so
    /// nothing is lost by dropping it. Keeps anything pinned, renamed,
    /// drafted, or currently active.
    private func pruneUnusedConversations() {
        // Never prune from underneath the Settings screen — the chat the
        // user was just looking at must still exist when they come back.
        guard section != .settings else { return }
        let before = conversations.count
        withAnimation(.easeOut(duration: 0.18)) {
            conversations.removeAll { conversation in
                conversation.id != activeConversationID
                    && !conversation.isPinned
                    && !conversation.titleIsCustom
                    // `messages`, not `realMessages`: a notice-only chat
                    // still holds an error the user may want to read.
                    && conversation.messages.isEmpty
                    && conversation.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && conversation.draftAttachments.isEmpty
            }
        }
        if conversations.count != before { saveHistory() }
    }

    /// Forks a conversation at (and including) the given message into a
    /// new chat — notices dropped, compaction markers kept so the branch's
    /// request history stays coherent, every message re-id'd.
    func branchConversation(from message: ChatMessage, in conversation: Conversation) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }
        var copied = conversation.messages[...index]
            .filter { $0.role != "notice" }
            .map { $0.duplicatedWithFreshID() }
        guard !copied.isEmpty else { return }
        // Branching mid-generation must not clone live streaming state —
        // the copy would shimmer forever with no task behind it.
        for i in copied.indices {
            copied[i].isStreaming = false
            copied[i].reconcileRunningActivities()
        }
        let title = "(branch) " + conversation.title
        let branch = Conversation(
            title: String(title.prefix(60)),
            messages: copied,
            providerID: conversation.providerID,
            model: conversation.model
        )
        pendingConversation = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            conversations.insert(branch, at: 0)
        }
        activeConversationID = branch.id
        section = .chat
        saveHistory()
    }

    func renameConversation(_ conversation: Conversation, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversation.title = trimmed
        conversation.titleIsCustom = true
        saveHistory()
    }

    /// Manual "regenerate title" action (sidebar row context menu) — reuses
    /// the same model call as the automatic titler, but bypasses both the
    /// "already custom" and "exactly two messages" guards, since an explicit
    /// user request should always run regardless of how the title got there.
    func regenerateTitle(for conversation: Conversation) {
        guard let profile = providers.selected else {
            postNotice("Choose a provider first.", to: conversation)
            return
        }
        guard conversation.messages.contains(where: { $0.role == "user" }),
              conversation.messages.contains(where: { $0.role == "assistant" }) else { return }
        let model = conversation.model.isEmpty ? providers.effectiveModel(for: profile) : conversation.model
        let credential = providers.credential(for: profile)
        generateTitleIfNeeded(for: conversation, profile: profile, model: model, credential: credential, force: true)
    }

    /// Fires once, right after the very first exchange completes, using
    /// whatever model/provider the conversation is already on — no separate
    /// "titling model" configuration. Silent on failure for the automatic
    /// (post-first-exchange) path — a truncated first message is a
    /// perfectly fine fallback title, never worth interrupting the user
    /// over. `force` (the manual "Regenerate Title" action) is a real user
    /// click, though, so it gets a real notice on failure instead of
    /// silently doing nothing — see the shared `catch` below. Every
    /// failure is also logged (visible in Console.app/stderr), so a
    /// pattern of silent automatic failures is at least diagnosable
    /// instead of invisible.
    /// The at-send fast path: names the chat from the opening message
    /// alone, in parallel with the reply. The post-reply refinement
    /// (`generateTitleIfNeeded`) still runs and may improve it.
    private func generateInstantTitle(for conversation: Conversation, userText: String, profile: ProviderProfile) {
        let model = conversation.model.isEmpty ? providers.effectiveModel(for: profile) : conversation.model
        let credential = providers.credential(for: profile)
        let prompt = """
        Give this new chat a short title from the user's opening message. 3-6 words, no quotes, no trailing punctuation, no markdown.

        User: \(userText.prefix(500))
        """
        Task { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            var titleText = ""
            do {
                if self.canUseAppleIntelligence {
                    // On-device: instant, free, and never burns provider quota.
                    titleText = try await AppleIntelligence.complete(prompt: prompt)
                } else if profile.kind != .appleIntelligence {
                    let events = CompatibleChatClient.shared.streamChatEvents(
                        profile: profile,
                        credential: credential,
                        model: model,
                        thinking: .auto,
                        messages: [ChatMessage(role: "user", content: prompt)]
                    )
                    for try await event in events {
                        if case .delta(let content, _) = event { titleText += content }
                    }
                } else {
                    return
                }
            } catch {
                print("[VelaChat] Instant title failed: \(error)")
                return
            }
            guard !conversation.titleIsCustom else { return }
            let cleaned = titleText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
            guard !cleaned.isEmpty, !Self.looksLikeBadTitle(cleaned) else { return }
            conversation.title = String(cleaned.prefix(60))
            conversation.titleIsCustom = false
            self.saveHistory()
        }
    }

    private func generateTitleIfNeeded(for conversation: Conversation, profile: ProviderProfile, model: String, credential: ProviderCredential, force: Bool = false) {
        // `force` bypasses both the "already custom" and "exactly two
        // messages" gates — an explicit user request should always run.
        // `titleIsCustom` itself is only ever flipped back to `false` on
        // actual success, below, not pre-emptively here — clearing it
        // before the network call could resolve used to mean a failed
        // regenerate silently and permanently forgot the user's manual
        // title even though nothing else changed.
        guard force || (isAutoTitleEnabled && !conversation.titleIsCustom && conversation.realMessages.count == 2),
              true else { return }
        guard let firstUser = conversation.messages.first(where: { $0.role == "user" }),
              let firstAssistant = conversation.messages.first(where: { $0.role == "assistant" }),
              !firstAssistant.content.isEmpty else { return }

        let prompt = """
        Summarize this exchange as a short chat title. 3-6 words, no quotes, no trailing punctuation, no markdown.

        User: \(firstUser.content.prefix(500))
        Assistant: \(firstAssistant.content.prefix(500))
        """

        Task { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            var titleText = ""
            do {
                if self.canUseAppleIntelligence {
                    titleText = try await AppleIntelligence.complete(prompt: prompt)
                } else if profile.kind == .appleIntelligence {
                    return
                } else {
                    let events = CompatibleChatClient.shared.streamChatEvents(
                        profile: profile,
                        credential: credential,
                        model: model,
                        thinking: .auto,
                        messages: [ChatMessage(role: "user", content: prompt)]
                    )
                    for try await event in events {
                        if case .delta(let content, _) = event { titleText += content }
                    }
                }
            } catch {
                print("[VelaChat] Title generation failed for \"\(conversation.title)\": \(error)")
                if force { self.postNotice("Couldn't generate a title: \(error.localizedDescription)", to: conversation) }
                return
            }
            guard !conversation.titleIsCustom || force else { return }
            let cleaned = titleText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
            guard !cleaned.isEmpty, !Self.looksLikeBadTitle(cleaned) else {
                if force { self.postNotice("The model didn't return a usable title.", to: conversation) }
                return
            }
            conversation.title = String(cleaned.prefix(60))
            conversation.titleIsCustom = false
            self.saveHistory()
        }
    }

    /// A model occasionally answers the "give me a title" prompt with a
    /// stray code fragment or a SHOUTED restatement instead of a real title.
    /// Reject those and keep whatever title (usually the truncated first
    /// message) was already showing rather than replace it with something
    /// worse.
    private static func looksLikeBadTitle(_ text: String) -> Bool {
        let codeMarkers: Set<Character> = ["{", "}", ";", "`", "<", ">", "=", "(", ")"]
        if text.contains(where: { codeMarkers.contains($0) }) { return true }
        let letters = text.filter { $0.isLetter }
        if letters.count > 2, letters == letters.uppercased(), letters != letters.lowercased() {
            return true
        }
        return false
    }

    func activateSkill(_ skill: Skill, for conversation: Conversation) {
        guard !conversation.activeSkillPaths.contains(skill.folderPath) else { return }
        conversation.activeSkillPaths.append(skill.folderPath)
        saveHistory()
    }

    func deactivateSkill(_ skill: Skill, for conversation: Conversation) {
        conversation.activeSkillPaths.removeAll { $0 == skill.folderPath }
        saveHistory()
    }

    func addSnippet(name: String, body: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedBody.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            promptSnippets.append(PromptSnippet(name: trimmedName, body: trimmedBody))
        }
    }

    func removeSnippet(_ snippet: PromptSnippet) {
        withAnimation(.easeOut(duration: 0.18)) {
            promptSnippets.removeAll { $0.id == snippet.id }
        }
    }

    func addMemory(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            memories.append(MemoryItem(content: trimmed))
        }
    }

    func updateMemory(_ memory: MemoryItem, content: String) {
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        memories[index].content = trimmed
    }

    func removeMemory(_ memory: MemoryItem) {
        withAnimation(.easeOut(duration: 0.18)) {
            memories.removeAll { $0.id == memory.id }
        }
    }

    /// Relevance-ranked injection: with a short list everything goes in
    /// (grouped by topic); past 15 memories, only the ones that share real
    /// words with the recent conversation do, with topic matches weighted
    /// double — and a note that `search_memory` can find the rest. Plain
    /// word overlap on purpose: no embeddings infrastructure exists here,
    /// and honest keyword scoring beats pretending otherwise.
    private static let memoryStopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "your", "have",
        "are", "was", "but", "not", "can", "what", "how", "about", "just",
        "like", "its", "it's", "from", "they", "them", "when", "where"
    ]

    private func relevantMemoryText(for conversation: Conversation) -> String {
        let selection: [MemoryItem]
        var omitted = 0
        if memories.count <= 15 {
            selection = memories
        } else {
            let recentText = conversation.realMessages.suffix(5).map(\.content).joined(separator: " ").lowercased()
            let contextWords = Set(
                recentText.split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
                    .filter { $0.count > 2 && !Self.memoryStopwords.contains($0) }
            )
            func score(_ memory: MemoryItem) -> Int {
                let contentWords = memory.content.lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
                var value = contentWords.filter { contextWords.contains($0) }.count
                if let topic = memory.topic?.lowercased() {
                    let topicWords = topic.split { !$0.isLetter && !$0.isNumber }.map(String.init)
                    value += 2 * topicWords.filter { contextWords.contains($0) }.count
                }
                return value
            }
            let ranked = memories
                .map { (memory: $0, score: score($0)) }
                .sorted { ($0.score, $0.memory.createdAt.timeIntervalSince1970) > ($1.score, $1.memory.createdAt.timeIntervalSince1970) }
            let matched = ranked.filter { $0.score > 0 }.prefix(12).map(\.memory)
            // Nothing matched (fresh conversation): fall back to recency.
            selection = matched.isEmpty
                ? Array(memories.sorted { $0.createdAt > $1.createdAt }.prefix(12))
                : matched
            omitted = memories.count - selection.count
        }
        var topics: [String] = []
        var grouped: [String: [MemoryItem]] = [:]
        for memory in selection {
            let topic = memory.displayTopic
            if grouped[topic] == nil { topics.append(topic) }
            grouped[topic, default: []].append(memory)
        }
        var lines: [String] = []
        for topic in topics {
            lines.append("\(topic):")
            for memory in grouped[topic] ?? [] {
                lines.append("- \(memory.content)")
            }
        }
        if omitted > 0 {
            lines.append("(\(omitted) more stored memor\(omitted == 1 ? "y" : "ies") — use search_memory to find them.)")
        }
        return lines.joined(separator: "\n")
    }

    /// The memory tools' MainActor entry point — every mutation lands in
    /// `memories`, whose `didSet` persists it, and Settings reflects it
    /// immediately.
    func applyMemoryMutation(_ mutation: ToolCatalog.MemoryMutation) -> String {
        switch mutation {
        case .save(let content, let topic):
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Error: the memory content is empty." }
            let cleanTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
            memories.append(MemoryItem(content: trimmed, topic: (cleanTopic?.isEmpty ?? true) ? nil : cleanTopic))
            return "Saved."
        case .update(let id, let content, let topic):
            guard let index = memories.firstIndex(where: { $0.id == id }) else {
                return "Error: no memory with that id — use search_memory to find the right one."
            }
            if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                memories[index].content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let topic {
                let cleaned = topic.trimmingCharacters(in: .whitespacesAndNewlines)
                memories[index].topic = cleaned.isEmpty ? nil : cleaned
            }
            return "Updated."
        case .delete(let id):
            guard memories.contains(where: { $0.id == id }) else {
                return "Error: no memory with that id — use search_memory to find the right one."
            }
            memories.removeAll { $0.id == id }
            return "Deleted."
        }
    }

    func togglePin(_ conversation: Conversation) {
        withAnimation(.easeOut(duration: 0.18)) {
            conversation.isPinned.toggle()
        }
        saveHistory()
    }

    /// Attachment bytes live on disk (see `AttachmentStore`); this drops
    /// the files no surviving message refers to any more. Run after
    /// deletions rather than on a timer, so an orphan can outlive its
    /// message by at most one destructive operation.
    private func pruneAttachmentBlobs() {
        let live = Set(conversations.flatMap { $0.messages.flatMap { $0.attachments.map(\.id) } })
        AttachmentStore.pruneOrphans(keeping: live)
    }

    /// Everything keyed by message ID that isn't part of the message
    /// itself. These accumulated silently: each new feature added another
    /// dictionary, and only the two oldest were ever cleaned up, so
    /// deleting conversations leaked entries for the rest of the session.
    private func discardTransientState(for messages: [ChatMessage]) {
        let ids = Set(messages.map(\.id))
        usageByMessage = usageByMessage.filter { !ids.contains($0.key) }
        searchByMessage = searchByMessage.filter { !ids.contains($0.key) }
        planByMessage = planByMessage.filter { !ids.contains($0.key) }
        finishReasonByMessage = finishReasonByMessage.filter { !ids.contains($0.key) }
        for id in ids {
            revealTasks[id]?.cancel()
            revealTasks[id] = nil
            revealQueues[id] = nil
            pendingFinish.remove(id)
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        if conversation.isGenerating {
            stopGeneration(for: conversation)
        }
        discardTransientState(for: conversation.messages)
        withAnimation(.easeOut(duration: 0.18)) {
            conversations.removeAll { $0.id == conversation.id }
        }
        SandboxManager.cleanup(for: conversation.id)
        pruneAttachmentBlobs()
        Task { await ChatGPTWebChat.shared.forgetContinuation(for: conversation.id) }
        if activeConversationID == conversation.id {
            activeConversationID = conversations.first?.id ?? newConversation().id
        }
        flushHistoryNow()
    }

    func clearHistory() {
        for conversation in conversations where conversation.isGenerating {
            stopGeneration(for: conversation)
        }
        for conversation in conversations {
            SandboxManager.cleanup(for: conversation.id)
            let id = conversation.id
            Task { await ChatGPTWebChat.shared.forgetContinuation(for: id) }
        }
        conversations.removeAll()
        pendingConversation = nil
        usageByMessage.removeAll()
        searchByMessage.removeAll()
        planByMessage.removeAll()
        finishReasonByMessage.removeAll()
        for (_, task) in revealTasks { task.cancel() }
        revealTasks.removeAll()
        revealQueues.removeAll()
        pendingFinish.removeAll()
        _ = newConversation()
        pruneAttachmentBlobs()
        flushHistoryNow()
    }

    func send(_ rawText: String) {
        send(rawText, replacingReplyWith: nil, attachments: activeConversation?.draftAttachments ?? [])
    }

    /// Quick-composer send: its text field is its own, so a send from the
    /// menu bar consumes the shared draft attachments but must NOT wipe
    /// whatever the user has half-typed in the main window's composer.
    func sendPreservingDraftText(_ rawText: String) {
        send(rawText, replacingReplyWith: nil, attachments: activeConversation?.draftAttachments ?? [], clearDraftText: false)
    }

    /// Edits a past user message in place: removes it and everything after
    /// it (mirroring `retryLastMessage`), then resends the edited text. The
    /// reply that answered the original text is preserved as an alternate
    /// on the new reply rather than being discarded.
    /// Toggles a bookmark on a single message within the active conversation
    /// — distinct from `togglePin`, which pins the whole conversation in the
    /// sidebar.
    func toggleMessagePin(_ message: ChatMessage) {
        guard let conversation = activeConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }
        conversation.messages[index].isPinned.toggle()
        saveHistory()
    }

    /// Removes a single message (and, if it's a user message, its reply)
    /// from the active conversation — distinct from `deleteConversation`,
    /// which removes the whole thread.
    func deleteMessage(_ message: ChatMessage) {
        guard let conversation = activeConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }
        guard !conversation.isGenerating else {
            postNotice("Already generating a reply.", to: conversation)
            return
        }
        var removed = [conversation.messages[index]]
        if message.role == "user",
           index + 1 < conversation.messages.count,
           conversation.messages[index + 1].role == "assistant" {
            removed.append(conversation.messages[index + 1])
            conversation.messages.remove(at: index + 1)
        }
        conversation.messages.remove(at: index)
        discardTransientState(for: removed)
        pruneAttachmentBlobs()
        saveHistory()
    }

    func editMessage(_ message: ChatMessage, newContent: String) {
        guard message.role == "user" else { return }
        guard let conversation = activeConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }
        guard !conversation.isGenerating else {
            postNotice("Already generating a reply.", to: conversation)
            return
        }
        let nextIndex = index + 1
        let priorReply: ChatMessage? = nextIndex < conversation.messages.count && conversation.messages[nextIndex].role == "assistant"
            ? conversation.messages[nextIndex]
            : nil
        let snapshot = conversation.messages
        conversation.messages.removeSubrange(index...)
        send(newContent, replacingReplyWith: priorReply, restoring: (conversation, snapshot))
    }

    /// Regenerates a specific assistant reply — works on any reply, not just
    /// the last one, unlike `retryLastMessage`. The reply being replaced is
    /// kept as a viewable alternate, same as an edited-message regeneration.
    func regenerate(_ message: ChatMessage) {
        guard message.role == "assistant" else { return }
        guard let conversation = activeConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }
        guard !conversation.isGenerating else {
            postNotice("Already generating a reply.", to: conversation)
            return
        }
        guard index > 0, conversation.messages[index - 1].role == "user" else { return }
        let priorUser = conversation.messages[index - 1]
        let priorReply = conversation.messages[index]
        let snapshot = conversation.messages
        conversation.messages.removeSubrange((index - 1)...)
        send(priorUser.content, replacingReplyWith: priorReply, restoring: (conversation, snapshot))
    }

    /// Resumes a reply that stopped early — whether you hit Stop, or the
    /// provider itself just ran out of output tokens mid-thought. A new,
    /// visible short user turn asks for the rest, same shape every major
    /// chat app's own "Continue" action uses, rather than trying to splice
    /// more text onto the truncated message in place.
    func continueGenerating(_ message: ChatMessage) {
        guard message.role == "assistant", !message.content.isEmpty, !message.isStreaming else { return }
        send("Continue exactly where you left off — no repetition, no preamble.")
    }

    private func send(_ rawText: String, replacingReplyWith priorReply: ChatMessage?, attachments: [Attachment] = [], restoring: (conversation: Conversation, messages: [ChatMessage])? = nil, clearDraftText: Bool = true) {
        // Edit/regenerate/retry remove messages before calling here, so every
        // early bail must put them back — otherwise a missing provider or a
        // failed discovery silently destroys the user's messages.
        func restoreOnBail() {
            guard let restoring else { return }
            restoring.conversation.messages = restoring.messages
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else {
            restoreOnBail()
            return
        }
        guard let profile = providers.selected else {
            restoreOnBail()
            postNotice("Choose a provider in Settings first.")
            section = .settings
            return
        }
        if !providers.hasDiscoveredModels(for: profile.id) {
            guard !pendingDiscoverySends.contains(profile.id) else {
                restoreOnBail()
                return
            }
            pendingDiscoverySends.insert(profile.id)
            statusMessage = "Finding a model…"
            Task { [weak self] in
                guard let self else { return }
                defer { self.pendingDiscoverySends.remove(profile.id) }
                _ = await self.providers.ensureReady(id: profile.id)
                if case .failed(let message) = self.providers.status(for: profile.id) {
                    self.statusMessage = nil
                    restoreOnBail()
                    self.postNotice(message)
                    return
                }
                self.statusMessage = nil
                self.send(text, replacingReplyWith: priorReply, attachments: attachments, restoring: restoring)
            }
            return
        }
        let conversation = activeConversation ?? newConversation()
        guard !conversation.isGenerating else {
            restoreOnBail()
            postNotice("Already generating a reply.", to: conversation)
            return
        }
        // First real use: the chat earns its sidebar row now, springing in.
        ensureListed(conversation)
        if conversation.providerID != profile.id {
            conversation.providerID = profile.id
            conversation.model = profile.model
        }
        if conversation.model.isEmpty {
            conversation.model = providers.effectiveModel(for: profile)
        }
        let isFirstMessage = conversation.realMessages.isEmpty
        if isFirstMessage, !conversation.titleIsCustom {
            let titleSource = text.isEmpty ? (attachments.first?.filename ?? text) : text
            conversation.title = titleSource.count > 54 ? String(titleSource.prefix(54)) + "…" : titleSource
            // A real title starts generating NOW, in parallel with the
            // reply, from the user's message alone — it typically lands in
            // the sidebar while the reply is still streaming.
            if isAutoTitleEnabled, !text.isEmpty {
                generateInstantTitle(for: conversation, userText: text, profile: profile)
            }
        }
        conversation.messages.append(ChatMessage(role: "user", content: text, attachments: attachments))
        conversation.updatedAt = Date()
        // Stamped now, not read live off `selectedProvider` when displayed —
        // otherwise switching providers mid-conversation retroactively
        // relabeled every earlier reply with whatever's newly selected.
        var assistant = ChatMessage(role: "assistant", content: "", isStreaming: true, providerName: profile.name, modelID: conversation.model)
        if let priorReply {
            assistant.alternates = [priorReply] + priorReply.alternates
        }
        let assistantID = assistant.id
        conversation.messages.append(assistant)
        conversation.updatedAt = Date()
        conversation.isGenerating = true
        conversation.currentGenerationID = assistantID
        noteSendStarted(assistantID)
        if clearDraftText {
            conversation.draftText = ""
        }
        conversation.draftAttachments = []
        conversation.generationProviderName = profile.name
        saveHistory()

        var requestMessages = requestHistory(for: conversation)
        let model = conversation.model.isEmpty ? providers.effectiveModel(for: profile) : conversation.model
        let credential = providers.credential(for: profile)
        let thinking = availableThinkingLevels.contains(thinkingLevel) ? thinkingLevel : .auto
        let modelInfo = providers.modelInfo(for: profile.id, model: model)
        let trimmedSearchEndpoint = searchEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        // Providers that search natively (Perplexity, OpenRouter's `:online`)
        // do it inside the request itself — VelaChat's own SearXNG pass is
        // only the fallback for providers with no built-in search.
        let nativeSearch = isWebSearchEnabled ? profile.kind.nativeWebSearch : .none
        let usesNativeSearch = !isNativeSearchNone(nativeSearch)
        // Catalog entry when there is one, ID-based inference otherwise —
        // an uncataloged compatible endpoint or a manual model override used
        // to silently lose all tools because `modelInfo` came back nil.
        let modelSupportsTools = (modelInfo ?? RemoteModel(id: model)).supportsTools
            && profile.kind != .appleIntelligence  // on-device path has no tool loop
        var tools: [ToolCatalog.Definition] = []
        if modelSupportsTools {
            if isConversationSearchEnabled {
                tools.append(ToolCatalog.searchConversations)
            }
            if isWebSearchEnabled, !usesNativeSearch, !trimmedSearchEndpoint.isEmpty {
                tools.append(ToolCatalog.webSearch)
            }
            tools.append(ToolCatalog.fetchURL)
            // current_datetime is gone: the Environment section stamps the
            // live date/time on every request instead.
            tools.append(ToolCatalog.calculator)
            tools.append(contentsOf: [ToolCatalog.saveMemory, ToolCatalog.searchMemory, ToolCatalog.editMemory])
            if isScheduleToolEnabled {
                tools.append(ToolCatalog.getSchedule)
                tools.append(ToolCatalog.createScheduleItem)
            }
            if isClipboardToolEnabled { tools.append(ToolCatalog.readClipboard) }
            tools.append(ToolCatalog.systemStatus)
            if isWorkspaceEnabled {
                tools.append(contentsOf: [ToolCatalog.writeFile, ToolCatalog.readFile, ToolCatalog.listWorkspaceFiles])
                if isAgentToolsEnabled {
                    tools.append(contentsOf: [ToolCatalog.editFile, ToolCatalog.searchFiles])
                }
            }
            if isAgentToolsEnabled {
                tools.append(ToolCatalog.updatePlan)
            }
            if isCommandToolEnabled {
                tools.append(ToolCatalog.runCommand)
            }
            if isSubagentsEnabled {
                tools.append(Subagents.definition)
            }
        }
        var attachmentTexts: [String: String] = [:]
        for message in conversation.realMessages {
            for attachment in message.attachments {
                if let text = attachment.textContent, !text.isEmpty {
                    attachmentTexts[attachment.filename] = text
                }
            }
        }
        if modelSupportsTools, !attachmentTexts.isEmpty {
            tools.append(ToolCatalog.readAttachment)
        }
        // Only offered when the model can't see images itself — otherwise
        // OCR would be a strictly worse path than just looking.
        if modelSupportsTools,
           !(modelInfo?.supportsVision ?? false),
           conversation.realMessages.contains(where: { !$0.imageAttachments.isEmpty }) {
            tools.append(ToolCatalog.analyzeImage)
        }
        // System stack, top to bottom: the user's own instructions lead,
        // then durable memories and skills, then the app's tool inventory
        // and conventions — the user's words always outrank boilerplate.
        var systemMessages: [ChatMessage] = []
        let trimmedInstructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
            systemMessages.append(ChatMessage(role: "system", content: trimmedInstructions))
        }
        if !memories.isEmpty {
            systemMessages.append(ChatMessage(role: "system", content: "Remembered facts about the user, true across every conversation:\n\(relevantMemoryText(for: conversation))"))
        }
        // Active skills' bodies become extra scoped context for the rest of
        // this conversation — capped per skill and in total, since an
        // uncapped 30KB SKILL.md silently cost thousands of tokens on
        // every single message.
        var skillBudget = Limits.skillTotalBytes
        for path in conversation.activeSkillPaths {
            guard let skill = skills.skills.first(where: { $0.folderPath == path }) else { continue }
            guard skillBudget > 0 else { break }
            var body = skill.body
            if body.count > Limits.skillBodyBytes {
                body = String(body.prefix(Limits.skillBodyBytes)) + "\n\n[Truncated — the full skill file is on disk.]"
            }
            if body.count > skillBudget {
                body = String(body.prefix(skillBudget)) + "\n\n[Truncated.]"
            }
            skillBudget -= body.count
            systemMessages.append(ChatMessage(role: "system", content: "Skill \"\(skill.name)\":\n\n\(body)"))
        }
        // The tool-inventory system message is composed inside the
        // generation task, after the MCP merge, so MCP tools get the same
        // rich inventory treatment as the built-ins instead of a bolted-on
        // one-liner the model tended to ignore.
        requestMessages.insert(contentsOf: systemMessages, at: 0)
        let composeInsertIndex = systemMessages.count
        var toolContext = ToolCatalog.ExecutionContext(
            conversationSummaries: conversations
                .filter { $0.id != conversation.id }
                .map { conv in
                    ToolCatalog.ConversationSearchSummary(
                        title: conv.title,
                        updatedAt: conv.updatedAt,
                        messages: conv.realMessages.map { (role: $0.role, content: $0.content) }
                    )
                },
            searchEndpoint: trimmedSearchEndpoint,
            workspaceDirectory: conversation.workspaceRoot
        )
        toolContext.attachmentTexts = attachmentTexts
        toolContext.memory = ToolCatalog.MemoryAccess(
            snapshot: memories.map { ToolCatalog.MemorySnapshot(id: $0.id, content: $0.content, topic: $0.topic) },
            mutate: { [weak self] mutation in
                await MainActor.run { [weak self] in
                    self?.applyMemoryMutation(mutation) ?? "Error: memory is unavailable."
                }
            }
        )
        if isScheduleToolEnabled {
            toolContext.schedule = { days in
                await ScheduleReader.schedule(days: days)
            }
            toolContext.createScheduleItem = { kind, title, start, duration, notes in
                await ScheduleReader.create(kind: kind, title: title, startISO: start, durationMinutes: duration, notes: notes)
            }
        }
        toolContext.systemStatus = {
            await MainActor.run { SystemTools.status() }
        }
        // Only models that can't see images need the OCR path, but the
        // attachments are cheap to carry either way.
        var imageAttachments: [String: Data] = [:]
        for message in conversation.realMessages {
            for attachment in message.imageAttachments {
                imageAttachments[attachment.filename] = attachment.data
            }
        }
        toolContext.imageAttachments = imageAttachments
        toolContext.analyzeImage = { data, filename in
            await SystemTools.analyzeImage(data: data, filename: filename)
        }
        if isAgentToolsEnabled {
            let planAssistantID = assistantID
            toolContext.updatePlan = { [weak self] steps in
                await MainActor.run { [weak self] in
                    guard let self else { return "Error: the app is shutting down." }
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.planByMessage[planAssistantID] = steps
                    }
                    let done = steps.filter { $0.status == "completed" }.count
                    return "Plan updated — \(done)/\(steps.count) steps complete."
                }
            }
        }
        if isCommandToolEnabled {
            let workspaceRoot = conversation.workspaceRoot
            let conversationID = conversation.id
            toolContext.runCommand = { [weak self] command in
                await self?.executeCommand(command, in: workspaceRoot, conversationID: conversationID)
                    ?? "Error: the app is shutting down."
            }
        }
        if isSubagentsEnabled {
            let subagentModel = subagentModelOverride.isEmpty ? model : subagentModelOverride
            let subagentTools = Subagents.allowedTools(from: tools)
            let baseContext = toolContext
            let conversationID = conversation.id
            toolContext.spawnAgents = { [weak self] rawTasks in
                guard let self else { return "Error: the app is shutting down." }
                let tasks = rawTasks.prefix(3).map { Subagents.Task(name: $0.name, prompt: $0.prompt) }
                if await self.isSubagentApprovalRequired {
                    let summary = tasks.map { $0.name.isEmpty ? "a task" : $0.name }.joined(separator: ", ")
                    let approved = await self.confirmSubagents(count: tasks.count, summary: summary, conversationID: conversationID)
                    guard approved else {
                        return "The user declined to run subagents. Do the work yourself, or ask them how to proceed."
                    }
                }
                return await Subagents.run(
                    tasks: tasks,
                    profile: profile,
                    credential: credential,
                    model: subagentModel,
                    tools: subagentTools,
                    toolContext: baseContext
                )
            }
        }
        toolContext.mcpCall = { [weak self] name, argumentsJSON in
            await MainActor.run { [weak self] in self?.mcp }?.call(prefixedName: name, argumentsJSON: argumentsJSON)
                ?? "Error: MCP is unavailable."
        }
        if isClipboardToolEnabled {
            toolContext.clipboard = {
                await MainActor.run { () -> String in
                    let pasteboard = NSPasteboard.general
                    if let text = pasteboard.string(forType: .string), !text.isEmpty {
                        return text.count > Limits.systemReadBytes ? String(text.prefix(Limits.systemReadBytes)) + "\n[Truncated.]" : text
                    }
                    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
                        return "Files on the clipboard:\n" + urls.map(\.path).joined(separator: "\n")
                    }
                    return "The clipboard is empty or non-text."
                }
            }
        }
        // Providers/models without real tool-calling support keep the old
        // pre-fetch behavior exactly as before — nothing regresses for them.
        let shouldPrefetchSearch = isWebSearchEnabled
            && !usesNativeSearch
            && !trimmedSearchEndpoint.isEmpty
            && !modelSupportsTools
        let wireModel = (nativeSearch == .onlineSuffix && !model.hasSuffix(":online")) ? model + ":online" : model

        conversation.generationTask = Task { [weak self, weak conversation] in
            guard let conversation else { return }
            var finalMessages = requestMessages
            // MCP tools merge here, inside the task — a cold server's spawn
            // latency lands in the normal streaming window, and a broken
            // one can never block the send path.
            var tools = tools
            if modelSupportsTools, let self {
                let hasEnabledServers = self.mcp.servers.contains { $0.enabled && !$0.command.isEmpty }
                if hasEnabledServers {
                    // Cold servers spawn here — say so instead of letting
                    // the reply just sit silent for a few seconds.
                    self.statusMessage = "Starting MCP servers…"
                }
                let mcpDefinitions = await self.mcp.definitionsForSend()
                if hasEnabledServers { self.statusMessage = nil }
                tools.append(contentsOf: mcpDefinitions)
            }
            var promptContext = SystemPrompt.Context(
                tools: tools,
                nativeSearch: usesNativeSearch,
                hasMemories: modelSupportsTools,
                providerName: profile.name,
                providerKind: profile.kind,
                modelID: model,
                contextWindow: modelInfo?.contextLength
            )
            if let self {
                promptContext.userFirstName = NSFullUserName().components(separatedBy: " ").first
                promptContext.workspaceFiles = (try? FileManager.default.contentsOfDirectory(atPath: conversation.workspaceRoot.path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
                promptContext.activeSkillNames = conversation.activeSkillPaths.compactMap { path in
                    self.skills.skills.first(where: { $0.folderPath == path })?.name
                }
                promptContext.hasAttachedFolder = conversation.workspaceRootPath != nil
                promptContext.memoryCount = self.memories.count
                promptContext.attachmentNames = conversation.realMessages.flatMap { $0.attachments.map(\.filename) }
            }
            finalMessages.insert(ChatMessage(role: "system", content: SystemPrompt.compose(promptContext)), at: min(composeInsertIndex, finalMessages.count))
            if shouldPrefetchSearch, let self {
                do {
                    let results = try await CompatibleChatClient.shared.searchWeb(query: text, endpoint: trimmedSearchEndpoint)
                    if !results.isEmpty {
                        self.searchByMessage[assistantID] = WebSearchRecord(query: text, results: results)
                        let context = results.enumerated()
                            .map { "[\($0 + 1)] \($1.title) — \($1.url)\n\($1.snippet)" }
                            .joined(separator: "\n\n")
                        let searchMessage = ChatMessage(role: "system", content: "Web search results for \"\(text)\":\n\n\(context)")
                        if finalMessages.isEmpty {
                            finalMessages.append(searchMessage)
                        } else {
                            finalMessages.insert(searchMessage, at: finalMessages.count - 1)
                        }
                    }
                } catch {
                    // A failed search shouldn't block the reply — proceed without results.
                }
            }
            do {
                if profile.kind == .appleIntelligence {
                    try await AppleIntelligence.streamChat(messages: finalMessages) { [weak self, weak conversation] delta in
                        Task { @MainActor [weak self, weak conversation] in
                            guard let self, let conversation else { return }
                            self.enqueue(.text(delta), for: assistantID, conversation: conversation)
                        }
                    }
                } else {
                    // Two nested recoveries around the stream:
                    // - inner (resilience): offline sends wait for the
                    //   network; transient failures before ANY event
                    //   arrived retry with backoff. Once events flowed, a
                    //   retry could duplicate the turn — error card instead.
                    // - outer (auto-continue): a reply cut at the output
                    //   cap silently continues into the SAME message, at
                    //   most twice, with a quiet activity note.
                    var continueCount = 0
                    var streamedText = ""
                    while true {
                        var deliveredEvents = false
                        var attempt = 0
                        while true {
                            do {
                                if let self, !self.isOnline {
                                    self.postRetryNote("Offline — waiting for the network", to: conversation, assistantID: assistantID,
                                                       finish: "Sent once the connection returned")
                                    guard await self.waitForConnectivity(timeout: 600) else {
                                        throw APIError.message("Still offline after 10 minutes — this reply wasn't sent. Try again when you're back online.")
                                    }
                                }
                                try Task.checkCancellation()
                                let events = CompatibleChatClient.shared.streamChatEvents(
                                    profile: profile,
                                    credential: credential,
                                    model: wireModel,
                                    thinking: thinking,
                                    modelInfo: modelInfo,
                                    messages: finalMessages,
                                    tools: tools,
                                    toolContext: tools.isEmpty ? nil : toolContext,
                                    conversationKey: conversation.id
                                )
                                var batch: [ChatStreamEvent] = []
                                for try await event in events {
                                    deliveredEvents = true
                                    if case .delta(let content, _) = event { streamedText += content }
                                    batch.append(event)
                                    if batch.count >= 8 {
                                        self?.apply(batch, to: conversation, assistantID: assistantID)
                                        batch.removeAll(keepingCapacity: true)
                                    }
                                }
                                if !batch.isEmpty {
                                    self?.apply(batch, to: conversation, assistantID: assistantID)
                                }
                                // Only worth mentioning once it actually
                                // worked — and as one line, not one per try.
                                self?.noteRetrySummary(attempts: attempt, to: conversation, assistantID: assistantID)
                                break
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch where !deliveredEvents && attempt < Limits.maxTransientRetries && Self.isTransientFailure(error) {
                                attempt += 1
                                let delay = Double(attempt * attempt) * 2 + Double.random(in: 0...0.5)
                                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            } catch {
                                // Retries exhausted (or the failure was never
                                // retryable). This MUST reach the user as a
                                // real error — a silently empty reply after
                                // two invisible retries is the worst
                                // possible outcome.
                                throw attempt > 0
                                    ? APIError.message("\(error.localizedDescription) (after \(attempt) automatic \(attempt == 1 ? "retry" : "retries"))")
                                    : error
                            }
                        }
                        // Auto-continue: only on a provider-reported length
                        // cut, only with real partial text, at most twice.
                        guard let self,
                              self.finishReasonByMessage[assistantID] == "length",
                              continueCount < Limits.maxAutoContinues,
                              !streamedText.isEmpty else { break }
                        continueCount += 1
                        self.finishReasonByMessage[assistantID] = nil
                        self.postRetryNote("Reply hit the length cap — continuing", to: conversation, assistantID: assistantID,
                                           finish: "Continued automatically")
                        finalMessages.append(ChatMessage(role: "assistant", content: streamedText))
                        finalMessages.append(ChatMessage(role: "user", content: "Continue exactly where you left off — no repetition, no preamble."))
                    }
                }
                self?.finishGeneration(for: conversation, assistantID: assistantID)
                self?.generateTitleIfNeeded(for: conversation, profile: profile, model: model, credential: credential)
            } catch is CancellationError {
                self?.finishGeneration(for: conversation, assistantID: assistantID)
            } catch {
                self?.failGeneration(error.localizedDescription, for: conversation, assistantID: assistantID)
            }
        }
    }

    /// Subagent fan-out confirmation — same pause-and-decide shape as a
    /// command approval, since it also spends real requests.
    func confirmSubagents(count: Int, summary: String, conversationID: UUID) async -> Bool {
        let decision: CommandApproval.Decision = await withCheckedContinuation { continuation in
            let box = DecisionGuard()
            pendingApproval = CommandApproval(
                conversationID: conversationID,
                command: "Run \(count) subagent\(count == 1 ? "" : "s") in parallel: \(summary)",
                directory: activeConversation?.workspaceRoot ?? SandboxManager.directory(for: conversationID),
                reason: "Each subagent is a separate request to your provider, and they run at the same time.",
                isSubagentRequest: true
            ) { decision in
                guard !box.answered else { return }
                box.answered = true
                continuation.resume(returning: decision)
            }
        }
        pendingApproval = nil
        if case .deny = decision { return false }
        return true
    }

    /// Attaches a real folder to the active conversation as its workspace
    /// root. A visible notice records it — the user should always know
    /// which directory the assistant is working in.
    func setWorkspaceRoot(_ url: URL) {
        let conversation = activeConversation ?? newConversation()
        conversation.workspaceRootPath = url.path
        postNotice("Workspace set to \(url.path). File tools and commands run here.", to: conversation)
        saveHistory()
    }

    func clearWorkspaceRoot(for conversation: Conversation) {
        conversation.workspaceRootPath = nil
        saveHistory()
    }

    /// One-shot latch for an approval card's answer (see `executeCommand`).
    private final class DecisionGuard: @unchecked Sendable {
        var answered = false
    }

    /// run_command's gate. Read-only commands run immediately; everything
    /// else pauses the generation on a real approval card in the
    /// transcript. A denial goes back to the model as a normal tool
    /// result so it can adapt instead of failing.
    func executeCommand(_ command: String, in directory: URL, conversationID: UUID) async -> String {
        let conversation = conversations.first { $0.id == conversationID }
        let classification = CommandRunner.classify(command)
        var approvedCommand = command
        var needsPrompt = false
        var reason = ""

        switch classification {
        case .readOnly:
            break
        case .needsApproval(let why):
            if conversation?.allowAllCommands == true || conversation?.alwaysAllowedCommands.contains(command) == true {
                break
            }
            needsPrompt = true
            reason = why
        }

        if needsPrompt {
            let decision: CommandApproval.Decision = await withCheckedContinuation { continuation in
                // The card can be answered exactly once; a stray second tap
                // must not crash on a double resume. `decide` is only ever
                // called from the card's buttons, i.e. the main actor.
                let box = DecisionGuard()
                let approval = CommandApproval(
                    conversationID: conversationID,
                    command: command,
                    directory: directory,
                    reason: reason
                ) { decision in
                    guard !box.answered else { return }
                    box.answered = true
                    continuation.resume(returning: decision)
                }
                pendingApproval = approval
            }
            pendingApproval = nil
            switch decision {
            case .deny:
                return "The user denied this command. Do not retry it — ask what they'd prefer, or take a different approach."
            case .approveOnce(let edited):
                approvedCommand = edited
            case .approveAlways(let edited):
                approvedCommand = edited
                conversation?.alwaysAllowedCommands.insert(edited)
            case .approveAll(let edited):
                approvedCommand = edited
                conversation?.allowAllCommands = true
            }
        }

        let output = await CommandRunner.run(approvedCommand, in: directory)
        return CommandRunner.formatted(output, command: approvedCommand)
    }

    /// A quiet, self-resolving activity line for retry/offline waits —
    /// the same visual language as tool calls, per the no-invisible-magic
    /// rule.
    private func postRetryNote(_ label: String, to conversation: Conversation, assistantID: UUID, finish: String) {
        var record = ActivityRecord(id: UUID(), kind: .note, toolName: "note", argument: label)
        record.isRunning = true
        enqueue(.activity(record), for: assistantID, conversation: conversation)
        enqueue(.activityUpdate(id: record.id, result: finish, isError: false), for: assistantID, conversation: conversation)
    }

    /// One line for a whole retry sequence rather than a stack of notes:
    /// a reply that limped through three attempts should read as "this
    /// connection is flaky", not as three separate events.
    private func noteRetrySummary(attempts: Int, to conversation: Conversation, assistantID: UUID) {
        guard attempts > 0 else { return }
        let label = attempts == 1 ? "Retried once — connection unstable" : "Retried \(attempts) times — connection unstable"
        var record = ActivityRecord(id: UUID(), kind: .note, toolName: "note", argument: label)
        record.isRunning = false
        record.result = "The provider or network failed before the reply started; VelaChat retried automatically."
        enqueue(.activity(record), for: assistantID, conversation: conversation)
    }

    func stopGeneration(for conversation: Conversation? = nil) {
        guard let conversation = conversation ?? activeConversation else { return }
        conversation.generationTask?.cancel()
        conversation.generationTask = nil
        if let index = conversation.messages.lastIndex(where: { $0.isStreaming }) {
            let assistantID = conversation.messages[index].id
            flushReveal(for: assistantID, conversation: conversation)
            conversation.messages[index].isStreaming = false
            // Tools that were mid-flight when the user hit Stop must not
            // shimmer forever — mark them interrupted.
            conversation.messages[index].reconcileRunningActivities()
            // A stopped reply still consumed tokens; count what we saw.
            recordUsage(for: conversation, assistantID: assistantID)
        }
        conversation.isGenerating = false
        saveHistory()
    }

    func retryLastMessage() {
        guard let conversation = activeConversation,
              let lastUserIndex = conversation.messages.lastIndex(where: { $0.role == "user" }) else { return }
        guard !conversation.isGenerating else {
            postNotice("Already generating a reply.", to: conversation)
            return
        }
        let lastUser = conversation.messages[lastUserIndex]
        // `send` always appends a fresh user message, so the old one (and
        // everything after it, e.g. a failed reply) must go too — otherwise
        // retry duplicates the prompt instead of resending it.
        let snapshot = conversation.messages
        conversation.messages.removeSubrange(lastUserIndex...)
        send(lastUser.content, replacingReplyWith: nil, restoring: (conversation, snapshot))
    }

    /// One unit of buffered reveal work. Ops apply strictly in order, so an
    /// activity line can never appear before the text the model wrote ahead
    /// of the call has finished revealing — the timeline on screen always
    /// matches the order things actually happened.
    private enum RevealOp {
        case text(String)
        case reasoning(String)
        case activity(ActivityRecord)
        case activityUpdate(id: UUID, result: String, isError: Bool)
    }

    private func enqueue(_ op: RevealOp, for assistantID: UUID, conversation: Conversation) {
        guard conversation.messages.contains(where: { $0.id == assistantID }) else { return }
        var queue = revealQueues[assistantID] ?? []
        // Consecutive same-kind chunks coalesce so the queue stays short.
        switch op {
        case .text(let chunk):
            if case .text(let existing) = queue.last {
                queue[queue.count - 1] = .text(existing + chunk)
            } else {
                queue.append(op)
            }
        case .reasoning(let chunk):
            if case .reasoning(let existing) = queue.last {
                queue[queue.count - 1] = .reasoning(existing + chunk)
            } else {
                queue.append(op)
            }
        case .activity, .activityUpdate:
            queue.append(op)
        }
        revealQueues[assistantID] = queue
        ensureRevealTask(for: assistantID, conversation: conversation)
        // `updatedAt` is deliberately NOT touched here — it's @Observable,
        // and writing it per token re-rendered every observer ~36x/second.
        // It's stamped once in `send` and once when generation ends.
    }

    private func ensureRevealTask(for assistantID: UUID, conversation: Conversation) {
        guard revealTasks[assistantID] == nil else { return }
        // The very first words go on screen immediately rather than after a
        // reveal tick. Time-to-first-token is the one moment where the
        // typewriter pacing is pure added latency: there is nothing on
        // screen yet for it to pace against.
        flushFirstReveal(for: assistantID, conversation: conversation)
        revealTasks[assistantID] = Task { [weak self, weak conversation] in
            while !Task.isCancelled {
                guard let self, let conversation else { return }
                guard var queue = self.revealQueues[assistantID], !queue.isEmpty else {
                    self.revealTasks[assistantID] = nil
                    // The stream ended while text was still draining — the
                    // deferred finish work runs now that it's all on screen.
                    if self.pendingFinish.remove(assistantID) != nil {
                        self.completeGeneration(for: conversation, assistantID: assistantID)
                    }
                    return
                }
                guard let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) else {
                    self.revealTasks[assistantID] = nil
                    self.revealQueues[assistantID] = nil
                    self.pendingFinish.remove(assistantID)
                    return
                }
                // Adaptive pace: the drain speeds up smoothly as backlog
                // grows instead of ever letting `finishGeneration` dump the
                // rest in one frame — the end-of-reply SNAP is gone. Once
                // the stream has finished (`pendingFinish`), the remaining
                // buffer drains in well under a second.
                let backlogCharacters = queue.reduce(0) { partial, op in
                    switch op {
                    case .text(let pending), .reasoning(let pending): partial + pending.count
                    case .activity, .activityUpdate: partial
                    }
                }
                let finishing = self.pendingFinish.contains(assistantID)
                // One UI mutation per ~33ms frame, revealing however many
                // words the pace calls for — per-word mutations at up to
                // 60Hz re-rendered the transcript into visible lag.
                func wordsPerTick(base: Int) -> Int {
                    var count = base
                    if backlogCharacters > 400 { count = max(count, backlogCharacters / 200) }
                    if finishing { count = max(count, backlogCharacters / 60 + 4) }
                    return count
                }
                switch queue[0] {
                case .text(var pending):
                    var chunk = ""
                    for _ in 0..<wordsPerTick(base: 1) {
                        guard !pending.isEmpty else { break }
                        chunk += Self.popNextWord(from: &pending)
                    }
                    if pending.isEmpty { queue.removeFirst() } else { queue[0] = .text(pending) }
                    self.revealQueues[assistantID] = queue
                    conversation.messages[index].appendTimelineText(chunk)
                    self.noteFirstToken(for: assistantID, conversation: conversation)
                    try? await Task.sleep(nanoseconds: 33_000_000)
                case .reasoning(var pending):
                    // Faster than the answer text — reasoning chains run
                    // long, and the answer shouldn't wait behind them.
                    var chunk = ""
                    for _ in 0..<wordsPerTick(base: 4) {
                        guard !pending.isEmpty else { break }
                        chunk += Self.popNextWord(from: &pending)
                    }
                    if pending.isEmpty { queue.removeFirst() } else { queue[0] = .reasoning(pending) }
                    self.revealQueues[assistantID] = queue
                    conversation.messages[index].reasoning = (conversation.messages[index].reasoning ?? "") + chunk
                    try? await Task.sleep(nanoseconds: 33_000_000)
                case .activity(let record):
                    queue.removeFirst()
                    self.revealQueues[assistantID] = queue
                    conversation.messages[index].appendActivity(record)
                case .activityUpdate(let id, let result, let isError):
                    queue.removeFirst()
                    self.revealQueues[assistantID] = queue
                    conversation.messages[index].updateActivity(id: id, result: result, isError: isError)
                }
            }
        }
    }

    /// Puts the first chunk of a reply on screen synchronously, before the
    /// paced drain starts. Only ever runs when the message is still empty,
    /// so it can't skip ahead of text already being revealed.
    private func flushFirstReveal(for assistantID: UUID, conversation: Conversation) {
        guard var queue = revealQueues[assistantID], !queue.isEmpty,
              let index = conversation.messages.firstIndex(where: { $0.id == assistantID }),
              conversation.messages[index].content.isEmpty,
              conversation.messages[index].reasoning?.isEmpty ?? true else { return }
        switch queue[0] {
        case .text(var pending):
            let chunk = Self.popNextWord(from: &pending)
            if pending.isEmpty { queue.removeFirst() } else { queue[0] = .text(pending) }
            revealQueues[assistantID] = queue
            conversation.messages[index].appendTimelineText(chunk)
            noteFirstToken(for: assistantID, conversation: conversation)
        case .reasoning(var pending):
            let chunk = Self.popNextWord(from: &pending)
            if pending.isEmpty { queue.removeFirst() } else { queue[0] = .reasoning(pending) }
            revealQueues[assistantID] = queue
            conversation.messages[index].reasoning = (conversation.messages[index].reasoning ?? "") + chunk
            noteFirstToken(for: assistantID, conversation: conversation)
        case .activity, .activityUpdate:
            break  // the paced drain handles these; they aren't "first token"
        }
    }

    /// Pops one word (plus any trailing whitespace) off the front of
    /// `pending`, so the reveal never flashes a partial word on screen.
    private static func popNextWord(from pending: inout String) -> String {
        guard let firstNonSpace = pending.firstIndex(where: { !$0.isWhitespace }) else {
            defer { pending.removeAll() }
            return pending
        }
        var cursor = firstNonSpace
        while cursor < pending.endIndex, !pending[cursor].isWhitespace {
            cursor = pending.index(after: cursor)
        }
        while cursor < pending.endIndex, pending[cursor].isWhitespace {
            cursor = pending.index(after: cursor)
        }
        let chunk = String(pending[pending.startIndex..<cursor])
        pending.removeSubrange(pending.startIndex..<cursor)
        return chunk
    }

    /// Immediately (synchronously, no animation) writes back whatever's
    /// still buffered for `assistantID` and cancels its reveal task. Called
    /// whenever generation ends — normally, on failure, or on Stop — so a
    /// reveal task can never outlive generation or get orphaned the way the
    /// old stuck-`isStreaming` bug happened.
    private func flushReveal(for assistantID: UUID, conversation: Conversation) {
        revealTasks[assistantID]?.cancel()
        revealTasks[assistantID] = nil
        pendingFinish.remove(assistantID)
        guard let queue = revealQueues.removeValue(forKey: assistantID), !queue.isEmpty else { return }
        guard let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) else { return }
        for op in queue {
            switch op {
            case .text(let chunk):
                conversation.messages[index].appendTimelineText(chunk)
            case .reasoning(let chunk):
                conversation.messages[index].reasoning = (conversation.messages[index].reasoning ?? "") + chunk
            case .activity(let record):
                conversation.messages[index].appendActivity(record)
            case .activityUpdate(let id, let result, let isError):
                conversation.messages[index].updateActivity(id: id, result: result, isError: isError)
            }
        }
    }

    /// True while the head of a message's reveal queue is reasoning —
    /// drives the "Thinking…" shimmer even between tool rounds, where
    /// content already exists but the model is thinking again.
    func isRevealingReasoning(_ id: UUID) -> Bool {
        if case .reasoning = revealQueues[id]?.first { return true }
        return false
    }

    private func apply(_ event: ChatStreamEvent, to conversation: Conversation, assistantID: UUID) {
        apply([event], to: conversation, assistantID: assistantID)
    }

    private func apply(_ events: [ChatStreamEvent], to conversation: Conversation, assistantID: UUID) {
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokens: Int?
        // Events enqueue in arrival order — deltas must NOT be merged across
        // an activity boundary, or the interleaving is lost.
        for event in events {
            switch event {
            case .delta(let content, let reasoning):
                if !content.isEmpty { enqueue(.text(content), for: assistantID, conversation: conversation) }
                if !reasoning.isEmpty { enqueue(.reasoning(reasoning), for: assistantID, conversation: conversation) }
            case .usage(let prompt, let completion, let cached):
                promptTokens = prompt ?? promptTokens
                completionTokens = completion ?? completionTokens
                cachedTokens = cached ?? cachedTokens
            case .finished(let reason):
                if let reason {
                    // Normalize the providers' truncation vocabulary.
                    let normalized = ["length", "max_tokens", "max_output_tokens"].contains(reason.lowercased()) ? "length" : reason
                    finishReasonByMessage[assistantID] = normalized
                }
            case .activityStarted(let id, let name, let argument):
                var record = ActivityRecord(id: id, kind: .from(toolName: name), toolName: name, argument: argument)
                record.isRunning = true
                enqueue(.activity(record), for: assistantID, conversation: conversation)
            case .quota(let snapshot):
                if let providerID = conversation.providerID {
                    quotaByProvider[providerID] = snapshot
                }
            case .activityFinished(let id, let result, let isError):
                // Persisted per-message forever — cap so one huge page fetch
                // doesn't bloat history (the model already saw the full text).
                let capped = result.count > Limits.toolResultBytes
                    ? String(result.prefix(Limits.toolResultBytes)) + "\n\n[Truncated — kept the first 4 KB.]"
                    : result
                enqueue(.activityUpdate(id: id, result: capped, isError: isError), for: assistantID, conversation: conversation)
            }
        }
        if promptTokens != nil || completionTokens != nil {
            let summary = UsageSummary(promptTokens: promptTokens, completionTokens: completionTokens, cachedTokens: cachedTokens)
            usageByMessage[assistantID] = summary
            // Persisted onto the message itself (not just the in-memory
            // cache above) so lifetime usage statistics survive a relaunch
            // instead of resetting to zero every session.
            if let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) {
                conversation.messages[index].usage = summary
            }
        }
    }

    private func finishGeneration(for conversation: Conversation?, assistantID: UUID) {
        guard let conversation else { return }
        // If the reveal is still catching up, don't dump the buffer — let
        // the drain finish at its (accelerated) pace and run the finish
        // work from there. Stop and failure keep the instant flush.
        if revealQueues[assistantID]?.isEmpty == false, revealTasks[assistantID] != nil {
            pendingFinish.insert(assistantID)
            return
        }
        completeGeneration(for: conversation, assistantID: assistantID)
    }

    /// One ledger entry per finished reply, from the final persisted
    /// summary — providers emit .usage several times mid-stream, so the
    /// per-event path must never feed the ledger directly.
    private func recordUsage(for conversation: Conversation, assistantID: UUID) {
        guard let providerID = conversation.providerID,
              let message = conversation.messages.first(where: { $0.id == assistantID }),
              let summary = usageByMessage[assistantID] ?? message.usage else { return }
        let modelInfo = providers.modelInfo(for: providerID, model: message.modelID ?? conversation.model)
        usage.record(
            providerID: providerID,
            promptTokens: summary.promptTokens,
            completionTokens: summary.completionTokens,
            costUSD: summary.costUSD(for: modelInfo)
        )
    }

    private func completeGeneration(for conversation: Conversation, assistantID: UUID) {
        flushReveal(for: assistantID, conversation: conversation)
        recordUsage(for: conversation, assistantID: assistantID)
        finishReasonByMessage[assistantID] = nil
        // The end-of-reply state changes (streaming indicator out, action
        // row and usage label in) fade rather than popping in one frame.
        withAnimation(.easeOut(duration: 0.3)) {
            if let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) {
                conversation.messages[index].isStreaming = false
            }
        }
        conversation.updatedAt = Date()
        // Only touch shared generation state (`isGenerating`/`generationTask`)
        // if this is still the *current* generation. A Stop immediately
        // followed by a new Send starts a new generation before this
        // cancelled task's completion handler gets a chance to run — without
        // this check, it would stomp the new generation's state once it did.
        if conversation.currentGenerationID == assistantID {
            conversation.isGenerating = false
            conversation.generationTask = nil
        }
        saveHistory()
        notifyIfBackgrounded(conversation: conversation, assistantID: assistantID)
        autoCompactIfNeeded(conversation)
    }

    /// What actually gets sent for the next turn: everything, unless this
    /// conversation has been compacted, in which case everything up to and
    /// including the last compaction marker collapses into one system
    /// message carrying its summary, and only what came after stays as full
    /// messages. Nothing is ever deleted from `conversation.messages`
    /// itself — this only ever affects the request payload.
    private func requestHistory(for conversation: Conversation) -> [ChatMessage] {
        guard let boundary = conversation.lastCompactionIndex else {
            return Array(conversation.messages.dropLast()).filter { !$0.isSynthetic }
        }
        let summary = conversation.messages[boundary].content
        let after = Array(conversation.messages[(boundary + 1)...])
        var trimmed = Array(after.dropLast()).filter { !$0.isSynthetic }
        // A pinned message surviving compaction only in paraphrased form is
        // exactly the failure mode worth avoiding — Cursor has a known,
        // reported bug where rules/instructions silently don't survive
        // context compression. Anything explicitly pinned skips
        // summarization entirely and rides along verbatim instead.
        let pinnedBeforeBoundary = conversation.messages[..<boundary].filter { $0.isPinned && !$0.isSynthetic }
        if !pinnedBeforeBoundary.isEmpty {
            let pinnedText = pinnedBeforeBoundary.map { "\($0.role.uppercased()): \($0.content)" }.joined(separator: "\n\n")
            trimmed.insert(ChatMessage(role: "system", content: "Pinned messages from earlier in this conversation, kept verbatim rather than summarized:\n\n\(pinnedText)"), at: 0)
        }
        trimmed.insert(ChatMessage(role: "system", content: "Summary of the earlier part of this conversation (older messages were compacted to save context; nothing was deleted):\n\n\(summary)"), at: 0)
        return trimmed
    }

    /// Fires at 95% of the detected context window (explicit user choice —
    /// compaction should be a late safety net, not an eager trimmer), scaled
    /// to the window rather than a fixed token count since windows here
    /// range from small local models to million-token hosted ones. Only
    /// fires when the window is actually known.
    private func autoCompactIfNeeded(_ conversation: Conversation) {
        guard let window = contextWindow(for: conversation), window > 0 else { return }
        let used = tokenEstimate(for: conversation)
        guard Double(used) / Double(window) >= 0.95 else { return }
        compactConversation(conversation, isAutomatic: true)
    }

    /// Summarizes everything since the last compaction (or the whole
    /// conversation, the first time) using the conversation's own active
    /// model/provider — the same mechanism the AI-titling feature already
    /// uses. The generated summary becomes a new `"compaction"` marker
    /// inserted into the transcript; the messages it covers are never
    /// touched or hidden, only left out of future request payloads.
    func compactConversation(_ conversation: Conversation, isAutomatic: Bool = false) {
        guard !compactingConversationIDs.contains(conversation.id) else { return }
        guard let providerID = conversation.providerID, let profile = providers.profile(id: providerID) else {
            if !isAutomatic { postNotice("Choose a real provider before compacting.", to: conversation) }
            return
        }
        guard !conversation.isGenerating else {
            if !isAutomatic { postNotice("Already generating a reply.", to: conversation) }
            return
        }
        let startIndex = conversation.lastCompactionIndex.map { $0 + 1 } ?? 0
        guard startIndex < conversation.messages.count else { return }
        let priorSummary: String? = conversation.lastCompactionIndex.map { conversation.messages[$0].content }
        let span = Array(conversation.messages[startIndex...])
        let realSpan = span.filter { !$0.isSynthetic && !$0.isStreaming && !$0.isPinned }
        // A handful of the most recent exchanges stay raw even when
        // compacting, never summarized — nothing that just happened should
        // get paraphrased away before it's had a chance to actually matter
        // on a later turn. (Pinned messages are excluded above entirely;
        // they never get summarized at any age — see `requestHistory`.)
        let recencyBuffer = 4
        // Not worth the round trip (or the risk of summarizing away detail
        // that mattered) for a short thread — automatic compaction in
        // particular should only ever fire on a conversation that's
        // genuinely gotten long.
        guard realSpan.count >= 6 + recencyBuffer else {
            if !isAutomatic { postNotice("Not enough conversation yet to compact.", to: conversation) }
            return
        }
        let toSummarize = Array(realSpan.dropLast(recencyBuffer))
        guard let lastSummarizedID = toSummarize.last?.id else { return }

        let transcript = toSummarize.map { "\($0.role.uppercased()): \($0.content)" }.joined(separator: "\n\n")
        var prompt = """
        Summarize the conversation below into a structured brief for continuing it later: the user's goals, key decisions made, and the current state of things. Quote exact numbers, file paths, code, error messages, and decisions verbatim rather than paraphrasing them — precise details like these are exactly what gets lost in a summary and exactly what a continuation needs to get right. Write plain prose or bullets, not a transcript. Do not add commentary about the summarization itself. Keep it well under 500 words unless the conversation genuinely can't be preserved usefully in less.
        """
        if let priorSummary, !priorSummary.isEmpty {
            prompt += "\n\nEarlier summary (already covers everything before this point):\n\(priorSummary)"
        }
        prompt += "\n\nConversation to summarize:\n\n\(transcript)"

        compactingConversationIDs.insert(conversation.id)
        if conversation.id == activeConversationID { statusMessage = "Compacting conversation…" }
        let model = conversation.model.isEmpty ? providers.effectiveModel(for: profile) : conversation.model
        let credential = providers.credential(for: profile)

        Task { [weak self] in
            guard let self else { return }
            defer { self.compactingConversationIDs.remove(conversation.id) }
            var summaryText = ""
            do {
                let promptWordCount = prompt.split(separator: " ").count
                if self.canUseAppleIntelligence, promptWordCount < AppleIntelligence.contextBudgetWords {
                    // On-device: free, instant-ish, and the transcript
                    // never leaves the Mac just to be summarized.
                    summaryText = try await AppleIntelligence.complete(prompt: prompt)
                } else if profile.kind == .appleIntelligence {
                    throw AppleIntelligence.Unavailable(reason: AppleIntelligence.unavailabilityReason ?? "The conversation is too long for the on-device model.")
                } else {
                    let events = CompatibleChatClient.shared.streamChatEvents(
                        profile: profile,
                        credential: credential,
                        model: model,
                        thinking: .auto,
                        messages: [ChatMessage(role: "user", content: prompt)]
                    )
                    for try await event in events {
                        if case .delta(let content, _) = event { summaryText += content }
                    }
                }
            } catch {
                if conversation.id == self.activeConversationID { self.statusMessage = nil }
                if !isAutomatic { self.postNotice("Couldn't compact this conversation: \(error.localizedDescription)", to: conversation) }
                return
            }
            if conversation.id == self.activeConversationID { self.statusMessage = nil }
            let cleaned = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                if !isAutomatic { self.postNotice("The model didn't return a usable summary.", to: conversation) }
                return
            }
            // The marker lands right after the last message the summary
            // actually covers — not the end of the whole span — so the
            // recency buffer (and any pinned messages) stay correctly on
            // the "not summarized" side of the boundary.
            guard let insertAfterIndex = conversation.messages.firstIndex(where: { $0.id == lastSummarizedID }) else {
                // The message the summary was anchored to was deleted while
                // this was in flight — the summary itself is still real
                // work the user is waiting on, so say so rather than
                // letting "Compacting…" just silently vanish.
                if !isAutomatic { self.postNotice("Compaction finished, but the conversation changed too much while it ran to safely insert the summary. Try again.", to: conversation) }
                return
            }
            conversation.messages.insert(ChatMessage(role: "compaction", content: cleaned), at: insertAfterIndex + 1)
            self.saveHistory()
        }
    }

    /// A portable handoff document for a different agent (or a fresh
    /// instance of you, with no memory of this conversation) to pick up
    /// cold — same summarization mechanism as compaction, framed
    /// differently and covering the whole conversation rather than just
    /// the "older" portion. Copied to the clipboard rather than written
    /// into the conversation, since the whole point is to leave with you.
    func generateHandoffDocument(for conversation: Conversation) {
        guard let providerID = conversation.providerID, let profile = providers.profile(id: providerID) else {
            postNotice("Choose a real provider before generating a handoff.", to: conversation)
            return
        }
        guard !conversation.isGenerating else {
            postNotice("Already generating a reply.", to: conversation)
            return
        }
        let priorSummary = conversation.lastCompactionIndex.map { conversation.messages[$0].content }
        let startIndex = conversation.lastCompactionIndex.map { $0 + 1 } ?? 0
        let real = startIndex < conversation.messages.count
            ? conversation.messages[startIndex...].filter { !$0.isSynthetic && !$0.isStreaming }
            : []
        guard !real.isEmpty || (priorSummary?.isEmpty == false) else {
            postNotice("Nothing to hand off yet.", to: conversation)
            return
        }
        let transcript = real.map { "\($0.role.uppercased()): \($0.content)" }.joined(separator: "\n\n")
        var prompt = """
        Write a handoff document for a different AI agent (or a fresh instance of you, with no memory of this conversation) to pick up this work cold. Structure it as: Goal, Key decisions made (with the reasoning where it matters), Current state, Open threads / what's next. Quote exact numbers, file paths, code, and specifics verbatim rather than paraphrasing — the whole point is that nothing important gets lost in the handoff. Write it as a real markdown document, not commentary about writing one.
        """
        if let priorSummary, !priorSummary.isEmpty {
            prompt += "\n\nEarlier summary of this conversation (from before, still relevant):\n\(priorSummary)"
        }
        if !transcript.isEmpty {
            prompt += "\n\nConversation:\n\n\(transcript)"
        }

        if conversation.id == activeConversationID { statusMessage = "Generating handoff document…" }
        let model = conversation.model.isEmpty ? providers.effectiveModel(for: profile) : conversation.model
        let credential = providers.credential(for: profile)

        Task { [weak self] in
            guard let self else { return }
            var text = ""
            do {
                let promptWordCount = prompt.split(separator: " ").count
                if self.canUseAppleIntelligence, promptWordCount < AppleIntelligence.contextBudgetWords {
                    text = try await AppleIntelligence.complete(prompt: prompt)
                } else if profile.kind == .appleIntelligence {
                    throw AppleIntelligence.Unavailable(reason: AppleIntelligence.unavailabilityReason ?? "The conversation is too long for the on-device model.")
                } else {
                    let events = CompatibleChatClient.shared.streamChatEvents(
                        profile: profile,
                        credential: credential,
                        model: model,
                        thinking: .auto,
                        messages: [ChatMessage(role: "user", content: prompt)]
                    )
                    for try await event in events {
                        if case .delta(let content, _) = event { text += content }
                    }
                }
            } catch {
                if conversation.id == self.activeConversationID { self.statusMessage = nil }
                self.postNotice("Couldn't generate a handoff document: \(error.localizedDescription)", to: conversation)
                return
            }
            if conversation.id == self.activeConversationID { self.statusMessage = nil }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cleaned, forType: .string)
            self.postNotice("Handoff document copied to clipboard.", kind: "success", to: conversation)
        }
    }

    /// A native notification for a reply that finished while you weren't
    /// looking at it — either a different conversation is open, or the app
    /// isn't frontmost at all. Only meaningful now that the app can actually
    /// stay alive with the window closed.
    private func notifyIfBackgrounded(conversation: Conversation, assistantID: UUID) {
        guard AppModel.isRunningAsBundledApp else { return }
        guard conversation.id != activeConversationID || !NSApp.isActive else { return }
        guard let message = conversation.messages.first(where: { $0.id == assistantID }),
              message.error == nil, !message.content.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = conversation.title
        content.body = String(message.content.prefix(140))
        content.sound = .default
        let request = UNNotificationRequest(identifier: assistantID.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func failGeneration(_ message: String, for conversation: Conversation?, assistantID: UUID) {
        guard let conversation else { return }
        flushReveal(for: assistantID, conversation: conversation)
        // The failed assistant message itself carries `.error` and already
        // renders inline in the transcript (with a "Try Again") — posting a
        // second, separate notice on top of it would just say the same
        // thing twice.
        if let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) {
            conversation.messages[index].isStreaming = false
            conversation.messages[index].reconcileRunningActivities()
            conversation.messages[index].error = message
        }
        recordUsage(for: conversation, assistantID: assistantID)
        conversation.updatedAt = Date()
        // See the matching comment in `finishGeneration` — same race guard.
        if conversation.currentGenerationID == assistantID {
            conversation.isGenerating = false
            conversation.generationTask = nil
        }
        saveHistory()
    }

    /// Debounced: encoding every conversation (attachments included) is
    /// megabytes of synchronous JSON work — doing it inline on every notice,
    /// pin, and finished reply stalled the main thread. Mutations mark dirty;
    /// the actual encode runs ~1s later, off the main thread. Destructive
    /// operations and app termination call `flushHistoryNow()` instead.
    private func saveHistory() {
        guard historySaveTask == nil else { return }
        historySaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.historySaveTask = nil
            self.writeHistoryNow()
        }
    }

    /// Synchronous — used on quit (a detached encode would race process
    /// exit) and after destructive operations, where losing the write to a
    /// crash inside the debounce window would be unacceptable.
    func flushHistoryNow() {
        historySaveTask?.cancel()
        historySaveTask = nil
        writeHistoryNow(synchronously: true)
    }

    private func writeHistoryNow(synchronously: Bool = false) {
        let snapshots = conversations.map {
            SavedConversation(id: $0.id, title: $0.title, messages: $0.messages, providerID: $0.providerID, model: $0.model, createdAt: $0.createdAt, updatedAt: $0.updatedAt, draftText: $0.draftText, titleIsCustom: $0.titleIsCustom, isPinned: $0.isPinned, activeSkillPaths: $0.activeSkillPaths, workspaceRootPath: $0.workspaceRootPath)
        }
        let key = historyKey
        if synchronously {
            if let data = try? JSONEncoder().encode(snapshots) {
                UserDefaults.standard.set(data, forKey: key)
            }
        } else {
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshots) {
                    UserDefaults.standard.set(data, forKey: key)
                }
            }
        }
    }

    /// Returns a notice to post once a conversation is guaranteed to exist
    /// (the caller in `init()` handles that timing) rather than posting one
    /// directly — there's nothing to attach it to yet at this point.
    private func restoreHistory() -> String? {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return nil }
        guard let snapshots = try? JSONDecoder().decode([SavedConversation].self, from: data) else {
            UserDefaults.standard.set(data, forKey: historyBackupKey)
            return "Saved conversations could not be read; a backup was kept."
        }
        conversations = snapshots.map {
            Conversation(id: $0.id, title: $0.title, messages: $0.messages, providerID: $0.providerID, model: $0.model, createdAt: $0.createdAt, updatedAt: $0.updatedAt, draftText: $0.draftText, titleIsCustom: $0.titleIsCustom, isPinned: $0.isPinned, activeSkillPaths: $0.activeSkillPaths, workspaceRootPath: $0.workspaceRootPath)
        }
        reconcileInterruptedMessages()
        activeConversationID = conversations.first?.id
        return nil
    }

    /// No generation `Task` can survive a relaunch, so a message still
    /// marked `isStreaming` in saved history means the app quit or crashed
    /// mid-reply. Left alone it would show a permanent, un-clearable
    /// "streaming" spinner with no way to ever finish or retry it.
    private func reconcileInterruptedMessages() {
        var didChange = false
        for conversation in conversations {
            for index in conversation.messages.indices where conversation.messages[index].isStreaming {
                conversation.messages[index].isStreaming = false
                conversation.messages[index].reconcileRunningActivities()
                if conversation.messages[index].content.isEmpty, conversation.messages[index].error == nil {
                    conversation.messages[index].error = "Interrupted before finishing — the app closed or crashed."
                }
                didChange = true
            }
        }
        if didChange { saveHistory() }
    }
}

/// `AVSpeechSynthesizerDelegate` requires `NSObject`, and its callbacks
/// aren't guaranteed to land on the main thread — kept as a tiny standalone
/// object rather than making `AppModel` itself an `NSObject`.
private final class SpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish?()
    }
}
