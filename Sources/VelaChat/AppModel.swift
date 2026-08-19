import Foundation
import Observation
import SwiftUI
import AVFoundation
import AppKit
import UserNotifications

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
        You can ask the user a multiple-choice question when a real decision \
        or ambiguity is worth pausing on, instead of guessing which way to go. \
        To do this, reply with ONLY a fenced block in exactly this shape — \
        nothing before or after it:

        ```ask-user
        {"question": "Which approach should I take?", "options": [{"label": "Short option name", "description": "One-sentence explanation"}, {"label": "Another option", "description": "One-sentence explanation"}], "multiSelect": false, "allowNotes": true}
        ```

        `options` needs at least two entries. Set `"multiSelect": true` only \
        if picking more than one option at once genuinely makes sense. \
        `allowNotes` (default true) lets the user add a free-text note \
        alongside their pick — set it false only if a note wouldn't be useful. \
        The user's choice (and any note) comes back to you as their next \
        message. Use this sparingly, only for choices that actually matter — \
        never for routine replies.
        """

    /// Teaches the model it can propose remembering something durable —
    /// same fenced-block pattern as `askUserQuestionInstruction`. Nothing
    /// is ever stored automatically: the proposal renders as a card the
    /// user has to actually confirm (`MemoryProposalCard`, ChatView.swift).
    static let memoryInstruction = """
        You can propose remembering a durable fact about the user or their \
        projects — something worth knowing in every future conversation, \
        not just this one (a preference, a recurring project detail, \
        something they explicitly asked you to remember). To do this, \
        include a fenced block anywhere in your reply in exactly this shape:

        ```remember
        {"content": "The fact to remember, written as a short standalone sentence"}
        ```

        This never saves anything by itself — the user sees it as a card and \
        has to confirm it. Use this rarely, only for something genuinely \
        worth carrying forward, and only when it fits naturally in what \
        you're already saying — never as the sole content of a reply.
        """

    let providers = ProviderStore()
    let skills = SkillsStore()
    var promptSnippets: [PromptSnippet] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(promptSnippets) {
                UserDefaults.standard.set(data, forKey: "velachat.prompt-snippets")
            }
        }
    }
    /// Global, editable, included in every request — see `MemoryItem`.
    var memories: [MemoryItem] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(memories) {
                UserDefaults.standard.set(data, forKey: "velachat.memories")
            }
        }
    }
    var messageWidth: MessageWidthPreset = .comfortable {
        didSet { UserDefaults.standard.set(messageWidth.rawValue, forKey: "velachat.message-width") }
    }
    var density: DensityPreset = .comfortable {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "velachat.density") }
    }
    var section: Section = .chat
    var conversations: [Conversation] = []
    var activeConversationID: UUID?
    /// A transient, non-error status shown near the composer while it's
    /// true (e.g. "Finding a model…") — self-clears on success or failure.
    /// Real errors don't use this; they're posted into the transcript via
    /// `postNotice(_:to:)` instead, so they're never a banner that vanishes
    /// on its own and are always visible in the conversation itself.
    var statusMessage: String?
    var thinkingLevel: ThinkingLevel = .auto {
        didSet { UserDefaults.standard.set(thinkingLevel.rawValue, forKey: "velachat.thinking-level") }
    }
    var usageByMessage: [UUID: UsageSummary] = [:]
    var customInstructions: String = "" {
        didSet { UserDefaults.standard.set(customInstructions, forKey: "velachat.custom-instructions") }
    }
    var isCommandPaletteShown = false
    var speakingMessageID: UUID?
    var searchEndpoint: String = "" {
        didSet { UserDefaults.standard.set(searchEndpoint, forKey: "velachat.search-endpoint") }
    }
    /// Sticky like ChatGPT's search toggle — stays on across sends until the
    /// user turns it off, not a one-shot-per-message flag.
    var isWebSearchEnabled = false
    /// Gates the `write_file`/`read_file`/`list_workspace_files` tools —
    /// on by default since they're path-validated into a private,
    /// per-conversation, app-managed folder with no relationship to the
    /// user's real files unless explicitly written there by hand; a real
    /// shell-execution tool would be a materially different risk and isn't
    /// offered at all (see `SandboxManager`).
    var isWorkspaceEnabled = true {
        didSet { UserDefaults.standard.set(isWorkspaceEnabled, forKey: "velachat.workspace-enabled") }
    }
    var searchByMessage: [UUID: WebSearchRecord] = [:]
    var toolUsesByMessage: [UUID: [ToolUseRecord]] = [:]

    /// True when search is reachable at all: either the provider searches
    /// natively, or a SearXNG endpoint is configured and the model takes tools.
    var canUseWebSearch: Bool {
        guard let kind = selectedProvider?.kind else { return false }
        if !isNativeSearchNone(kind.nativeWebSearch) { return true }
        let hasEndpoint = !searchEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasEndpoint && (selectedModelInfo?.supportsTools ?? false)
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
    private let historyKey = "velachat.conversations"
    private let historyBackupKey = "velachat.conversations.backup"
    private var didStart = false
    private var pendingDiscoverySends: Set<UUID> = []
    private var compactingConversationIDs: Set<UUID> = []

    /// Decouples the on-screen reveal pace from provider chunk size: network
    /// tokens land in `pendingReveal` and a per-message task drains them a
    /// word at a time, so replies feel like a smooth typewriter regardless
    /// of whether the provider streams in tiny or huge chunks.
    private var pendingReveal: [UUID: String] = [:]
    private var revealTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        if let raw = UserDefaults.standard.string(forKey: "velachat.thinking-level"),
           let saved = ThinkingLevel(rawValue: raw) {
            thinkingLevel = saved
        }
        customInstructions = UserDefaults.standard.string(forKey: "velachat.custom-instructions") ?? ""
        searchEndpoint = UserDefaults.standard.string(forKey: "velachat.search-endpoint") ?? ""
        if let data = UserDefaults.standard.data(forKey: "velachat.prompt-snippets"),
           let saved = try? JSONDecoder().decode([PromptSnippet].self, from: data) {
            promptSnippets = saved
        }
        if let data = UserDefaults.standard.data(forKey: "velachat.memories"),
           let saved = try? JSONDecoder().decode([MemoryItem].self, from: data) {
            memories = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "velachat.message-width"),
           let saved = MessageWidthPreset(rawValue: raw) {
            messageWidth = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "velachat.density"),
           let saved = DensityPreset(rawValue: raw) {
            density = saved
        }
        if UserDefaults.standard.object(forKey: "velachat.workspace-enabled") != nil {
            isWorkspaceEnabled = UserDefaults.standard.bool(forKey: "velachat.workspace-enabled")
        }
        let corruptionNotice = restoreHistory()
        if conversations.isEmpty {
            _ = newConversation()
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
        return conversations.first { $0.id == activeConversationID }
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
        activeConversation?.model = model.id
        if !availableThinkingLevels.contains(thinkingLevel) {
            thinkingLevel = .auto
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        if let active = activeConversation, let providerID = active.providerID {
            providers.select(providerID, markExplicit: false)
        }
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
        if let existingEmpty = conversations.first(where: { $0.realMessages.isEmpty && !$0.isPinned }) {
            activeConversationID = existingEmpty.id
            return existingEmpty
        }
        let provider = providers.selected
        let conversation = Conversation(providerID: provider?.id, model: provider?.model ?? "")
        withAnimation(.easeOut(duration: 0.18)) {
            conversations.insert(conversation, at: 0)
        }
        activeConversationID = conversation.id
        saveHistory()
        return conversation
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
    func postNotice(_ message: String, to conversation: Conversation? = nil) -> ChatMessage {
        let target = conversation ?? activeConversation ?? newConversation()
        let notice = ChatMessage(role: "notice", content: message)
        target.messages.append(notice)
        target.updatedAt = Date()
        saveHistory()
        return notice
    }

    func selectConversation(_ conversation: Conversation) {
        activeConversationID = conversation.id
        if let providerID = conversation.providerID {
            providers.select(providerID)
        }
        if !availableThinkingLevels.contains(thinkingLevel) {
            thinkingLevel = .auto
        }
        section = .chat
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
        guard let profile = providers.selected, profile.kind != .preview else { return }
        guard conversation.messages.contains(where: { $0.role == "user" }),
              conversation.messages.contains(where: { $0.role == "assistant" }) else { return }
        conversation.titleIsCustom = false
        let model = conversation.model.isEmpty ? providers.effectiveModel(for: profile) : conversation.model
        let credential = providers.credential(for: profile)
        generateTitleIfNeeded(for: conversation, profile: profile, model: model, credential: credential, force: true)
    }

    /// Fires once, right after the very first exchange completes, using
    /// whatever model/provider the conversation is already on — no separate
    /// "titling model" configuration. Silent on failure: a truncated first
    /// message is a perfectly fine fallback title, never worth an error.
    private func generateTitleIfNeeded(for conversation: Conversation, profile: ProviderProfile, model: String, credential: ProviderCredential, force: Bool = false) {
        guard !conversation.titleIsCustom, (force || conversation.realMessages.count == 2), profile.kind != .preview else { return }
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
                let events = CompatibleChatClient.shared.streamChatEvents(
                    profile: profile,
                    credential: credential,
                    model: model,
                    thinking: .off,
                    messages: [ChatMessage(role: "user", content: prompt)]
                )
                for try await event in events {
                    if case .delta(let content, _) = event { titleText += content }
                }
            } catch {
                return
            }
            guard !conversation.titleIsCustom else { return }
            let cleaned = titleText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
            guard !cleaned.isEmpty, !Self.looksLikeBadTitle(cleaned) else { return }
            conversation.title = String(cleaned.prefix(60))
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

    /// Every memory gets injected on every request today — fine for a
    /// short list, but unbounded as it grows. Caps at the most-recent
    /// entries that fit a token budget instead of letting memory alone
    /// silently eat an ever-larger share of context on every single
    /// message. (A relevance-ranked subset would need embeddings, which
    /// this app doesn't have — recency is the honest fallback.)
    private func boundedMemoryText(maxCharacters: Int = 2_000) -> String {
        let sorted = memories.sorted { $0.createdAt > $1.createdAt }
        var lines: [String] = []
        var total = 0
        for memory in sorted {
            let line = "- \(memory.content)"
            guard total + line.count <= maxCharacters else { break }
            lines.append(line)
            total += line.count
        }
        if lines.count < memories.count {
            lines.append("(\(memories.count - lines.count) older memor\(memories.count - lines.count == 1 ? "y" : "ies") omitted to save context — see Settings → Memory for the full list.)")
        }
        return lines.joined(separator: "\n")
    }

    func togglePin(_ conversation: Conversation) {
        withAnimation(.easeOut(duration: 0.18)) {
            conversation.isPinned.toggle()
        }
        saveHistory()
    }

    func deleteConversation(_ conversation: Conversation) {
        if conversation.isGenerating {
            stopGeneration(for: conversation)
        }
        usageByMessage = usageByMessage.filter { key, _ in !conversation.messages.contains { $0.id == key } }
        searchByMessage = searchByMessage.filter { key, _ in !conversation.messages.contains { $0.id == key } }
        toolUsesByMessage = toolUsesByMessage.filter { key, _ in !conversation.messages.contains { $0.id == key } }
        withAnimation(.easeOut(duration: 0.18)) {
            conversations.removeAll { $0.id == conversation.id }
        }
        if activeConversationID == conversation.id {
            activeConversationID = conversations.first?.id ?? newConversation().id
        }
        saveHistory()
    }

    func clearHistory() {
        for conversation in conversations where conversation.isGenerating {
            stopGeneration(for: conversation)
        }
        conversations.removeAll()
        usageByMessage.removeAll()
        searchByMessage.removeAll()
        toolUsesByMessage.removeAll()
        _ = newConversation()
        saveHistory()
    }

    func send(_ rawText: String) {
        send(rawText, replacingReplyWith: nil, attachments: activeConversation?.draftAttachments ?? [])
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
        if message.role == "user",
           index + 1 < conversation.messages.count,
           conversation.messages[index + 1].role == "assistant" {
            conversation.messages.remove(at: index + 1)
        }
        conversation.messages.remove(at: index)
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
        conversation.messages.removeSubrange(index...)
        send(newContent, replacingReplyWith: priorReply)
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
        conversation.messages.removeSubrange((index - 1)...)
        send(priorUser.content, replacingReplyWith: priorReply)
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

    private func send(_ rawText: String, replacingReplyWith priorReply: ChatMessage?, attachments: [Attachment] = []) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard let profile = providers.selected else {
            postNotice("Choose a provider in Settings first.")
            section = .settings
            return
        }
        if profile.kind != .preview && !providers.hasDiscoveredModels(for: profile.id) {
            guard !pendingDiscoverySends.contains(profile.id) else { return }
            pendingDiscoverySends.insert(profile.id)
            statusMessage = "Finding a model…"
            Task { [weak self] in
                guard let self else { return }
                defer { self.pendingDiscoverySends.remove(profile.id) }
                _ = await self.providers.ensureReady(id: profile.id)
                if case .failed(let message) = self.providers.status(for: profile.id) {
                    self.statusMessage = nil
                    self.postNotice(message)
                    return
                }
                self.statusMessage = nil
                self.send(text, replacingReplyWith: priorReply, attachments: attachments)
            }
            return
        }
        let conversation = activeConversation ?? newConversation()
        guard !conversation.isGenerating else { return }
        if conversation.providerID != profile.id {
            conversation.providerID = profile.id
            conversation.model = profile.model
        }
        if conversation.model.isEmpty {
            conversation.model = providers.effectiveModel(for: profile)
        }
        if conversation.realMessages.isEmpty, !conversation.titleIsCustom {
            let titleSource = text.isEmpty ? (attachments.first?.filename ?? text) : text
            conversation.title = titleSource.count > 54 ? String(titleSource.prefix(54)) + "…" : titleSource
        }
        conversation.messages.append(ChatMessage(role: "user", content: text, attachments: attachments))
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
        conversation.draftText = ""
        conversation.draftAttachments = []
        conversation.generationProviderName = profile.name
        saveHistory()

        var requestMessages = requestHistory(for: conversation)
        let trimmedInstructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
            requestMessages.insert(ChatMessage(role: "system", content: trimmedInstructions), at: 0)
        }
        // Active skills' bodies become extra scoped context for the rest of
        // this conversation — the same shape custom instructions already
        // use, just per-conversation instead of global.
        for path in conversation.activeSkillPaths.reversed() {
            guard let skill = skills.skills.first(where: { $0.folderPath == path }) else { continue }
            requestMessages.insert(ChatMessage(role: "system", content: "Skill \"\(skill.name)\":\n\n\(skill.body)"), at: 0)
        }
        if !memories.isEmpty {
            requestMessages.insert(ChatMessage(role: "system", content: "Remembered facts about the user, true across every conversation:\n\(boundedMemoryText())"), at: 0)
        }
        requestMessages.insert(ChatMessage(role: "system", content: Self.memoryInstruction), at: 0)
        requestMessages.insert(ChatMessage(role: "system", content: Self.askUserQuestionInstruction), at: 0)
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
        let modelSupportsTools = modelInfo?.supportsTools ?? false
        // Real tool calling when the model actually supports it — the model
        // decides whether to search at all, rather than VelaChat always
        // pre-fetching before it even sees the prompt. `search_conversations`
        // is offered unconditionally (independent of the web-search
        // toggle) — that's the "let the AI search past conversations"
        // memory capability, not a web feature.
        var tools: [ToolCatalog.Definition] = []
        if modelSupportsTools {
            tools.append(ToolCatalog.searchConversations)
            if isWebSearchEnabled, !usesNativeSearch, !trimmedSearchEndpoint.isEmpty {
                tools.append(ToolCatalog.webSearch)
            }
            if isWorkspaceEnabled {
                tools.append(contentsOf: [ToolCatalog.writeFile, ToolCatalog.readFile, ToolCatalog.listWorkspaceFiles])
            }
        }
        let toolContext = ToolCatalog.ExecutionContext(
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
            workspaceDirectory: SandboxManager.directory(for: conversation.id)
        )
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
                if profile.kind == .preview {
                    try await PreviewResponder.stream(for: text, model: model) { [weak self, weak conversation] token in
                        guard let self, let conversation else { return }
                        self.append(token: token, reasoning: "", to: conversation, assistantID: assistantID)
                    }
                } else {
                    let events = CompatibleChatClient.shared.streamChatEvents(
                        profile: profile,
                        credential: credential,
                        model: wireModel,
                        thinking: thinking,
                        modelInfo: modelInfo,
                        messages: finalMessages,
                        tools: tools,
                        toolContext: tools.isEmpty ? nil : toolContext
                    )
                    var batch: [ChatStreamEvent] = []
                    for try await event in events {
                        batch.append(event)
                        if batch.count >= 8 {
                            self?.apply(batch, to: conversation, assistantID: assistantID)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty {
                        self?.apply(batch, to: conversation, assistantID: assistantID)
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

    func stopGeneration(for conversation: Conversation? = nil) {
        guard let conversation = conversation ?? activeConversation else { return }
        conversation.generationTask?.cancel()
        conversation.generationTask = nil
        if let index = conversation.messages.lastIndex(where: { $0.isStreaming }) {
            flushReveal(for: conversation.messages[index].id, conversation: conversation)
            conversation.messages[index].isStreaming = false
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
        conversation.messages.removeSubrange(lastUserIndex...)
        send(lastUser.content)
    }

    private func append(token: String, reasoning: String, to conversation: Conversation, assistantID: UUID) {
        guard conversation.messages.contains(where: { $0.id == assistantID }) else { return }
        if !token.isEmpty {
            pendingReveal[assistantID, default: ""] += token
            ensureRevealTask(for: assistantID, conversation: conversation)
        }
        if !reasoning.isEmpty, let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) {
            conversation.messages[index].reasoning = (conversation.messages[index].reasoning ?? "") + reasoning
        }
        conversation.updatedAt = Date()
    }

    private func ensureRevealTask(for assistantID: UUID, conversation: Conversation) {
        guard revealTasks[assistantID] == nil else { return }
        revealTasks[assistantID] = Task { [weak self, weak conversation] in
            while !Task.isCancelled {
                guard let self, let conversation else { return }
                guard var pending = self.pendingReveal[assistantID], !pending.isEmpty else {
                    self.revealTasks[assistantID] = nil
                    return
                }
                let chunk = Self.popNextWord(from: &pending)
                self.pendingReveal[assistantID] = pending
                guard let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) else {
                    self.revealTasks[assistantID] = nil
                    return
                }
                conversation.messages[index].content += chunk
                conversation.updatedAt = Date()
                try? await Task.sleep(nanoseconds: 28_000_000)
            }
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
        guard let remaining = pendingReveal.removeValue(forKey: assistantID), !remaining.isEmpty else { return }
        guard let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) else { return }
        conversation.messages[index].content += remaining
    }

    private func apply(_ event: ChatStreamEvent, to conversation: Conversation, assistantID: UUID) {
        apply([event], to: conversation, assistantID: assistantID)
    }

    private func apply(_ events: [ChatStreamEvent], to conversation: Conversation, assistantID: UUID) {
        var content = ""
        var reasoning = ""
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokens: Int?
        for event in events {
            switch event {
            case .delta(let nextContent, let nextReasoning):
                content += nextContent
                reasoning += nextReasoning
            case .usage(let prompt, let completion, let cached):
                promptTokens = prompt ?? promptTokens
                completionTokens = completion ?? completionTokens
                cachedTokens = cached ?? cachedTokens
            case .toolUse(let name, let query, let result):
                toolUsesByMessage[assistantID, default: []].append(ToolUseRecord(name: name, query: query, result: result))
            }
        }
        if !content.isEmpty || !reasoning.isEmpty {
            append(token: content, reasoning: reasoning, to: conversation, assistantID: assistantID)
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
        flushReveal(for: assistantID, conversation: conversation)
        if let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) {
            conversation.messages[index].isStreaming = false
        }
        conversation.isGenerating = false
        conversation.generationTask = nil
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

    /// Mirrors Claude Code's own auto-compact threshold (~83.5% of the
    /// context window) rather than a fixed token count, since context
    /// windows here range from small local models to million-token hosted
    /// ones. Only fires when the window is actually known.
    private func autoCompactIfNeeded(_ conversation: Conversation) {
        guard let window = contextWindow(for: conversation), window > 0 else { return }
        let used = tokenEstimate(for: conversation)
        guard Double(used) / Double(window) >= 0.835 else { return }
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
        guard let providerID = conversation.providerID, let profile = providers.profile(id: providerID), profile.kind != .preview else {
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
                let events = CompatibleChatClient.shared.streamChatEvents(
                    profile: profile,
                    credential: credential,
                    model: model,
                    thinking: .off,
                    messages: [ChatMessage(role: "user", content: prompt)]
                )
                for try await event in events {
                    if case .delta(let content, _) = event { summaryText += content }
                }
            } catch {
                if conversation.id == self.activeConversationID { self.statusMessage = nil }
                if !isAutomatic { self.postNotice("Couldn't compact this conversation: \(error.localizedDescription)", to: conversation) }
                return
            }
            if conversation.id == self.activeConversationID { self.statusMessage = nil }
            let cleaned = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            // The marker lands right after the last message the summary
            // actually covers — not the end of the whole span — so the
            // recency buffer (and any pinned messages) stay correctly on
            // the "not summarized" side of the boundary.
            guard let insertAfterIndex = conversation.messages.firstIndex(where: { $0.id == lastSummarizedID }) else { return }
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
        guard let providerID = conversation.providerID, let profile = providers.profile(id: providerID), profile.kind != .preview else {
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
                let events = CompatibleChatClient.shared.streamChatEvents(
                    profile: profile,
                    credential: credential,
                    model: model,
                    thinking: .off,
                    messages: [ChatMessage(role: "user", content: prompt)]
                )
                for try await event in events {
                    if case .delta(let content, _) = event { text += content }
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
            self.postNotice("Handoff document copied to clipboard.", to: conversation)
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
            conversation.messages[index].error = message
        }
        conversation.isGenerating = false
        conversation.generationTask = nil
        saveHistory()
    }

    private func saveHistory() {
        let snapshots = conversations.map {
            SavedConversation(id: $0.id, title: $0.title, messages: $0.messages, providerID: $0.providerID, model: $0.model, createdAt: $0.createdAt, updatedAt: $0.updatedAt, draftText: $0.draftText, titleIsCustom: $0.titleIsCustom, isPinned: $0.isPinned, activeSkillPaths: $0.activeSkillPaths)
        }
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: historyKey)
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
            Conversation(id: $0.id, title: $0.title, messages: $0.messages, providerID: $0.providerID, model: $0.model, createdAt: $0.createdAt, updatedAt: $0.updatedAt, draftText: $0.draftText, titleIsCustom: $0.titleIsCustom, isPinned: $0.isPinned, activeSkillPaths: $0.activeSkillPaths)
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
