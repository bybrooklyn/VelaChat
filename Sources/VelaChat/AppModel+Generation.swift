import Foundation
import VelaCore
import SwiftUI
import AppKit
import UserNotifications

/// Turning a user message into a streamed reply: the send path, the tool
/// loop's event handling, the paced reveal that puts text on screen, and
/// the completion/failure/compaction work around it.
///
/// Split out of AppModel.swift, which had grown past 2,700 lines. Same
/// type, same behaviour — the state these methods use lives with the
/// other stored properties in AppModel.swift.
@MainActor
extension AppModel {
    func send(_ rawText: String, replacingReplyWith priorReply: ChatMessage?, attachments: [Attachment] = [], restoring: (conversation: Conversation, messages: [ChatMessage])? = nil, clearDraftText: Bool = true) {
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
        // Redaction happens here, once, before anything can leave: the
        // title generator, the request payload, and the stored transcript
        // all use the redacted text. Storing the redacted form (rather than
        // the original plus a "don't send this" flag) means the transcript
        // never claims to have sent something it didn't, and a matched
        // credential is never written to disk at all.
        //
        // Attachment text is redacted in place for the same reason —
        // `contentForRequest` folds it into the outgoing message, so
        // redacting only the typed text would leave the larger hole open.
        let outbound = redaction.redactor.redact(text)
        var outboundAttachments = attachments
        var attachmentSpans: [RedactionSpan] = []
        if redaction.isEnabled {
            let redactor = redaction.redactor
            for index in outboundAttachments.indices where outboundAttachments[index].kind != .image {
                guard let original = outboundAttachments[index].textContent else { continue }
                let result = redactor.redact(original)
                guard result.didRedact, let encoded = result.text.data(using: .utf8) else { continue }
                outboundAttachments[index].data = encoded
                // Location is meaningless outside the message body, so it
                // is recorded as `notInMessageBody` — the chip row shows
                // which rules fired, which is the part that must be seen.
                attachmentSpans += result.spans.map {
                    RedactionSpan(ruleName: $0.ruleName, location: RedactionSpan.notInMessageBody, length: $0.length)
                }
            }
        }
        let outboundText = outbound.text
        let redactionSpans = outbound.spans + attachmentSpans

        let isFirstMessage = conversation.realMessages.isEmpty
        if isFirstMessage, !conversation.titleIsCustom {
            let titleSource = outboundText.isEmpty ? (outboundAttachments.first?.filename ?? outboundText) : outboundText
            conversation.title = titleSource.count > 54 ? String(titleSource.prefix(54)) + "…" : titleSource
            // A real title starts generating NOW, in parallel with the
            // reply, from the user's message alone — it typically lands in
            // the sidebar while the reply is still streaming.
            if isAutoTitleEnabled, !outboundText.isEmpty {
                generateInstantTitle(for: conversation, userText: outboundText, profile: profile)
            }
        }
        var userMessage = ChatMessage(role: "user", content: outboundText, attachments: outboundAttachments)
        userMessage.redactions = redactionSpans
        conversation.messages.append(userMessage)
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
                // Compaction-surviving notes ride the workspace too, but are
                // agent-only and never listed as a workspace file.
                tools.append(ToolCatalog.scratchpad)
                if conversation.projectWorkspace != nil {
                    tools.append(contentsOf: [ToolCatalog.gitStatus, ToolCatalog.gitDiff, ToolCatalog.gitLog])
                    if isAgentToolsEnabled {
                        tools.append(ToolCatalog.gitCommit)
                        tools.append(ToolCatalog.createPullRequest)
                    }
                }
            }
            // Also attached while planning even with the agent abilities
            // off: update_plan is how a plan gets posted, and the plan card
            // is the only way out of planning mode.
            if isAgentToolsEnabled || conversation.isPlanning {
                tools.append(ToolCatalog.updatePlan)
            }
            // Always available on a tool-capable model: asking is not an
            // "agent ability", it's how the model avoids guessing.
            tools.append(ToolCatalog.askUser)
            if isCommandToolAvailable(for: conversation) {
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
        // Planning mode, enforced. Not a line in the system prompt asking
        // the model to hold off: the tools that could change anything are
        // simply not on the wire, so there is nothing to ignore under
        // pressure and nothing to take on trust afterwards. Reads, search,
        // update_plan, ask_user and read-only run_command all survive the
        // filter — see `PlanMode`.
        if conversation.isPlanning {
            tools = PlanMode.filter(tools)
        }
        // System stack, top to bottom: the user's own instructions lead,
        // then durable memories and skills, then the app's tool inventory
        // and conventions — the user's words always outrank boilerplate.
        var systemMessages: [ChatMessage] = []
        let trimmedInstructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
            systemMessages.append(ChatMessage(role: "system", content: trimmedInstructions))
        }
        if !facts.isEmpty {
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
        // Security scope for an attached project folder, held for exactly
        // this turn: every workspace tool below may touch the folder, and
        // opening/closing per call would be churn. The holder stops access
        // when the generation closure exits (finish, fail, or cancel).
        let workspaceScope = WorkspaceScope.open(conversation.projectWorkspace)
        defer { workspaceScope.close() }
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
        // §6 write gate: an ATTACHED project folder confirms every file
        // write through the shared approval flow (reads stay free). The
        // app-owned sandbox keeps silent writes.
        if conversation.projectWorkspace != nil {
            toolContext.requiresWriteApproval = true
            let folderPath = conversation.projectWorkspace?.path ?? conversation.workspaceRoot.path
            toolContext.approveWrite = { [weak self] relativePath in
                guard let self else { return false }
                return await self.approveWorkspaceWrite(relativePath: relativePath, folderPath: folderPath, conversationID: conversation.id)
            }
        }
        if profile.kind == .claudeCode {
            let conversationID = conversation.id
            toolContext.claudePermission = { [weak self] toolName, summary, input in
                guard let self else { return false }
                return await self.approveClaudeTool(
                    toolName: toolName,
                    summary: summary,
                    input: input,
                    conversationID: conversationID
                )
            }
        }
        if conversation.projectWorkspace != nil {
            let folderPath = conversation.projectWorkspace?.path ?? conversation.workspaceRoot.path
            toolContext.approveGitWrite = { [weak self] summary, sensitive in
                guard let self else { return false }
                return await self.approveGitOperation(summary: summary, folderPath: folderPath, sensitive: sensitive, conversationID: conversation.id)
            }
        }
        toolContext.attachmentTexts = attachmentTexts
        toolContext.memory = ToolCatalog.MemoryAccess(
            snapshot: facts.map { ToolCatalog.MemorySnapshot(id: $0.id, content: $0.content, topic: $0.topic) },
            mutate: { [weak self] mutation in
                guard let self else { return "Error: memory is unavailable." }
                return await self.applyMemoryMutation(mutation)
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
        if isAgentToolsEnabled || conversation.isPlanning {
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
        if isCommandToolAvailable(for: conversation) {
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
        let askConversationID = conversation.id
        toolContext.askUser = { [weak self] payloadJSON in
            await self?.askUser(payloadJSON, conversationID: askConversationID)
                ?? "Error: the app is shutting down."
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
                // The resolved window, not just the catalog's — the prompt's
                // own budget maths (and what the model is told it has to work
                // with) should use the same number the ring shows, including
                // a learned or curated one.
                promptContext.contextWindow = self.contextWindow(for: conversation) ?? modelInfo?.contextLength
                promptContext.userFirstName = NSFullUserName().components(separatedBy: " ").first
                promptContext.workspaceFiles = (try? FileManager.default.contentsOfDirectory(atPath: conversation.workspaceRoot.path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
                promptContext.activeSkillNames = conversation.activeSkillPaths.compactMap { path in
                    self.skills.skills.first(where: { $0.folderPath == path })?.name
                }
                promptContext.hasAttachedFolder = conversation.workspaceRootPath != nil
                // Gated on tool support for the same reason every other
                // section is: a model with no tool calling has nothing
                // withheld from it, so telling it about a mode it cannot
                // participate in is pure confusion.
                promptContext.isPlanning = conversation.isPlanning && modelSupportsTools
                // `facts` replaced the old `memories` array — the legacy
                // store is gone, so this reads the mirror of MemoryStore.
                promptContext.memoryCount = self.facts.count
                promptContext.attachmentNames = conversation.realMessages.flatMap { $0.attachments.map(\.filename) }
            }
            // Past conversations that look relevant to what was just
            // asked. Retrieval is keyword-driven (see MemoryStore.recall),
            // so this stays silent when nothing genuinely matches rather
            // than padding every request with vaguely-related history.
            if let self, self.isMemoryAllowed(for: profile) {
                // The message alone is often not enough to retrieve on: a
                // follow-up like "what about the second one?" carries none
                // of the conversation's actual subject, so searching it
                // verbatim returned nothing. The last few turns supply that
                // subject, and `recall` weights them below the query's own
                // terms so context can only ever break a tie, never
                // outrank what the user actually just asked.
                let recentContext = conversation.realMessages
                    .suffix(4)
                    .map { String($0.content.prefix(500)) }
                    .joined(separator: "\n")
                let hits = await MemoryStore.shared.recall(
                    query: text,
                    context: recentContext,
                    excluding: conversation.id
                )
                let recalled = hits.map { hit -> MemoryRecall in
                    switch hit.source {
                    case .fact(let factID):
                        MemoryRecall(origin: .fact(factID), text: hit.text)
                    case .chunk(let conversationID, let messageID):
                        MemoryRecall(origin: .conversation(id: conversationID, messageID: messageID), text: hit.text)
                    }
                }
                if !recalled.isEmpty {
                    self.recallByMessage[assistantID] = recalled
                    // Facts are already in the prompt via relevantMemoryText;
                    // only the conversation excerpts need adding here.
                    // Excerpts are DATA: any tool-call syntax a past reply
                    // contained (raw ask-user fences, card JSON) is
                    // neutralized before injection, so retrieved history can
                    // never hand the model a template to parrot back as a
                    // live-looking artifact.
                    let excerpts = recalled
                        .filter { !$0.isFact }
                        .prefix(4)
                        .map { "- \(AskUserQuestionPayload.neutralizingToolCallSyntax(in: String($0.text.prefix(400))))" }
                        .joined(separator: "\n")
                    if !excerpts.isEmpty {
                        finalMessages.insert(ChatMessage(
                            role: "system",
                            content: "Possibly relevant excerpts from the user's earlier conversations (they cannot see these; use them if useful, ignore them if not):\n\(excerpts)"
                        ), at: min(composeInsertIndex, finalMessages.count))
                    }
                    await MemoryStore.shared.noteFactUsed(recalled.compactMap {
                        if case .fact(let id) = $0.origin { return id }
                        return nil
                    })
                }
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
                        // Set the moment the first retry is scheduled, so
                        // the whole retry sequence resolves through one
                        // note instead of the "one line per try" spam
                        // `noteRetrySummary` used to produce (and only on
                        // success — a provider that never recovers used to
                        // leave no trace of the retries at all).
                        var retryNoteID: UUID?
                        // Fires at most once per reply: if the provider
                        // 429s again after the window was supposed to have
                        // reset, the ordinary retry/error ladder takes over.
                        var queuedForWindowReset = false
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
                                // Ground truth for the token-ratio fit: the
                                // exact text this request carries, banked so
                                // `recordUsage` can divide it by the
                                // provider's own prompt_tokens once the reply
                                // lands. Only the first request of a reply is
                                // a valid sample — a continuation's usage
                                // covers two requests, and the tool loop's
                                // covers a round per hop.
                                if let self, continueCount == 0 {
                                    self.noteCalibrationSend(
                                        assistantID: assistantID,
                                        conversation: conversation,
                                        providerID: profile.id,
                                        model: model,
                                        messages: finalMessages,
                                        tools: tools
                                    )
                                }
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
                                if let self, let retryNoteID {
                                    self.resolveRetryNote(retryNoteID, isError: false, to: conversation, assistantID: assistantID)
                                }
                                break
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch where !deliveredEvents {
                                // Ladder, most specific first:
                                // 1. The subscription plan window ran out —
                                //    queue until the provider's own reset
                                //    moment (once), visibly.
                                // 2. Ordinary transient failure within the
                                //    retry budget — short backoff.
                                // 3. Anything else — surface for real.
                                if !queuedForWindowReset,
                                   let wait = Self.quotaWindowResetWait(for: error, quota: self?.quotaByProvider[profile.id]) {
                                    queuedForWindowReset = true
                                    let noteID = self?.postRetryNote(
                                        "Plan window exhausted — queued until it resets",
                                        to: conversation,
                                        assistantID: assistantID
                                    )
                                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                                    try Task.checkCancellation()
                                    if let self, let noteID {
                                        self.resolveRetryNote(noteID, isError: false, to: conversation, assistantID: assistantID)
                                    }
                                } else if attempt < Limits.maxTransientRetries, Self.isTransientFailure(error) {
                                    attempt += 1
                                    // Visible the instant the retry is
                                    // scheduled, not after it eventually works
                                    // — a blank bubble for the whole backoff is
                                    // exactly the "is this even doing anything"
                                    // complaint this exists to fix.
                                    if let self, retryNoteID == nil {
                                        retryNoteID = self.postRetryNote("Retrying after a connection failure", to: conversation, assistantID: assistantID)
                                    }
                                    let baseDelay = attempt == 1 ? Limits.transientRetryFirstDelay : Limits.transientRetryFollowupDelay
                                    let delay = baseDelay + Double.random(in: 0...Limits.transientRetryJitter)
                                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                                } else {
                                    // Retries exhausted (or the failure was never
                                    // retryable). This MUST reach the user as a
                                    // real error — a silently empty reply after
                                    // two invisible retries is the worst
                                    // possible outcome.
                                    if let self, let retryNoteID {
                                        self.resolveRetryNote(retryNoteID, isError: true, to: conversation, assistantID: assistantID)
                                    }
                                    throw attempt > 0
                                        ? APIError.message("\(error.localizedDescription) (after \(attempt) automatic \(attempt == 1 ? "retry" : "retries"))")
                                        : error
                                }
                            }
                        }
                        // Auto-continue: only on a provider-reported length
                        // cut, only with real partial text, at most twice.
                        guard let self,
                              self.finishReasonByMessage[assistantID] == "length",
                              continueCount < Limits.maxAutoContinues,
                              !streamedText.isEmpty else { break }
                        continueCount += 1
                        // Two requests now share one `prompt_tokens` total.
                        self.calibrationSampleByMessage.removeValue(forKey: assistantID)
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

    /// The §6 write gate's host side: one card per write in an attached
    /// folder until the user grants "all edits this chat" for that folder.
    /// Session-scoped on purpose — a relaunch re-asks, exactly like
    /// `allowAllCommands`.
    @MainActor
    func approveWorkspaceWrite(relativePath: String, folderPath: String, conversationID: UUID) async -> Bool {
        if workspaceWriteApprovals.contains(folderPath) { return true }
        let decision: CommandApproval.Decision = await withOneShotResume { resume in
            pendingApproval = CommandApproval(
                conversationID: conversationID,
                command: relativePath,
                directory: URL(fileURLWithPath: folderPath, isDirectory: true),
                reason: "The model wants to modify a file in your attached folder.",
                isFileWrite: true,
                decide: resume
            )
        }
        pendingApproval = nil
        switch decision {
        case .approveOnce:
            return true
        case .approveAll:
            workspaceWriteApprovals.insert(folderPath)
            return true
        case .deny:
            CommandTrust.noteDenied("file-write:\(relativePath)", for: folderPath)
            return false
        case .approveAlways, .approveRule:
            // Not offered by the file-write card; treat as one-shot.
            return true
        }
    }


    /// The `ask_user` tool's gate: decodes the payload, puts a real
    /// question card on screen, and suspends the tool call until the user
    /// answers. Mirrors `confirmSubagents` — both suspend on
    /// `withOneShotResume`, so a double-tap can never resume twice.
    ///
    /// A malformed payload comes back as a normal tool error rather than
    /// throwing: the model can then re-ask correctly instead of the whole
    /// reply dying on a bad question.
    func askUser(_ payloadJSON: String, conversationID: UUID) async -> String {
        guard let data = payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AskUserQuestionPayload.self, from: data),
              !payload.questions.isEmpty else {
            return "Error: the questions payload was malformed. Re-send it with 1-4 questions, each with at least 2 options."
        }
        let answer: String? = await withOneShotResume { resume in
            pendingQuestion = PendingQuestion(conversationID: conversationID, payload: payload, respond: resume)
        }
        pendingQuestion = nil
        guard let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "The user dismissed the question without answering. Continue with your best judgement and say which assumption you made."
        }
        return answer
    }

    /// Subagent fan-out confirmation — same pause-and-decide shape as a
    /// command approval, since it also spends real requests.
    func confirmSubagents(count: Int, summary: String, conversationID: UUID) async -> Bool {
        let decision: CommandApproval.Decision = await withOneShotResume { resume in
            pendingApproval = CommandApproval(
                conversationID: conversationID,
                command: "Run \(count) subagent\(count == 1 ? "" : "s") in parallel: \(summary)",
                directory: activeConversation?.workspaceRoot ?? SandboxManager.directory(for: conversationID),
                reason: "Each subagent is a separate request to your provider, and they run at the same time.",
                isSubagentRequest: true,
                decide: resume
            )
        }
        pendingApproval = nil
        if case .deny = decision { return false }
        return true
    }

    /// A quiet activity line for retry/offline waits — the same visual
    /// language as tool calls, per the no-invisible-magic rule.
    ///
    /// When `finish` is given (the offline-wait and length-cap-continue
    /// callers, which already know how their own wait ends) the note
    /// resolves immediately, same as before. When it's omitted (the
    /// transient-retry caller, which doesn't know the outcome yet when the
    /// note is posted) the caller resolves it later via `resolveRetryNote`
    /// — returning the id is what makes that possible.
    @discardableResult
    private func postRetryNote(_ label: String, to conversation: Conversation, assistantID: UUID, finish: String? = nil) -> UUID {
        var record = ActivityRecord(id: UUID(), kind: .note, toolName: "note", argument: label)
        record.isRunning = true
        record.startedAt = Date()
        enqueue(.activity(record), for: assistantID, conversation: conversation)
        if let finish {
            // Resolved in the same block it was posted: no duration was
            // observed, so none is stamped — a finishedAt here would
            // manufacture a "0.0s" label for an instantaneous note.
            enqueue(.activityUpdate(id: record.id, result: finish, isError: false, finishedAt: nil), for: assistantID, conversation: conversation)
        }
        return record.id
    }

    /// Resolves a note started by `postRetryNote(_:to:assistantID:)` once
    /// its real outcome is known. One line for the whole retry sequence —
    /// a reply that limped through two attempts reads as "this connection
    /// is flaky", not as a stack of per-attempt events — whether it
    /// eventually worked or the retries ran out and the failure is about
    /// to surface as a real error.
    private func resolveRetryNote(_ id: UUID, isError: Bool, to conversation: Conversation, assistantID: UUID) {
        let result = isError
            ? "Retries ran out — the failure is being reported instead."
            : "The provider or network failed before the reply started; VelaChat retried automatically."
        enqueue(.activityUpdate(id: id, result: result, isError: isError, finishedAt: Date()), for: assistantID, conversation: conversation)
    }

    /// Stop, and throw away what had arrived.
    ///
    /// The distinct counterpart to `stopGeneration`, which keeps the
    /// partial reply. Both are legitimate: a half-written answer worth
    /// continuing is the common case, but a reply that went wrong
    /// immediately is just clutter, and re-sending on top of it means
    /// deleting it by hand first.
    ///
    /// The user turn is deliberately left in place — discarding the reply
    /// should not also discard what was asked.
    func stopGenerationDiscardingPartial(for conversation: Conversation? = nil) {
        guard let conversation = conversation ?? activeConversation else { return }
        let assistantID = conversation.messages.last(where: { $0.isStreaming })?.id
        stopGeneration(for: conversation)
        guard let assistantID,
              let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) else { return }
        // Alternates hold superseded replies from an earlier edit or
        // regenerate. Dropping the message wholesale would take that
        // history with it, so an existing alternate is promoted back into
        // place instead of being lost.
        let discarded = conversation.messages[index]
        if let restored = discarded.alternates.first {
            var promoted = restored
            promoted.alternates = Array(discarded.alternates.dropFirst())
            conversation.messages[index] = promoted
        } else {
            conversation.messages.remove(at: index)
        }
        discardTransientState(for: [discarded])
        recallByMessage[assistantID] = nil
        conversation.updatedAt = Date()
        saveHistory()
    }

    /// Stops every background run — the background-runs surface's "Stop
    /// All". Same per-conversation path as a manual Stop (pending questions
    /// resolved, partial replies kept), just applied across the board.
    func stopAll() {
        for conversation in conversations where conversation.isGenerating {
            stopGeneration(for: conversation)
        }
    }

    func stopGeneration(for conversation: Conversation? = nil) {
        guard let conversation = conversation ?? activeConversation else { return }
        // An `ask_user` call suspends on a continuation that only the card
        // resumes. Cancelling the task does not touch it, so a Stop pressed
        // while a question is on screen would strand that continuation
        // forever — and leak the card. Resolve it as unanswered first.
        if let question = pendingQuestion, question.conversationID == conversation.id {
            question.respond(nil)
            pendingQuestion = nil
        }
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
            // Once `finishGeneration` defers to this loop (`pendingFinish`),
            // this loop *owns* the end-of-generation transition — and it had
            // three exits that returned without performing it: the message
            // going missing, the task being cancelled mid-sleep, and the
            // weak refs going away. Any of those left `isGenerating` true
            // forever, which is the send button staying a stop button after
            // the reply visibly finished. Resolving it in one `defer` means
            // every exit, including ones added later, settles the state.
            defer {
                if let self, self.pendingFinish.remove(assistantID) != nil {
                    self.revealTasks[assistantID] = nil
                    if let conversation {
                        self.completeGeneration(for: conversation, assistantID: assistantID)
                    }
                }
            }
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
                    // `defer` completes the generation — the reply is gone
                    // from the transcript, but the conversation must still
                    // stop reporting itself as generating.
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
                    conversation.messages[index].appendTimelineReasoning(chunk)
                    try? await Task.sleep(nanoseconds: 33_000_000)
                case .activity(let record):
                    queue.removeFirst()
                    self.revealQueues[assistantID] = queue
                    conversation.messages[index].appendActivity(record)
                case .activityUpdate(let id, let result, let isError, let finishedAt):
                    queue.removeFirst()
                    self.revealQueues[assistantID] = queue
                    conversation.messages[index].updateActivity(id: id, result: result, isError: isError, finishedAt: finishedAt)
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
            conversation.messages[index].appendTimelineReasoning(chunk)
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
                conversation.messages[index].appendTimelineReasoning(chunk)
            case .activity(let record):
                conversation.messages[index].appendActivity(record)
            case .activityUpdate(let id, let result, let isError, let finishedAt):
                conversation.messages[index].updateActivity(id: id, result: result, isError: isError, finishedAt: finishedAt)
            }
        }
        persistStreamingProgress()
    }

    /// Crash-safety for a reply that is still arriving. Partial text is
    /// written to history at most every `Limits.streamingPersistInterval`
    /// seconds, so a hard quit mid-stream keeps what had been received
    /// instead of discarding the turn.
    ///
    /// Throttled deliberately. `saveHistory()` already coalesces within its
    /// own one-second debounce, but the encode behind it walks every
    /// conversation — doing that once per revealed chunk would spend more
    /// time serializing than streaming.
    private func persistStreamingProgress() {
        let now = Date()
        guard now.timeIntervalSince(lastStreamingPersist) >= Limits.streamingPersistInterval else { return }
        lastStreamingPersist = now
        saveHistory()
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
        var cacheCreation: CacheCreationTokens?
        // Events enqueue in arrival order — deltas must NOT be merged across
        // an activity boundary, or the interleaving is lost.
        for event in events {
            switch event {
            case .delta(let content, let reasoning):
                if !content.isEmpty { enqueue(.text(content), for: assistantID, conversation: conversation) }
                if !reasoning.isEmpty { enqueue(.reasoning(reasoning), for: assistantID, conversation: conversation) }
            case .usage(let prompt, let completion, let cached, let creation):
                promptTokens = prompt ?? promptTokens
                completionTokens = completion ?? completionTokens
                cachedTokens = cached ?? cachedTokens
                cacheCreation = creation ?? cacheCreation
            case .finished(let reason):
                if let reason {
                    // Normalize the providers' truncation vocabulary.
                    let normalized = ["length", "max_tokens", "max_output_tokens"].contains(reason.lowercased()) ? "length" : reason
                    finishReasonByMessage[assistantID] = normalized
                }
            case .activityStarted(let id, let name, let argument):
                // A real tool call means this reply is several requests, and
                // `ToolLoopUsage` reports their SUM. Measured against the
                // single round's text that would fit a ratio a multiple too
                // small, so the sample is dropped rather than skewed. "note"
                // activities are the app's own status lines, not rounds.
                if name != "note" { calibrationSampleByMessage.removeValue(forKey: assistantID) }
                var record = ActivityRecord(id: id, kind: .from(toolName: name), toolName: name, argument: argument)
                record.isRunning = true
                record.startedAt = Date()
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
                enqueue(.activityUpdate(id: id, result: capped, isError: isError, finishedAt: Date()), for: assistantID, conversation: conversation)
            case .refusal(let text):
                // A provider refusal is not a crash and not content: it's a
                // decision. It lands as its own notice message so the
                // transcript shows an intentional typed row.
                postNotice(
                    "The provider declined this request:\n\n\(text)",
                    kind: "refusal",
                    to: conversation
                )
            }
        }
        if promptTokens != nil || completionTokens != nil {
            var summary = UsageSummary(promptTokens: promptTokens, completionTokens: completionTokens, cachedTokens: cachedTokens)
            summary.cacheCreation5mTokens = cacheCreation?.ephemeral5m
            summary.cacheCreation1hTokens = cacheCreation?.ephemeral1h
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
        // Always taken, never left behind: a reply that ends without usage
        // would otherwise leak its sample for the rest of the session.
        let calibration = calibrationSampleByMessage.removeValue(forKey: assistantID)
        guard let providerID = conversation.providerID,
              let message = conversation.messages.first(where: { $0.id == assistantID }),
              let summary = usageByMessage[assistantID] ?? message.usage else { return }
        let modelInfo = providers.modelInfo(for: providerID, model: message.modelID ?? conversation.model)
        usage.record(
            providerID: providerID,
            promptTokens: summary.promptTokens,
            completionTokens: summary.completionTokens,
            costUSD: summary.costUSD(for: modelInfo, providerKind: providers.profile(id: providerID)?.kind)
        )
        // The one place real tokenizer ground truth exists. Everything the
        // request carried, divided by what the provider says that cost.
        if let calibration, let promptTokens = summary.promptTokens {
            tokenCalibration.record(
                key: calibration.key,
                sentUnits: calibration.sentUnits,
                overheadUnits: calibration.overheadUnits,
                promptTokens: promptTokens
            )
        }
    }

    /// Banks what a request is about to carry, so the reply's reported
    /// `prompt_tokens` can be turned into a characters-per-token ratio.
    ///
    /// `sentUnits` is the whole request — system prompt, tool schemas,
    /// transcript — because `prompt_tokens` counts the whole request.
    /// Subtracting the transcript's own bytes leaves the per-turn overhead
    /// the context readout has no other way to see: the view layer never
    /// gets near a composed system prompt or an MCP tool schema.
    private func noteCalibrationSend(
        assistantID: UUID,
        conversation: Conversation,
        providerID: UUID,
        model: String,
        messages: [ChatMessage],
        tools: [ToolCatalog.Definition]
    ) {
        guard !model.isEmpty else { return }
        var sentUnits = messages.reduce(0) { $0 + TokenCalibration.units(of: $1.contentForRequest) }
        for tool in tools {
            sentUnits += TokenCalibration.units(of: tool.name)
                + TokenCalibration.units(of: tool.description)
                + TokenCalibration.units(of: tool.parametersJSON)
        }
        let transcriptUnits = transcriptUnits(for: conversation).units
        calibrationSampleByMessage[assistantID] = TokenCalibrationSample(
            key: ProviderStore.modelKey(providerID, model),
            sentUnits: sentUnits,
            overheadUnits: max(0, sentUnits - transcriptUnits)
        )
    }

    /// Providers state their real context window in the error they return
    /// when a request overruns it — "This model's maximum context length is
    /// 8192 tokens" and friends. That sentence is the only *observation* of
    /// an endpoint's true limit this app can ever make: a gateway, a proxy
    /// or a self-hosted server can all cap far below whatever the model is
    /// documented to support, and no catalog will say so.
    ///
    /// Recorded into its own store, never into the user's manual override —
    /// see `ContextWindowResolver` for why that separation is what makes the
    /// precedence expressible at all.
    private func learnContextWindow(from errorText: String, conversation: Conversation) {
        guard let providerID = conversation.providerID,
              !conversation.model.isEmpty,
              let window = ContextWindowLearning.contextLength(fromErrorText: errorText) else { return }
        providers.recordLearnedContextWindow(window, providerID: providerID, model: conversation.model)
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
        memoryIndexer.indexFinished(conversation: conversation, assistantID: assistantID)
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
        learnContextWindow(from: message, conversation: conversation)
        conversation.updatedAt = Date()
        // See the matching comment in `finishGeneration` — same race guard.
        if conversation.currentGenerationID == assistantID {
            conversation.isGenerating = false
            conversation.generationTask = nil
        }
        saveHistory()
    }
}
