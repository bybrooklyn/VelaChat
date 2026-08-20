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
        routine replies — write first and ask at the end. Give a short, \
        genuinely useful reply: what you already know, or the part of the \
        work you can do without the answer. Finish the thought, and only \
        then put the question block last, so the user is never left \
        staring at half a paragraph above a question card. Nothing may \
        follow the block. It takes exactly this shape:

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
    /// Per-model characters-per-token ratios, fitted from the
    /// provider-reported `prompt_tokens` of finished replies. Turns the
    /// context readout from a flat `characters / 4` guess into something
    /// calibrated against what the provider actually charged.
    let tokenCalibration = TokenCalibrationStore()
    let redaction = RedactionStore()
    /// Hard egress switch. The stored value is mirrored into `EgressPolicy`
    /// (a process-wide gate read at request construction) because the
    /// paths that must honor it — the ChatGPT web client, quota probes,
    /// model discovery — never see `AppModel`.
    var isLocalOnlyMode = false {
        didSet {
            UserDefaults.standard.set(isLocalOnlyMode, forKey: DefaultsKey.localOnlyMode)
            EgressPolicy.isLocalOnly = isLocalOnlyMode
        }
    }
    let mcp = McpManager()
    let skills = SkillsStore()
    let memoryIndexer = MemoryIndexer()
    /// Which stored facts and past-conversation excerpts informed each
    /// reply — surfaced under the message so recall is explainable rather
    /// than magical.
    var recallByMessage: [UUID: [MemoryRecall]] = [:]
    var promptSnippets: [PromptSnippet] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(promptSnippets) {
                UserDefaults.standard.set(data, forKey: DefaultsKey.promptSnippets)
            }
        }
    }
    /// The user's durable facts, global and included in every request —
    /// see `MemoryItem`.
    ///
    /// Read-only from outside, and NOT persisted here. Facts used to live
    /// in this array as a `UserDefaults`-backed list that was separately
    /// *mirrored* into `MemoryStore` so retrieval had something to search.
    /// Two sources of truth for the same data is its own bug: a write that
    /// reached one and not the other left the list the user edits and the
    /// text the model recalls permanently disagreeing, which reads as
    /// "memory is just bad" rather than as a missing write.
    ///
    /// The store is the only home now. Every mutation goes through it and
    /// comes back through `refreshFacts()`; this array exists solely
    /// because SwiftUI renders synchronously and the store is an actor.
    private(set) var facts: [MemoryItem] = []
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
    /// What each in-flight reply actually sent, kept until the provider
    /// reports how many tokens that was. Dropped the moment the reply stops
    /// being a single request — a tool round or an auto-continue — because
    /// the `prompt_tokens` it would then be measured against covers several
    /// requests, not the one text this recorded.
    var calibrationSampleByMessage: [UUID: TokenCalibrationSample] = [:]
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
    /// Whether a substantial-looking draft gets the one-time offer of
    /// planning mode. On by default; the offer itself is capped at once
    /// per conversation, and this switch turns the heuristic off for
    /// people who would rather decide for themselves every time.
    var isPlanningSuggestionEnabled = true {
        didSet { Defaults.set(isPlanningSuggestionEnabled, DefaultsKey.planningSuggestion) }
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
        /// The attached folder that may remember a prefix rule for this
        /// command, or nil for a sandbox workspace — which is also how the
        /// card knows whether to offer the "Always allow …" button at all.
        var trustFolderPath: String? = nil
        let decide: @Sendable (Decision) -> Void

        enum Decision: Sendable {
            case approveOnce(String)
            case approveAlways(String)
            case approveAll(String)
            /// Approve, and remember `rule` as a prefix rule for this
            /// conversation's attached folder — across relaunches, unlike
            /// every other case here.
            case approveRule(command: String, rule: String)
            case deny
        }
    }
    var pendingApproval: CommandApproval?

    /// A question the model asked through the real `ask_user` tool, holding
    /// the generation open until it's answered.
    ///
    /// The fenced ```ask-user block can't do this: it ends the turn, and the
    /// answer arrives as a whole new user message. A tool call pauses
    /// mid-reply exactly the way `CommandApproval` does, so the model can
    /// ask and then keep working in the same turn.
    struct PendingQuestion: Identifiable {
        let id = UUID()
        let conversationID: UUID
        let payload: AskUserQuestionPayload
        /// The composed answer text, or nil if the user dismissed without
        /// answering — the model is told so rather than left waiting.
        let respond: @Sendable (String?) -> Void
    }
    var pendingQuestion: PendingQuestion?
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
    ///
    /// `.cannotFindHost` and `.dnsLookupFailed` are deliberately NOT
    /// retryable, even though they're `URLError`s like the others: both
    /// mean the endpoint's hostname doesn't resolve at all — a typo'd or
    /// dead base URL — which is a configuration error, not a blip. It will
    /// fail identically every time, so retrying it just spends the whole
    /// backoff budget (~4s, see `Limits.transientRetry*`) before reporting
    /// what was already knowable on the first attempt. `.cannotConnectToHost`
    /// stays retryable because DNS resolved fine there — the host exists but
    /// refused the connection, which a service mid-restart can recover from.
    nonisolated static func isTransientFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .dataNotAllowed, .secureConnectionFailed:
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
    var sendStartedAt: [UUID: Date] = [:]
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
    let historyKey = DefaultsKey.conversations
    let historyBackupKey = DefaultsKey.conversations + ".backup"
    private var didStart = false
    var pendingDiscoverySends: Set<UUID> = []
    var compactingConversationIDs: Set<UUID> = []

    /// Decouples the on-screen reveal pace from provider chunk size: network
    /// events land in an ordered per-message op queue (text, reasoning,
    /// activity lines) and a task drains them in order — text a word at a
    /// time, activities in place — so replies feel like a smooth typewriter
    /// and the timeline order always matches what actually happened.
    var revealQueues: [UUID: [RevealOp]] = [:]
    var revealTasks: [UUID: Task<Void, Never>] = [:]
    /// Messages whose stream has ended but whose reveal queue is still
    /// draining — finish work (isStreaming flip, save, notify) runs when
    /// the drain empties instead of snapping the buffer in one frame.
    var pendingFinish: Set<UUID> = []
    var historySaveTask: Task<Void, Never>?
    /// When streamed text was last persisted. A reply used to be written to
    /// history only at send, at stop, and at completion — never while it was
    /// arriving — so a hard quit thirty seconds into a long answer lost the
    /// whole thing and `reconcileInterruptedMessages` stamped it
    /// "Interrupted before finishing" over an empty message. Throttled
    /// rather than saved per chunk: `writeHistoryNow` encodes every
    /// conversation, which is far too much work to do per token.
    var lastStreamingPersist: Date = .distantPast

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
        // Swift does not run property observers for assignments made
        // inside an initializer, so the mirror into `EgressPolicy` is done
        // explicitly here. Getting this wrong would leave the gate open for
        // the whole launch despite the switch reading as on.
        isLocalOnlyMode = Defaults.bool(DefaultsKey.localOnlyMode, default: false)
        EgressPolicy.isLocalOnly = isLocalOnlyMode
        restoreQuotaSnapshots()
        isAgentToolsEnabled = Defaults.bool(DefaultsKey.agentToolsEnabled, default: isAgentToolsEnabled)
        isCommandToolEnabled = Defaults.bool(DefaultsKey.commandToolEnabled, default: false)
        isPlanningSuggestionEnabled = Defaults.bool(DefaultsKey.planningSuggestion, default: true)
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

    /// What the next turn would cost to send, from the composer, before
    /// hitting Send.
    ///
    /// This is an ESTIMATE and is labelled as one everywhere it appears —
    /// the token count is derived from characters, not from the provider's
    /// tokenizer, and the reply's length is unknowable in advance. It
    /// therefore prices *input only*, and returns `nil` unless the model's
    /// real input price is known. Never presented as an observed figure
    /// (house rule: unobserved numbers are never implied).
    var estimatedNextTurnInputCostUSD: Double? {
        guard let model = selectedModelInfo,
              let inputPrice = model.inputPricePerMillion,
              inputPrice > 0 else { return nil }
        let tokens = contextTokenEstimate + tokenEstimate(forDraft: activeConversation?.draftText ?? "")
        guard tokens > 0 else { return nil }
        return Double(tokens) * inputPrice / 1_000_000
    }

    /// Token count for text not yet in the transcript — the same
    /// calibrated ratio the context readout uses, so the composer's
    /// "about to send" number and the ring can't disagree with each other.
    private func tokenEstimate(forDraft text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return TokenCalibration.tokens(
            units: TokenCalibration.units(of: text),
            charactersPerToken: charactersPerToken(providerID: selectedProvider?.id, model: currentModelID)
        )
    }

    /// The fitted ratio for a provider+model, or `TokenCalibration`'s
    /// fallback while that pair is still under-sampled.
    private func charactersPerToken(providerID: UUID?, model: String) -> Double {
        guard let providerID, !model.isEmpty else { return TokenCalibration.fallbackCharactersPerToken }
        return tokenCalibration.charactersPerToken(for: ProviderStore.modelKey(providerID, model))
    }

    /// Bytes every request carries that aren't transcript — the composed
    /// system prompt and the tool schemas — as last observed for this
    /// provider+model. Zero until a reply has been sent, so an unknown
    /// overhead adds nothing rather than being guessed at.
    private func overheadUnits(providerID: UUID?, model: String) -> Int {
        guard let providerID, !model.isEmpty else { return 0 }
        return tokenCalibration.overheadUnits(for: ProviderStore.modelKey(providerID, model))
    }

    /// True once the active model's estimate is a measurement rather than
    /// the flat fallback. Surfaced in the context popover so the two cases
    /// aren't presented as if they were the same thing.
    var contextEstimateIsCalibrated: Bool {
        guard let provider = selectedProvider, !currentModelID.isEmpty else { return false }
        return tokenCalibration.isCalibrated(for: ProviderStore.modelKey(provider.id, currentModelID))
    }

    /// Counts only what would actually be sent on the next request — after
    /// a compaction, that's the summary plus whatever came after it, not the
    /// full raw transcript (which never shrinks, since nothing is deleted).
    /// Without this, the context readout — and the auto-compact trigger
    /// below, which reads the same number — would stay pinned near "full"
    /// forever after compacting, since the visible transcript itself never
    /// gets smaller.
    ///
    /// Two corrections on top of the old `bytes / 4`: the divisor is the
    /// ratio fitted from this model's own reported `prompt_tokens`, and the
    /// last observed system-prompt-plus-tools overhead is added in. Every
    /// request really does carry that overhead, so leaving it out made the
    /// readout short by a fixed few thousand tokens on every single turn —
    /// in the unsafe direction, since it is the number auto-compaction
    /// compares against the window.
    ///
    /// Deliberately a plain synchronous function: it is read during view
    /// rendering, so it may not await anything or touch the network.
    func tokenEstimate(for conversation: Conversation) -> Int {
        let ratio = charactersPerToken(providerID: conversation.providerID, model: conversation.model)
        let transcript = transcriptUnits(for: conversation)
        let overhead = overheadUnits(providerID: conversation.providerID, model: conversation.model)
        return TokenCalibration.tokens(units: transcript.units + overhead, charactersPerToken: ratio)
            + transcript.attachmentTokens
    }

    /// UTF-8 bytes of the transcript a request would carry, and the
    /// attachment tokens alongside it (already counted in tokens, not
    /// bytes, by `Attachment.estimatedTokens`).
    ///
    /// Split out because the calibration hook needs exactly this number:
    /// the difference between it and the bytes actually sent is the
    /// system-prompt-plus-tool-schema overhead the readout otherwise
    /// misses on every turn.
    func transcriptUnits(for conversation: Conversation) -> (units: Int, attachmentTokens: Int) {
        let messages: [ChatMessage]
        if let boundary = conversation.lastCompactionIndex {
            messages = Array(conversation.messages[boundary...])
        } else {
            messages = conversation.messages
        }
        var units = 0
        var attachmentTokens = 0
        for message in messages {
            // Notices and other local-only cards are never sent, so they
            // must not inflate the readout or trip auto-compaction early.
            // The compaction-summary system message IS sent, and stays
            // counted because it is not synthetic.
            guard !message.isSynthetic else { continue }
            units += max(1, TokenCalibration.units(of: message.content))
            attachmentTokens += message.attachments.filter(\.isIncluded).reduce(0) { $0 + $1.estimatedTokens }
        }
        return (units, attachmentTokens)
    }

    /// The active model's context window and where the number came from.
    /// Precedence is documented once, in `ContextWindowResolver` — this is
    /// only the wiring that hands it the four candidates.
    var resolvedContextWindow: ContextWindowResolver.Resolved? {
        guard let provider = selectedProvider, !currentModelID.isEmpty else { return nil }
        return ContextWindowResolver.resolve(
            manual: providers.contextWindowOverride(providerID: provider.id, model: currentModelID),
            learned: providers.learnedContextWindow(providerID: provider.id, model: currentModelID),
            catalog: selectedModelInfo?.contextLength,
            modelID: currentModelID
        )
    }

    var contextWindow: Int? { resolvedContextWindow?.value }

    /// Where the displayed window came from, so a curated guess is never
    /// shown as though the provider had published it.
    var contextWindowSource: ContextWindowSource? { resolvedContextWindow?.source }

    func contextWindow(for conversation: Conversation) -> Int? {
        guard let providerID = conversation.providerID, !conversation.model.isEmpty else { return nil }
        return ContextWindowResolver.resolve(
            manual: providers.contextWindowOverride(providerID: providerID, model: conversation.model),
            learned: providers.learnedContextWindow(providerID: providerID, model: conversation.model),
            catalog: providers.modelInfo(for: providerID, model: conversation.model)?.contextLength,
            modelID: conversation.model
        )?.value
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
        // Recent conversations become searchable within seconds; older
        // ones fill in behind them without competing with the interface.
        memoryIndexer.startBackfill(conversations: conversations)
        // Facts have one home now. `LegacyMemoryMigration` moves the old
        // `velachat.memories` array into the store, verifies every fact
        // landed, and only then deletes it; a failure leaves the legacy
        // copy intact to retry next launch. Either way the UI mirror is
        // loaded from the store afterwards.
        Task {
            await LegacyMemoryMigration.run(store: .shared, defaults: .standard)
            await refreshFacts()
        }
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

    func isPristine(_ conversation: Conversation) -> Bool {
        conversation.realMessages.isEmpty
            && !conversation.isPinned
            && !conversation.titleIsCustom
            && conversation.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && conversation.draftAttachments.isEmpty
            && conversation.messages.isEmpty
    }

    /// Moves the pending chat into the sidebar list — the row springs in.
    @discardableResult
    func promotePending() -> Conversation? {
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
    func ensureListed(_ conversation: Conversation) {
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
        calibrationSampleByMessage.removeAll()
        tokenCalibration.reset()
        searchByMessage.removeAll()
        facts.removeAll()
        Task { await MemoryStore.shared.deleteEverything() }
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
    func pruneUnusedConversations() {
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
    func generateInstantTitle(for conversation: Conversation, userText: String, profile: ProviderProfile) {
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

    func generateTitleIfNeeded(for conversation: Conversation, profile: ProviderProfile, model: String, credential: ProviderCredential, force: Bool = false) {
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

    /// Re-reads the fact list out of the store. Every mutation below ends
    /// here, so the list on screen is always what retrieval will actually
    /// search rather than a hopeful local copy of it.
    func refreshFacts() async {
        let stored = await MemoryStore.shared.allFacts()
        let mapped = stored.map {
            MemoryItem(id: $0.id, content: $0.content, createdAt: $0.createdAt, topic: $0.topic)
        }
        withAnimation(.easeOut(duration: 0.18)) {
            facts = mapped
        }
    }

    /// Settings' "Add a memory" field. Goes through the same `write` the
    /// model's `save_memory` ends at, so a hand-typed fact is normalized
    /// ("i like tea" → "User likes tea") and deduped like any other —
    /// but *not* filtered by `MemoryCapture`, because a person writing
    /// their own fact is not the over-saving problem those rules exist for.
    func addMemory(_ content: String) {
        Task {
            await MemoryStore.shared.write(content: content, topic: nil, sourceConversationID: nil)
            await refreshFacts()
        }
    }

    func updateMemory(_ memory: MemoryItem, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != memory.content else { return }
        Task {
            await MemoryStore.shared.updateFact(id: memory.id, content: trimmed, topic: nil)
            await refreshFacts()
        }
    }

    func removeMemory(_ memory: MemoryItem) {
        Task {
            await MemoryStore.shared.deleteFact(id: memory.id)
            await refreshFacts()
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

    /// Per-provider memory switch: personal facts and past-conversation
    /// excerpts should not reach a provider the user hasn't chosen to
    /// trust with them. Local providers are allowed by default because
    /// nothing leaves the Mac.
    func isMemoryAllowed(for profile: ProviderProfile) -> Bool {
        Defaults.bool(DefaultsKey.memoryAllowedPrefix + profile.id.uuidString, default: true)
    }

    func setMemoryAllowed(_ allowed: Bool, for profile: ProviderProfile) {
        Defaults.set(allowed, DefaultsKey.memoryAllowedPrefix + profile.id.uuidString)
    }

    /// Jump to the conversation a recalled excerpt came from.
    func openConversation(id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            postNotice("That conversation has since been deleted.")
            return
        }
        selectConversation(conversation)
    }

    /// "Don't use this again": a fact is deleted outright, and a recalled
    /// message stops being indexed, so the correction actually sticks
    /// rather than only hiding the row.
    func forgetRecall(_ recall: MemoryRecall) {
        switch recall.origin {
        case .fact(let id):
            Task {
                await MemoryStore.shared.deleteFact(id: id)
                await refreshFacts()
            }
        case .conversation(_, let messageID):
            Task { await MemoryStore.shared.forgetMessage(messageID) }
        }
        for (messageID, recalls) in recallByMessage {
            recallByMessage[messageID] = recalls.filter { $0.id != recall.id }
        }
    }

    func relevantMemoryText(for conversation: Conversation) -> String {
        let selection: [MemoryItem]
        var omitted = 0
        if facts.count <= 15 {
            selection = facts
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
            let ranked = facts
                .map { (memory: $0, score: score($0)) }
                .sorted { ($0.score, $0.memory.createdAt.timeIntervalSince1970) > ($1.score, $1.memory.createdAt.timeIntervalSince1970) }
            let matched = ranked.filter { $0.score > 0 }.prefix(12).map(\.memory)
            // Nothing matched (fresh conversation): fall back to recency.
            selection = matched.isEmpty
                ? Array(facts.sorted { $0.createdAt > $1.createdAt }.prefix(12))
                : matched
            omitted = facts.count - selection.count
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

    /// The memory tools' entry point. Every mutation lands in
    /// `MemoryStore` — the only place facts live — and `refreshFacts`
    /// brings the change back to Settings immediately.
    ///
    /// The save result is deliberately more than "Saved.": the model needs
    /// to learn what memory actually did with what it sent. A refusal
    /// names the rule it broke, a merge says a duplicate was folded in
    /// rather than added, and a save echoes the normalized text so the
    /// model can see that "i prefer tea" was stored as "User prefers tea"
    /// instead of saving it again in a different voice.
    func applyMemoryMutation(_ mutation: ToolCatalog.MemoryMutation) async -> String {
        switch mutation {
        case .save(let content, let topic):
            let cleanTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome = await MemoryStore.shared.capture(
                content: content,
                topic: (cleanTopic?.isEmpty ?? true) ? nil : cleanTopic,
                sourceConversationID: activeConversation?.id
            )
            await refreshFacts()
            switch outcome {
            case .saved(let stored):
                return "Saved: \(stored)"
            case .merged(let stored):
                return "A near-identical memory already existed, so it was updated in place rather than duplicated: \(stored)"
            case .rejected(let reason):
                return reason
            }
        case .update(let id, let content, let topic):
            guard facts.contains(where: { $0.id == id }) else {
                return "Error: no memory with that id — use search_memory to find the right one."
            }
            let cleanTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
            await MemoryStore.shared.updateFact(
                id: id,
                content: content,
                topic: (cleanTopic?.isEmpty ?? true) ? nil : cleanTopic
            )
            await refreshFacts()
            return "Updated."
        case .delete(let id):
            guard facts.contains(where: { $0.id == id }) else {
                return "Error: no memory with that id — use search_memory to find the right one."
            }
            await MemoryStore.shared.deleteFact(id: id)
            await refreshFacts()
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
    func pruneAttachmentBlobs() {
        let live = Set(conversations.flatMap { $0.messages.flatMap { $0.attachments.map(\.id) } })
        AttachmentStore.pruneOrphans(keeping: live)
    }

    /// Everything keyed by message ID that isn't part of the message
    /// itself. These accumulated silently: each new feature added another
    /// dictionary, and only the two oldest were ever cleaned up, so
    /// deleting conversations leaked entries for the rest of the session.
    func discardTransientState(for messages: [ChatMessage]) {
        let ids = Set(messages.map(\.id))
        usageByMessage = usageByMessage.filter { !ids.contains($0.key) }
        calibrationSampleByMessage = calibrationSampleByMessage.filter { !ids.contains($0.key) }
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
        memoryIndexer.forget(conversationID: conversation.id)
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
        calibrationSampleByMessage.removeAll()
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



    /// Attaches a real folder to the active conversation as its workspace
    /// root. A visible notice records it — the user should always know
    /// which directory the assistant is working in.
    func setWorkspaceRoot(_ url: URL) {
        let conversation = activeConversation ?? newConversation()
        conversation.workspaceRootPath = url.path
        postNotice("Workspace set to \(url.path). File tools and commands run here.", to: conversation)
        saveHistory()
    }

    /// Writes a chat code block into the active conversation's workspace,
    /// returning the filename actually used. Never overwrites: a repeated
    /// save gets its own file rather than silently replacing the last one.
    @discardableResult
    func saveSnippetToWorkspace(_ content: String, filename: String) -> String? {
        let conversation = activeConversation ?? newConversation()
        let root = conversation.workspaceRoot
        var name = filename
        var attempt = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            let base = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            name = ext.isEmpty ? "\(base)-\(attempt)" : "\(base)-\(attempt).\(ext)"
            attempt += 1
        }
        guard let url = SandboxManager.resolve(name, in: root) else { return nil }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return name
        } catch {
            postNotice("Couldn't save that snippet: \(error.localizedDescription)", to: conversation)
            return nil
        }
    }

    func clearWorkspaceRoot(for conversation: Conversation) {
        conversation.workspaceRootPath = nil
        saveHistory()
    }

    /// Whether `run_command` goes on the wire for this conversation.
    ///
    /// The Settings switch is the user's explicit answer and always wins,
    /// in either direction. Untouched, the default depends on where the
    /// commands would run: attaching a real project folder is already the
    /// user saying "work in here", and a chat with a checkout attached and
    /// no way to run its build is the state that produced the actual
    /// complaint this addresses ("I can't invoke rustc, cargo build, or
    /// cargo test from this chat"). With only the synthetic per-conversation
    /// sandbox, shell execution stays off.
    func isCommandToolAvailable(for conversation: Conversation) -> Bool {
        if Defaults.has(DefaultsKey.commandToolEnabled) { return isCommandToolEnabled }
        return conversation.commandTrustFolderPath != nil
    }

    /// Whether the active conversation is planning — what the menu item,
    /// the composer chip, and the shortcut all read.
    var isPlanningActive: Bool { activeConversation?.isPlanning ?? false }

    /// Turns planning mode on or off, with a visible notice: which tools a
    /// reply had is not something the user should have to infer from the
    /// model's behaviour.
    func setPlanning(_ planning: Bool, for conversation: Conversation) {
        guard conversation.isPlanning != planning else { return }
        conversation.isPlanning = planning
        // Answering the question either way retires the offer — it exists
        // to introduce the mode, not to keep asking about it.
        conversation.didOfferPlanning = true
        if planning {
            postNotice("Planning mode on — this chat can read, search, and run read-only commands, but cannot write files, change memory, or run anything else until you approve a plan.", kind: "info", to: conversation)
        } else {
            postNotice("Planning mode off — file edits, memory writes, and approved commands are available again.", kind: "info", to: conversation)
        }
        saveHistory()
    }

    func togglePlanningMode() {
        let conversation = activeConversation ?? newConversation()
        setPlanning(!conversation.isPlanning, for: conversation)
    }

    /// Whether to show the one-time planning offer above the composer for
    /// what is currently typed. Cheap enough to ask on every keystroke.
    func shouldOfferPlanning(for conversation: Conversation, draft: String) -> Bool {
        guard isPlanningSuggestionEnabled, !conversation.isPlanning, !conversation.didOfferPlanning else { return false }
        // Nothing to withhold means nothing to offer: with no file or
        // command tools attached, planning mode would change nothing about
        // what the model can do.
        guard isAgentToolsEnabled || isWorkspaceEnabled || isCommandToolAvailable(for: conversation) else { return false }
        return PlanMode.looksSubstantial(draft)
    }

    /// "Not now" on the offer — declining is an answer, so it never comes
    /// back for this conversation.
    func declinePlanningOffer(for conversation: Conversation) {
        conversation.didOfferPlanning = true
        saveHistory()
    }

    /// The user approved a posted plan. Planning mode ends, the withheld
    /// tools come back, and the plan is carried into a FRESH turn as a
    /// real user message rather than the tools quietly unlocking mid-reply
    /// — the transcript should say, in the user's own turn, what was
    /// approved and when.
    func approvePlan(_ steps: [ToolCatalog.PlanStep], for conversation: Conversation) {
        guard conversation.isPlanning, !conversation.isGenerating else { return }
        conversation.isPlanning = false
        saveHistory()
        let list = steps.map { "- \($0.step)" }.joined(separator: "\n")
        send("""
        Plan approved — carry it out now, in order:

        \(list)

        Report what you actually did as you go, and stop and ask if a step turns out to be wrong.
        """)
    }

    /// The user rejected a posted plan. The mode stays on (the point of
    /// rejecting is that the plan isn't right yet) and their feedback
    /// becomes the next message, so revision happens in the open.
    func rejectPlan(feedback: String, for conversation: Conversation) {
        guard conversation.isPlanning, !conversation.isGenerating else { return }
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send("Not that plan. \(trimmed)\n\nStay in planning mode: revise the plan and post it again with update_plan.")
    }

    /// One-shot latch for an approval card's answer (see `executeCommand`).
    final class DecisionGuard: @unchecked Sendable {
        var answered = false
    }

    /// run_command's gate. Read-only commands run immediately; everything
    /// else pauses the generation on a real approval card in the
    /// transcript. A denial goes back to the model as a normal tool
    /// result so it can adapt instead of failing.
    func executeCommand(_ command: String, in directory: URL, conversationID: UUID) async -> String {
        let conversation = conversations.first { $0.id == conversationID }
        // Planning mode is enforced here rather than by asking the model to
        // behave: it keeps `run_command` attached (exploration is most of
        // what a plan is made of) and refuses everything that isn't
        // read-only, whatever the user has previously trusted.
        if conversation?.isPlanning == true, let refusal = PlanMode.commandRefusal(for: command) {
            return refusal
        }
        let trustFolderPath = conversation?.commandTrustFolderPath
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
            // Rules remembered for the attached folder — the only trust
            // here that survives a relaunch, and never consulted for a
            // sandbox workspace (`trustFolderPath` is nil for one).
            if case .allowed = CommandTrust.decision(for: command, folderPath: trustFolderPath) {
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
                    reason: reason,
                    trustFolderPath: trustFolderPath
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
                // Remembered so a rule added later can never quietly
                // auto-approve the exact command they refused.
                CommandTrust.noteDenied(command, for: trustFolderPath)
                return "The user denied this command. Do not retry it — ask what they'd prefer, or take a different approach."
            case .approveOnce(let edited):
                approvedCommand = edited
            case .approveAlways(let edited):
                approvedCommand = edited
                conversation?.alwaysAllowedCommands.insert(edited)
            case .approveAll(let edited):
                approvedCommand = edited
                conversation?.allowAllCommands = true
            case .approveRule(let edited, let rule):
                approvedCommand = edited
                CommandTrust.allow(rule: rule, for: trustFolderPath)
            }
        }

        let output = await CommandRunner.run(approvedCommand, in: directory)
        return CommandRunner.formatted(output, command: approvedCommand)
    }





    /// One unit of buffered reveal work. Ops apply strictly in order, so an
    /// activity line can never appear before the text the model wrote ahead
    /// of the call has finished revealing — the timeline on screen always
    /// matches the order things actually happened.
    enum RevealOp {
        case text(String)
        case reasoning(String)
        case activity(ActivityRecord)
        /// `finishedAt` is stamped where the stream event arrived, not where
        /// this op is drained — the reveal queue is deliberately paced, so
        /// reading the clock at drain time would report the typewriter's
        /// backlog as the tool call's runtime.
        case activityUpdate(id: UUID, result: String, isError: Bool, finishedAt: Date)
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



    /// Debounced: encoding every conversation (attachments included) is
    /// megabytes of synchronous JSON work — doing it inline on every notice,
    /// pin, and finished reply stalled the main thread. Mutations mark dirty;
    /// the actual encode runs ~1s later, off the main thread. Destructive
    /// operations and app termination call `flushHistoryNow()` instead.
    func saveHistory() {
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

    func writeHistoryNow(synchronously: Bool = false) {
        let snapshots = conversations.map {
            SavedConversation(id: $0.id, title: $0.title, messages: $0.messages, providerID: $0.providerID, model: $0.model, createdAt: $0.createdAt, updatedAt: $0.updatedAt, draftText: $0.draftText, titleIsCustom: $0.titleIsCustom, isPinned: $0.isPinned, activeSkillPaths: $0.activeSkillPaths, workspaceRootPath: $0.workspaceRootPath, isPlanning: $0.isPlanning, didOfferPlanning: $0.didOfferPlanning)
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
            Conversation(id: $0.id, title: $0.title, messages: $0.messages, providerID: $0.providerID, model: $0.model, createdAt: $0.createdAt, updatedAt: $0.updatedAt, draftText: $0.draftText, titleIsCustom: $0.titleIsCustom, isPinned: $0.isPinned, activeSkillPaths: $0.activeSkillPaths, workspaceRootPath: $0.workspaceRootPath, isPlanning: $0.isPlanning, didOfferPlanning: $0.didOfferPlanning)
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
                if conversation.messages[index].error == nil {
                    // Partial text now survives a crash (see
                    // `persistStreamingProgress`), so this has two cases.
                    // A recovered fragment must still say it is a fragment:
                    // silently presenting a truncated answer as a finished
                    // one is worse than losing it, because nothing on
                    // screen distinguishes the two.
                    conversation.messages[index].error = conversation.messages[index].content.isEmpty
                        ? "Interrupted before finishing — the app closed or crashed."
                        : "Interrupted before finishing — the app closed or crashed. This reply is partial; use Continue Generating or Regenerate."
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
