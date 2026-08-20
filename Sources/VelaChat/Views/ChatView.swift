import SwiftUI
import HighlightSwift
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(WindowChrome.self) private var chrome
    @State private var lastScrollAt = Date.distantPast
    @State private var isDropTargeted = false
    @FocusState private var inputFocused: Bool
    @State private var isAttachMenuShown = false

    /// Content is capped wide enough to read comfortably without becoming the
    /// narrow column it used to be — the old 720pt cap wasted most of the
    /// window on any reasonably sized display.
    private var contentWidth: CGFloat { appModel.messageWidth.width }

    private var input: Binding<String> {
        Binding(
            get: { appModel.activeConversation?.draftText ?? "" },
            set: { appModel.activeConversation?.draftText = $0 }
        )
    }

    private var draftAttachments: Binding<[Attachment]> {
        Binding(
            get: { appModel.activeConversation?.draftAttachments ?? [] },
            set: { appModel.activeConversation?.draftAttachments = $0 }
        )
    }

    private let suggestions = [
        "Summarize this idea in three bullets",
        "Help me think through a hard decision",
        "Write a clean first draft"
    ]


    @Environment(ArtifactPresenter.self) private var artifactPresenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            mainContent
            if let artifact = artifactPresenter.activeArtifact {
                Divider()
                ArtifactPanel(artifact: artifact)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: artifactPresenter.activeArtifact?.id)
    }

    private var mainContent: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let conversation = appModel.activeConversation, !conversation.messages.isEmpty {
                        ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                            let grouped = index > 0
                                && conversation.messages[index - 1].role == message.role
                                && !message.isSynthetic
                                && !conversation.messages[index - 1].isSynthetic
                            MessageRow(
                                message: message,
                                isLastMessage: conversation.messages.last?.id == message.id,
                                isGroupedWithPrevious: grouped
                            )
                                .padding(.top, index == 0 ? 0 : (grouped ? 3 : appModel.density.messageSpacing))
                                .overlay {
                                    if appModel.chatFindHighlightID == message.id {
                                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                            .stroke(Theme.accent.opacity(0.55), lineWidth: 1.5)
                                            .padding(-4)
                                            .transition(.opacity)
                                    }
                                }
                                .animation(.easeOut(duration: 0.4), value: appModel.chatFindHighlightID)
                                .id(message.id)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    } else {
                        welcome
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("vela.bottom")
                }
                .padding(.horizontal, 34)
                .padding(.top, 20)
                .padding(.bottom, 26)
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity)
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: appModel.activeConversation?.messages.count ?? 0)
                // Replacing the stack per-conversation makes switching chats
                // a quiet crossfade instead of an instant swap.
                .id(appModel.activeConversationID)
                .animation(.easeOut(duration: 0.16), value: appModel.activeConversationID)
            }
            // Fullscreen has no titlebar clearance at all since the toolbar
            // removal — without this the first message clips under the
            // screen's top edge / menu-bar reveal strip.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: chrome.isFullScreen ? 32 : 0)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
            // macOS 26 draws an automatic blur band where scroll content
            // meets the titlebar. With a transparent titlebar and no
            // toolbar that reads as a stray frosted strip across the top,
            // so the transcript opts out of it explicitly.
            .scrollEdgeEffectHidden(true, for: .top)
            // …but opting out left nothing at all between scrolled text and
            // the traffic lights: a half-cut line of the reply rendered
            // straight through the window chrome. A short gradient in the
            // pane's own background colour is the middle ground — content
            // fades out before it reaches the lights, with none of the
            // frosted-strip edge that made the system effect look like a
            // stray toolbar.
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Theme.background, Theme.background.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: chrome.isFullScreen ? 0 : 34)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
            }
            .onChange(of: appModel.activeConversation?.messages.count ?? 0) { _, _ in
                scrollToLast(proxy)
            }
            .onChange(of: appModel.activeConversationID) { _, _ in
                // The artifact panel, find bar, and scroll position all
                // belonged to the previous conversation — carrying any of
                // them across a switch shows stale state.
                artifactPresenter.close()
                appModel.isChatFindShown = false
                appModel.chatFindHighlightID = nil
                scrollToLast(proxy, animated: false)
            }
            .onChange(of: appModel.activeConversation?.messages.last?.content.count ?? 0) { _, _ in
                let now = Date()
                // Matches the reveal cadence — 4x slower (the old 0.12s)
                // let text run off the bottom edge and then jump. Dropping a
                // tick here is worse than following it: the next accepted
                // one has twice as far to travel.
                guard now.timeIntervalSince(lastScrollAt) > 0.03 else { return }
                lastScrollAt = now
                followLast(proxy)
            }
            .overlay {
                if let approval = appModel.pendingApproval,
                   approval.conversationID == appModel.activeConversationID {
                    // Modal-feeling but in-place: the reply is genuinely
                    // paused behind this decision.
                    //
                    // The scrim stays here and *only* here. An approval
                    // blocks on a safety decision — something is about to
                    // run on the user's machine — so dimming the transcript
                    // to insist on an answer is proportionate. A question
                    // blocks on a preference, which is not an emergency and
                    // does not earn a darkened window.
                    ZStack {
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()
                        CommandApprovalCard(approval: approval)
                            .id(approval.id)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: appModel.pendingApproval?.id)
            // The question card's own animation moved down to the composer
            // with the card itself — see `pendingQuestionCard`.
            .overlay(alignment: .top) {
                if appModel.isChatFindShown, let conversation = appModel.activeConversation {
                    ChatFindBar(conversation: conversation, proxy: proxy)
                        // Fresh query/match state per conversation.
                        .id(conversation.id)
                        .padding(.top, chrome.isFullScreen ? 40 : 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: appModel.isChatFindShown)
            .overlay(alignment: .topTrailing) {
                if let conversation = appModel.activeConversation, !conversation.pinnedMessages.isEmpty {
                    PinnedMessagesButton(conversation: conversation, proxy: proxy)
                        .padding(.trailing, 16)
                        // Fullscreen has no titlebar clearance — same bump
                        // as the find bar, or the chip hugs the screen edge.
                        .padding(.top, chrome.isFullScreen ? 40 : 10)
                }
            }
        }
        .task { inputFocused = true }
    }


    private var welcome: some View {
        VStack(spacing: 14) {
            VelaMark(size: 52)
                .padding(.bottom, 3)
            Text("What are you working on?")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
            Text("Choose a model in the composer. Your provider and last model choice stay with you on this Mac.")
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 8) {
                ForEach(contextualSuggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        input.wrappedValue = suggestion
                        inputFocused = true
                    }
                    .buttonStyle(VelaControlButtonStyle(tint: Theme.secondaryText))
                }
            }
            .padding(.top, 5)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    /// Which prompt starters actually make sense depends on what the
    /// selected model is good at, not one fixed set of three chips
    /// regardless of what's chosen — research-flavored when search is live,
    /// harder problem-solving prompts for a reasoning-capable model, and a
    /// safe general-purpose fallback otherwise.
    private var contextualSuggestions: [String] {
        if appModel.isWebSearchEnabled && appModel.canUseWebSearch {
            return [
                "What's the latest on…",
                "Research and compare options for…",
                "Find current pricing for…"
            ]
        }
        if appModel.selectedModelInfo?.supportsReasoning == true {
            return [
                "Debug this tricky piece of logic",
                "Design a system for…",
                "Walk me through a hard tradeoff"
            ]
        }
        return suggestions
    }

    /// A "/" at the very start of the field opens the menu; anything typed
    /// after it (with no space yet) filters the list. A space means you've
    /// moved on to a real message that happens to start with "/".
    private var slashQuery: String? {
        let text = input.wrappedValue
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        guard !rest.contains(where: { $0.isWhitespace }) else { return nil }
        return String(rest).lowercased()
    }

    private func slashItems(for query: String) -> [SlashItem] {
        let builtins: [(String, String, () -> Void)] = [
            ("New Chat", "square.and.pencil", { _ = appModel.newConversation(); appModel.section = .chat }),
            ("Toggle Web Search", "globe", { appModel.isWebSearchEnabled.toggle() }),
            ("Compact Conversation", "arrow.down.right.and.arrow.up.left", {
                if let conversation = appModel.activeConversation { appModel.compactConversation(conversation) }
            }),
            ("Handoff Document", "arrow.turn.up.right", {
                if let conversation = appModel.activeConversation { appModel.generateHandoffDocument(for: conversation) }
            }),
            ("Settings", "slider.horizontal.3", { appModel.section = .settings })
        ]
        let matchingBuiltins = builtins
            .filter { query.isEmpty || $0.0.lowercased().contains(query) }
            .map { SlashItem.action(title: $0.0, symbol: $0.1, perform: $0.2) }
        let matchingSnippets = appModel.promptSnippets
            .filter { query.isEmpty || $0.name.lowercased().contains(query) }
            .map(SlashItem.snippet)
        let matchingSkills = appModel.skills.skills
            .filter { query.isEmpty || $0.name.lowercased().contains(query) }
            .map(SlashItem.skill)
        return matchingBuiltins + matchingSnippets + matchingSkills
    }

    private func selectSlashItem(_ item: SlashItem) {
        switch item {
        case .action(_, _, let perform):
            perform()
            input.wrappedValue = ""
        case .snippet(let snippet):
            input.wrappedValue = snippet.body
        case .skill(let skill):
            if let conversation = appModel.activeConversation {
                appModel.activateSkill(skill, for: conversation)
            }
            input.wrappedValue = ""
        }
        inputFocused = true
    }

    /// Skills activated on this conversation — their body is scoped context
    /// for every request from here on, so it's worth always showing which
    /// ones are on and offering a quick way to turn one back off.
    private func activeSkillsRow(_ conversation: Conversation) -> some View {
        HStack(spacing: 6) {
            ForEach(conversation.activeSkillPaths, id: \.self) { path in
                if let skill = appModel.skills.skills.first(where: { $0.folderPath == path }) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text(skill.name)
                            .font(.caption)
                        Button {
                            appModel.deactivateSkill(skill, for: conversation)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accentSoft.opacity(0.7), in: Capsule())
                    .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: contentWidth, alignment: .leading)
    }

    /// A blocked `ask_user` call, pinned just above the composer.
    ///
    /// It lives in the composer's own stack rather than as an overlay over
    /// the transcript for two reasons. It sits where the answer is about to
    /// be given instead of over the middle of the reply it interrupts, and
    /// — unlike an overlay anchored to the scroll view's bottom edge, which
    /// would land on top of the composer that `safeAreaInset` draws there —
    /// it can never cover the input.
    ///
    /// There is deliberately **no scrim**. A command approval keeps one
    /// because it blocks on a safety decision; a question blocks on a
    /// preference, which doesn't earn a darkened window. The shadow is the
    /// only chrome: `AskUserQuestionCard` already draws its own padding,
    /// surface, and accent stroke, and the container this used to sit in
    /// added a second padded, glassed, bordered one on top — a visible box
    /// inside a box.
    @ViewBuilder
    private var pendingQuestionCard: some View {
        if let question = appModel.pendingQuestion,
           question.conversationID == appModel.activeConversationID {
            AskUserQuestionCard(
                payload: question.payload,
                interactive: true,
                onAnswer: { question.respond($0) }
            )
            .frame(maxWidth: 560)
            .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
            .id(question.id)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .move(edge: .bottom))
            )
        }
    }

    /// The composer's planning-mode chip — same shape as the active-skills
    /// row, and the quickest way back out of the mode.
    private func planningRow(_ conversation: Conversation) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.caption2)
                Text("Planning — reads and read-only commands only")
                    .font(.caption)
                Button {
                    appModel.setPlanning(false, for: conversation)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Leave planning mode")
                .accessibilityLabel("Leave planning mode")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.accentSoft.opacity(0.7), in: Capsule())
            .foregroundStyle(Theme.accent)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: contentWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            pendingQuestionCard

            // Real errors render as cards in the transcript itself now
            // (`postNotice`/`role == "notice"` in `MessageRow`), not a
            // banner here — this is only ever a transient, self-clearing
            // status like "Finding a model…", never a failure.
            if let status = appModel.statusMessage {
                HStack(spacing: 6) {
                    ShimmerText(text: status, font: .caption)
                }
                .font(.caption)
                .frame(maxWidth: contentWidth, alignment: .leading)
                .transition(.opacity)
            }

            if !appModel.isOnline {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Offline — messages you send will go out when the connection returns")
                        .font(.caption)
                }
                .foregroundStyle(Theme.warning)
                .frame(maxWidth: contentWidth, alignment: .leading)
                .transition(.opacity)
            }

            if let conversation = appModel.activeConversation, !conversation.activeSkillPaths.isEmpty {
                activeSkillsRow(conversation)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // A mode that changes which tools the next reply gets must be
            // visible while you type into it, not only in the menu that
            // turned it on.
            if let conversation = appModel.activeConversation, conversation.isPlanning {
                planningRow(conversation)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let conversation = appModel.activeConversation,
               appModel.shouldOfferPlanning(for: conversation, draft: input.wrappedValue) {
                PlanModeSuggestionCard(
                    onAccept: { appModel.setPlanning(true, for: conversation) },
                    onDismiss: { appModel.declinePlanningOffer(for: conversation) }
                )
                .frame(maxWidth: contentWidth)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let query = slashQuery {
                let items = slashItems(for: query)
                if !items.isEmpty {
                    SlashCommandList(items: items, onSelect: selectSlashItem)
                        .frame(maxWidth: contentWidth)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if !draftAttachments.wrappedValue.isEmpty {
                    AttachmentChipRow(attachments: draftAttachments)
                        .animation(.easeOut(duration: 0.16), value: draftAttachments.wrappedValue.count)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Sized by its own content: one line at rest, growing only as
                // the message does, instead of reserving a fixed tall block.
                TextField("Message", text: input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...12)
                    .focused($inputFocused)
                    .onSubmit {
                        if let query = slashQuery, let first = slashItems(for: query).first {
                            selectSlashItem(first)
                        } else {
                            send()
                        }
                    }
                    .onPasteCommand(of: [.image, .fileURL]) { providers in
                        handlePaste(providers)
                    }
                    .onChange(of: input.wrappedValue) { oldValue, newValue in
                        // A huge jump in length in one change is a paste, not
                        // typing — convert the whole draft into a text
                        // attachment instead of leaving a wall of text sitting
                        // in the field. Ordinary typing never trips this.
                        guard newValue.count - oldValue.count > 3_000 else { return }
                        draftAttachments.wrappedValue.append(.fromText(filename: "Pasted Text.txt", kind: .text, content: newValue, mimeType: "text/plain"))
                        input.wrappedValue = ""
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 2)

                VelaGlassContainer {
                    HStack(spacing: 7) {
                        Button {
                            isAttachMenuShown.toggle()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .rotationEffect(.degrees(isAttachMenuShown ? 45 : 0))
                        }
                        .buttonStyle(AttachPlusButtonStyle())
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isAttachMenuShown)
                        .help("Attach")
                        .accessibilityLabel("Attach")
                        .popover(isPresented: $isAttachMenuShown, arrowEdge: .top) {
                            AttachMenu(
                                onFile: { isAttachMenuShown = false; presentAttachPanel() },
                                onFolder: { isAttachMenuShown = false; presentFolderPanel() },
                                onPasteboard: { isAttachMenuShown = false; pasteFromClipboard() },
                                onRepo: { repo in
                                    isAttachMenuShown = false
                                    appModel.cloneGitHubRepo(repo)
                                },
                                isPlanning: appModel.isPlanningActive,
                                onPlanMode: {
                                    isAttachMenuShown = false
                                    appModel.togglePlanningMode()
                                }
                            )
                        }
                        ModelPickerButton()
                        if appModel.availableThinkingLevels.count > 1 {
                            ThinkingPickerButton()
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                        if appModel.canUseWebSearch {
                            WebSearchToggleButton()
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                        Spacer(minLength: 8)
                        // Sits immediately left of Send, Claude-Code-style —
                        // "what am I about to spend" belongs right next to
                        // the button that spends it.
                        ContextButton()
                        // One control that morphs between send and stop —
                        // the stop action used to live as a separate square
                        // button up in the toolbar, far from the composer.
                        Button {
                            if appModel.isGenerating {
                                appModel.stopGeneration()
                            } else {
                                send()
                            }
                        } label: {
                            Image(systemName: appModel.isGenerating ? "stop.fill" : "arrow.up")
                                .font(.system(size: appModel.isGenerating ? 11 : 13, weight: .bold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(SendButtonStyle(isReady: canSend, isStopping: appModel.isGenerating))
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canSend && !appModel.isGenerating)
                        .help(appModel.isGenerating ? "Stop generating, keeping what has arrived (⌘.)" : "Send message (⌘Return)")
                        .accessibilityLabel(appModel.isGenerating ? "Stop generating and keep the partial reply (⌘.)" : "Send message (⌘Return)")
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: appModel.isGenerating)
                        // Stopping keeps the partial reply, which is the
                        // right default — a half-written answer is usually
                        // worth continuing. Discarding is the other real
                        // case (a reply that went wrong immediately) and
                        // needs its own control, not a hidden modifier.
                        .contextMenu {
                            if appModel.isGenerating {
                                Button(role: .destructive) {
                                    appModel.stopGenerationDiscardingPartial()
                                } label: {
                                    Label("Stop and Discard Reply", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            // Without this the glass control container greedily claims the
            // whole height the bottom inset offers, which is what made the
            // composer a tall empty slab regardless of the text inside it.
            .fixedSize(horizontal: false, vertical: true)
            // 34 matches the transcript's own text inset, so the caret and
            // the messages above it sit on the same left edge.
            .padding(.horizontal, 34)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: contentWidth)
            .nativeMaterial(cornerRadius: Theme.Radius.composer)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
                    .stroke(isDropTargeted ? Theme.accent.opacity(0.8) : Theme.accent.opacity(inputFocused ? 0.5 : 0.16), lineWidth: isDropTargeted ? 2 : (inputFocused ? 1.4 : 1))
            }
            .animation(.easeOut(duration: 0.18), value: inputFocused)
            .animation(.easeOut(duration: 0.12), value: isDropTargeted)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous))
            // Clicking anywhere on the composer (not just the field) puts
            // the cursor in it — buttons still win their own hits.
            .onTapGesture { inputFocused = true }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
        }
        // 34 is the transcript's own text inset, so the composer's outer
        // edge lines up with the column of messages above it rather than
        // running 16pt wider than everything else in the pane.
        .padding(.horizontal, 34)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(Theme.background.opacity(0.92))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: appModel.pendingQuestion?.id)
        .animation(.easeOut(duration: 0.16), value: appModel.statusMessage != nil)
        .animation(.easeOut(duration: 0.16), value: appModel.activeConversation?.activeSkillPaths.isEmpty ?? true)
        .animation(.easeOut(duration: 0.16), value: appModel.activeConversation?.isPlanning ?? false)
        .animation(.easeOut(duration: 0.16), value: slashQuery != nil)
        .animation(.easeOut(duration: 0.16), value: appModel.availableThinkingLevels.count)
        .animation(.easeOut(duration: 0.16), value: appModel.canUseWebSearch)
        .animation(.easeOut(duration: 0.16), value: appModel.isWebSearchEnabled)
    }

    private var canSend: Bool {
        let hasText = !input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachment = !draftAttachments.wrappedValue.isEmpty
        return (hasText || hasAttachment) && !appModel.isGenerating
    }

    private func send() {
        guard canSend else { return }
        appModel.send(input.wrappedValue)
    }

    // MARK: - Attachments

    private func addAttachment(from url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            if let attachment = Attachment.fromGitFolder(url: url) {
                draftAttachments.wrappedValue.append(attachment)
            } else {
                appModel.postNotice("\(url.lastPathComponent) isn't a git repository — only git-repo folders can be attached right now.")
            }
            return
        }
        guard let attachment = Attachment.fromFile(url: url) else { return }
        draftAttachments.wrappedValue.append(attachment)
        if attachment.kind == .image { warnIfNoVisionSupport() }
    }

    private func warnIfNoVisionSupport() {
        guard appModel.selectedModelInfo?.supportsVision == false else { return }
        appModel.postNotice("\(appModel.selectedModel) may not support image input — the image will still be sent, but the model might not be able to see it.")
    }

    private func imageAttachment(data: Data, filename: String) -> Attachment? {
        guard NSImage(data: data) != nil else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "heic": mime = "image/heic"
        default: mime = "image/jpeg"
        }
        return Attachment(kind: .image, filename: filename, mimeType: mime, data: data)
    }

    private func presentAttachPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addAttachment(from: url) }
    }

    /// Points this conversation's workspace at a real folder — every file
    /// tool and run_command then operates inside it, and nothing outside
    /// it (SandboxManager.resolve still refuses escapes).
    private func presentFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Workspace"
        panel.message = "The assistant can read, write, and run commands inside this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appModel.setWorkspaceRoot(url)
    }

    /// The plus menu's clipboard path: file URLs attach as files, images as
    /// image attachments — same handlers the composer's paste command uses.
    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            for url in urls { addAttachment(from: url) }
            return
        }
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            draftAttachments.wrappedValue.append(Attachment(kind: .image, filename: "Pasted Image.png", mimeType: "image/png", data: png))
            return
        }
        appModel.postNotice("The clipboard has no file or image to attach.")
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage,
                          let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
                    DispatchQueue.main.async {
                        draftAttachments.wrappedValue.append(Attachment(kind: .image, filename: "Pasted Image.png", mimeType: "image/png", data: pngData))
                        warnIfNoVisionSupport()
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { addAttachment(from: url) }
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { addAttachment(from: url) }
            }
        }
        return handled
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // Targets a sentinel below the last row: sending appends two rows
        // (user + streaming placeholder) in one update, and anchoring the
        // placeholder's own bottom before layout settled left the new
        // content half off-screen. One-tick defer lets layout land first.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("vela.bottom", anchor: .bottom) }
            } else {
                proxy.scrollTo("vela.bottom", anchor: .bottom)
            }
        }
    }

    /// Scroll-follow while text is streaming in.
    ///
    /// This used to be an unanimated `scrollTo` per reveal tick. That looks
    /// fine at a slow token rate, where each tick appends a word or two, but
    /// the reveal drain scales `wordsPerTick` with its backlog — so a fast
    /// model appends a large block every 33ms and the transcript teleports
    /// downward thirty times a second. Interpolating each step over roughly
    /// one tick turns the same sequence of jumps into continuous motion; the
    /// destination is identical, only the path between them changes.
    private func followLast(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.linear(duration: 0.034)) {
                proxy.scrollTo("vela.bottom", anchor: .bottom)
            }
        }
    }
}











/// The artifact side panel — live `WKWebView` preview for HTML/SVG/Mermaid,
/// plus copy and a real save-to-disk download (this is a normal, unsandboxed
/// Mac app, so an actual `NSSavePanel` is just as available here as it would
/// be in any other native app).
private struct ArtifactPanel: View {
    @Environment(ArtifactPresenter.self) private var artifactPresenter
    @Environment(AppModel.self) private var appModel
    let artifact: Artifact
    @State private var copied = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var width: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: DefaultsKey.inspectorWidth)
        return saved > 0 ? min(max(saved, 320), 720) : 420
    }()
    @State private var dragStartWidth: CGFloat?

    private var isWorkspaceFile: Bool {
        if case .workspaceFile = artifact.source { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: width)
        .background(Theme.background)
        // Resizable: a slim grab strip on the leading edge.
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStartWidth ?? width
                            dragStartWidth = start
                            width = min(max(start - value.translation.width, 320), 720)
                        }
                        .onEnded { _ in
                            dragStartWidth = nil
                            UserDefaults.standard.set(width, forKey: DefaultsKey.inspectorWidth)
                        }
                )
        }
        .onChange(of: artifact.id) { _, _ in
            isEditing = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.title)
                    .font(.subheadline.weight(.semibold))
                Text(artifact.kind.displayName)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            if isWorkspaceFile {
                if isEditing {
                    Button("Save") {
                        if let error = artifactPresenter.save(artifact, content: editText) {
                            appModel.postNotice(error)
                        } else {
                            withAnimation(.easeOut(duration: 0.18)) { isEditing = false }
                        }
                    }
                    .buttonStyle(VelaControlButtonStyle(tint: Theme.accent))
                } else {
                    Button {
                        editText = artifact.content
                        withAnimation(.easeOut(duration: 0.18)) { isEditing = true }
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(VelaIconButtonStyle())
                    .foregroundStyle(Theme.tertiaryText)
                    .help("Edit")
                    .accessibilityLabel("Edit")
                }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(isEditing ? editText : artifact.content, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(VelaIconButtonStyle())
            .foregroundStyle(copied ? Theme.success : Theme.tertiaryText)
            .help(copied ? "Copied" : "Copy source")
            .accessibilityLabel(copied ? "Copied" : "Copy source")
            .animation(.easeOut(duration: 0.12), value: copied)
            Button {
                downloadArtifact()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(VelaIconButtonStyle())
            .foregroundStyle(Theme.tertiaryText)
            .help("Save to disk")
            .accessibilityLabel("Save to disk")
            Button {
                artifactPresenter.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(VelaIconButtonStyle())
            .foregroundStyle(Theme.tertiaryText)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            TextEditor(text: $editText)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.surfaceLow)
        } else {
            switch artifact.kind {
            case .markdown:
                ScrollView {
                    RichMessageText(text: artifact.content, isUser: false)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(artifact.id)
                .transition(.opacity)
            case .code:
                ScrollView([.vertical, .horizontal]) {
                    CodeText(artifact.content)
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .id(artifact.id)
                .transition(.opacity)
            default:
                ArtifactWebView(html: artifact.previewHTML)
                    .background(Color.white)
            }
        }
    }

    private func downloadArtifact() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.title.contains(".") ? artifact.title : "artifact.\(artifact.kind.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (isEditing ? editText : artifact.content).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appModel.postNotice("Couldn't save the artifact: \(error.localizedDescription)")
        }
    }
}

enum SlashItem: Identifiable {
    case action(title: String, symbol: String, perform: () -> Void)
    case snippet(PromptSnippet)
    case skill(Skill)

    var id: String {
        switch self {
        case .action(let title, _, _): "action.\(title)"
        case .snippet(let snippet): "snippet.\(snippet.id)"
        case .skill(let skill): "skill.\(skill.id)"
        }
    }
}









/// "Searched the web · N results", expanding to the real sources as
/// clickable cards — the pattern ChatGPT and Claude both use for tool output.
