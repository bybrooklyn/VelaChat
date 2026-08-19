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
                // let text run off the bottom edge and then jump.
                guard now.timeIntervalSince(lastScrollAt) > 0.03 else { return }
                lastScrollAt = now
                scrollToLast(proxy, animated: false)
            }
            .overlay(alignment: .topLeading) {
                if appModel.sidebarVisibility == .detailOnly {
                    Button {
                        appModel.toggleSidebar()
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(8)
                            .glassChip(in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Show Sidebar")
                    // Clears the traffic-light zone in windowed mode.
                    .padding(.leading, 16)
                    .padding(.top, chrome.isFullScreen ? 10 : 34)
                    .transition(.opacity)
                }
            }
            .overlay {
                if let approval = appModel.pendingApproval,
                   approval.conversationID == appModel.activeConversationID {
                    // Modal-feeling but in-place: the reply is genuinely
                    // paused behind this decision.
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

    /// Bookmarked replies within this conversation — distinct from pinning the
/// whole conversation in the sidebar — jump back to directly instead of
/// scrolling to find them again.
private struct PinnedMessagesButton: View {
    let conversation: Conversation
    let proxy: ScrollViewProxy
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .padding(8)
        .glassChip(in: Circle())
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Pinned in this conversation")
                    .font(.headline)
                    .padding(12)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(conversation.pinnedMessages) { message in
                            Button {
                                isPresented = false
                                withAnimation { proxy.scrollTo(message.id, anchor: .top) }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: message.role == "user" ? "person.fill" : "sparkles")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.tertiaryText)
                                        .padding(.top, 2)
                                    Text(message.content.isEmpty ? "(empty)" : message.content)
                                        .font(.callout)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .foregroundStyle(Theme.text)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 280)
            }
            .frame(width: 320)
        }
        .help("Pinned messages")
    }
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

    private var composer: some View {
        VStack(spacing: 6) {
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
                        .popover(isPresented: $isAttachMenuShown, arrowEdge: .top) {
                            AttachMenu(
                                onFile: { isAttachMenuShown = false; presentAttachPanel() },
                                onFolder: { isAttachMenuShown = false; presentFolderPanel() },
                                onPasteboard: { isAttachMenuShown = false; pasteFromClipboard() },
                                onRepo: { repo in
                                    isAttachMenuShown = false
                                    appModel.cloneGitHubRepo(repo)
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
                        .help(appModel.isGenerating ? "Stop generating (⌘.)" : "Send message (⌘Return)")
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: appModel.isGenerating)
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
        // 18 + the pill's 16 inner inset = 34, the transcript's own inset —
        // the paperclip and message text share a left edge now.
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(Theme.background.opacity(0.92))
        .animation(.easeOut(duration: 0.16), value: appModel.statusMessage != nil)
        .animation(.easeOut(duration: 0.16), value: appModel.activeConversation?.activeSkillPaths.isEmpty ?? true)
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
}

/// Muted outline when there's nothing to send, solid filled accent once
/// there is, and a filled stop target while a reply is streaming — one
/// control that communicates all three states in place.
/// Real glass only for the two "filled" states (ready to send / stopping) —
/// `Glass.tint(_:)` reads naturally as "a solid colored button." The empty,
/// nothing-to-send state stays a plain stroked outline rather than an
/// untinted glass circle, which would read as inconsistent floating chrome
/// with nothing to visually anchor it.
/// The transcript's ⌘F find bar: match count across the open chat,
/// up/down jumping via the scroll proxy, a fading outline on the current
/// match's row. (Inline term highlighting inside Markdown bodies is a
/// known defer — MarkdownUI renders from plain strings.)
private struct ChatFindBar: View {
    @Environment(AppModel.self) private var appModel
    let conversation: Conversation
    let proxy: ScrollViewProxy

    @State private var query = ""
    @State private var matchIndex = 0
    @FocusState private var focused: Bool

    private var matches: [UUID] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 2 else { return [] }
        return conversation.messages
            .filter { !$0.isSynthetic }
            .filter { $0.content.lowercased().contains(trimmed) || ($0.reasoning?.lowercased().contains(trimmed) ?? false) }
            .map(\.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            TextField("Find in chat", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { jump(1) }
                .onExitCommand { close() }
            if !matches.isEmpty {
                Text("\(min(matchIndex + 1, matches.count)) of \(matches.count)")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            } else if query.count >= 2 {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Button { jump(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .disabled(matches.isEmpty)
            Button { jump(1) } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .disabled(matches.isEmpty)
            Button { close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassChip(in: Capsule())
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in
            matchIndex = 0
            if let first = matches.first { scroll(to: first) }
        }
    }

    private func jump(_ direction: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = ((matchIndex + direction) % matches.count + matches.count) % matches.count
        scroll(to: matches[matchIndex])
    }

    private func scroll(to id: UUID) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: .center)
        }
        appModel.chatFindHighlightID = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if appModel.chatFindHighlightID == id { appModel.chatFindHighlightID = nil }
        }
    }

    private func close() {
        appModel.isChatFindShown = false
        appModel.chatFindHighlightID = nil
    }
}

/// The plus button's glass menu: file, GitHub repo (only when the gh CLI
/// is installed and logged in), clipboard, and a cloud page that morphs in
/// with providers marked coming-soon.
private struct AttachMenu: View {
    enum Page { case root, repos, cloud }

    let onFile: () -> Void
    let onFolder: () -> Void
    let onPasteboard: () -> Void
    let onRepo: (String) -> Void

    @State private var page: Page = .root
    @State private var repos: [String]? = nil
    @State private var ghChecked = false
    @State private var ghAvailable = false
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch page {
            case .root: rootPage
            case .repos: reposPage
            case .cloud: cloudPage
            }
        }
        .padding(8)
        .frame(width: 250)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: page)
        // Reopening the menu must start at the root, not wherever the
        // last visit left off.
        .onAppear { page = .root }
        .task {
            guard !ghChecked else { return }
            ghChecked = true
            let list = await appModel.fetchGitHubRepos()
            ghAvailable = list != nil
            repos = list
        }
    }

    @ViewBuilder
    private var rootPage: some View {
        menuRow(symbol: "doc.badge.plus", title: "Attach file…", action: onFile)
        menuRow(symbol: "folder.badge.gearshape", title: "Open folder as workspace…", action: onFolder)
        if ghAvailable {
            menuRow(symbol: "arrow.triangle.branch", title: "Add GitHub repo", chevron: true) {
                page = .repos
            }
        }
        menuRow(symbol: "doc.on.clipboard", title: "Paste from clipboard", action: onPasteboard)
        menuRow(symbol: "cloud", title: "Cloud storage", chevron: true) {
            page = .cloud
        }
    }

    @ViewBuilder
    private var reposPage: some View {
        backRow(title: "GitHub repos")
        if let repos, !repos.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(repos, id: \.self) { repo in
                        menuRow(symbol: "arrow.triangle.branch", title: repo) {
                            onRepo(repo)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        } else if repos == nil {
            ShimmerText(text: "Loading repos…", font: .callout)
                .padding(10)
        } else {
            Text("No repositories found.")
                .font(.callout)
                .foregroundStyle(Theme.tertiaryText)
                .padding(10)
        }
    }

    @ViewBuilder
    private var cloudPage: some View {
        backRow(title: "Cloud storage")
        disabledRow(symbol: "externaldrive.badge.icloud", title: "Google Drive", note: "connect — coming soon")
        disabledRow(symbol: "externaldrive.badge.icloud", title: "Proton Drive", note: "connect — coming soon")
    }

    private func backRow(title: String) -> some View {
        HStack(spacing: 6) {
            Button {
                page = .root
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func menuRow(symbol: String, title: String, chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 18)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    private func disabledRow(symbol: String, title: String, note: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
            Text(title)
                .font(.callout)
            Spacer(minLength: 0)
            Text(note)
                .font(.caption2)
        }
        .foregroundStyle(Theme.tertiaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Theme.controlBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
    }
}

/// The composer's plus button: a circular control with real physical press
/// feedback — it visibly depresses before the file panel opens.
private struct AttachPlusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.secondaryText)
            .frame(width: 30, height: 30)
            .background(Theme.controlBackground.opacity(configuration.isPressed ? 1 : 0.75), in: Circle())
            .overlay { Circle().stroke(Theme.controlStroke.opacity(0.6), lineWidth: 1) }
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

private struct SendButtonBackground: ViewModifier {
    let fill: Color
    let isFilled: Bool

    // A plain filled circle, deliberately NOT a glassEffect: inside the
    // composer's GlassEffectContainer, a glass send button visually merged
    // and morphed with the neighboring context circle. Fill just fades.
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Circle().fill(fill)
                    Circle()
                        .stroke(Theme.controlStroke.opacity(0.7), lineWidth: 1.2)
                        .opacity(isFilled ? 0 : 1)
                }
            }
    }
}

private struct SendButtonStyle: ButtonStyle {
    let isReady: Bool
    var isStopping = false

    private var fill: Color {
        // Stop used to be a near-white disc — the brightest thing on
        // screen through every reply. The softened danger tint reads
        // "stop" without glowing.
        if isStopping { return Theme.danger }
        return isReady ? Theme.accentStrong : .clear
    }

    private var foreground: Color {
        if isStopping { return Theme.accentForeground }
        return isReady ? Theme.accentForeground : Theme.tertiaryText
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 30)
            .modifier(SendButtonBackground(fill: fill, isFilled: isReady || isStopping))
            .foregroundStyle(foreground)
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isReady)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isStopping)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var appModel
    let message: ChatMessage
    let isLastMessage: Bool
    @State private var showingReasoning = false
    @State private var showingSearchResults = false
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editedText = ""
    @State private var alternateIndex = 0

    private var totalVersions: Int { message.alternates.count + 1 }
    private var displayedMessage: ChatMessage {
        guard alternateIndex > 0, alternateIndex - 1 < message.alternates.count else { return message }
        return message.alternates[alternateIndex - 1]
    }

    private var pinIndicator: some View {
        HStack(spacing: 3) {
            Image(systemName: "pin.fill")
                .font(.system(size: 8))
            Text("Pinned")
                .font(.caption2)
        }
        .foregroundStyle(Theme.accent)
    }

    var isGroupedWithPrevious: Bool = false

    static func timestampLabel(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return "\(relative) · \(time.string(from: date))"
    }

    var body: some View {
        if message.role == "notice" {
            NoticeCard(message: message)
        } else if message.role == "compaction" {
            CompactionCard(message: message)
        } else if message.role == "user" {
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 120)
                Button {
                    editedText = message.content
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
                .help("Edit message")
                .opacity(isHovering && !isEditing ? 1 : 0)
                .allowsHitTesting(isHovering && !isEditing)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                VStack(alignment: .trailing, spacing: 4) {
                    if isEditing {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextField("Message", text: $editedText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(1...6)
                            HStack(spacing: 6) {
                                Button("Cancel") { isEditing = false }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.tertiaryText)
                                Button("Save") {
                                    isEditing = false
                                    appModel.editMessage(message, newContent: editedText)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, appModel.density.bubblePadding)
                        .frame(minWidth: 220)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                    } else {
                        if !message.attachments.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(message.attachments) { attachment in
                                    AttachmentChip(attachment: attachment)
                                }
                            }
                        }
                        RichMessageText(text: message.content, isUser: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, appModel.density.bubblePadding)
                            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                            .contextMenu {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(message.content, forType: .string)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                Button {
                                    editedText = message.content
                                    isEditing = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button {
                                    if let conversation = appModel.activeConversation {
                                        appModel.branchConversation(from: message, in: conversation)
                                    }
                                } label: {
                                    Label("Branch from Here", systemImage: "arrow.triangle.branch")
                                }
                                Button {
                                    appModel.toggleMessagePin(message)
                                } label: {
                                    Label(message.isPinned ? "Unpin" : "Pin", systemImage: message.isPinned ? "pin.slash" : "pin")
                                }
                                Button(role: .destructive) {
                                    appModel.deleteMessage(message)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    if message.isPinned {
                        pinIndicator
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isEditing)
            }
            .onHover { isHovering = $0 }
        } else {
            HStack(alignment: .top, spacing: 11) {
                if isGroupedWithPrevious {
                    // Same speaker as above: the avatar yields to a spacer so
                    // consecutive replies read as one tight run.
                    Color.clear.frame(width: 23, height: 1)
                } else {
                    VelaMark(size: 23)
                        .padding(.top, 1)
                        .help(displayedMessage.modelID.map { "Generated by \($0)" } ?? (displayedMessage.providerName ?? ""))
                }
                VStack(alignment: .leading, spacing: 7) {
                    // No provider-name header — the VelaMark avatar is the
                    // whole signature (model id lives in its tooltip).
                    if message.isPinned || totalVersions > 1 {
                        HStack(spacing: 8) {
                            Spacer()
                            if message.isPinned {
                                pinIndicator
                            }
                            if totalVersions > 1 {
                                AlternateStepper(index: $alternateIndex, total: totalVersions)
                            }
                        }
                    }

                    if alternateIndex == 0, let record = appModel.searchByMessage[message.id] {
                        SearchResultsDisclosure(record: record, isExpanded: $showingSearchResults)
                    }

                    if alternateIndex == 0, let steps = appModel.planByMessage[message.id], !steps.isEmpty {
                        PlanCard(steps: steps, isWorking: message.isStreaming)
                    }

                    if let reasoning = displayedMessage.reasoning, !reasoning.isEmpty {
                        ReasoningDisclosure(
                            reasoning: reasoning,
                            isThinking: alternateIndex == 0 && message.isStreaming
                                && (displayedMessage.content.isEmpty || appModel.isRevealingReasoning(message.id)),
                            isExpanded: $showingReasoning
                        )
                    }

                    if let error = displayedMessage.error {
                        VStack(alignment: .leading, spacing: 8) {
                            // A mid-stream failure keeps whatever already
                            // streamed — hiding 800 words behind a triangle
                            // was pure data loss for the reader.
                            if !displayedMessage.content.isEmpty {
                                RichMessageText(text: displayedMessage.content, isUser: false)
                            }
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.danger)
                            if alternateIndex == 0 {
                                Button("Try Again") { appModel.retryLastMessage() }
                                    .buttonStyle(VelaControlButtonStyle(tint: Theme.danger))
                            }
                        }
                    } else if alternateIndex == 0, let ask = displayedMessage.askQuestion {
                        // The card appears the moment the closing fence
                        // arrives — no need to wait for the stream to end.
                        VStack(alignment: .leading, spacing: 10) {
                            if !ask.prefix.isEmpty {
                                RichMessageText(text: ask.prefix, isUser: false)
                            }
                            AskUserQuestionCard(
                                payload: ask.payload,
                                interactive: isLastMessage && !appModel.isGenerating
                            )
                            if !ask.suffix.isEmpty {
                                RichMessageText(text: ask.suffix, isUser: false)
                            }
                        }
                    } else if message.isStreaming, alternateIndex == 0,
                              AskUserQuestionPayload.hasUnterminatedFence(in: displayedMessage.content) {
                        // Mid-stream, fence open: never show the raw JSON
                        // typing itself out — a quiet placeholder instead.
                        VStack(alignment: .leading, spacing: 10) {
                            let prefix = AskUserQuestionPayload.prefixBeforeUnterminatedFence(in: displayedMessage.content)
                            if !prefix.isEmpty {
                                RichMessageText(text: prefix, isUser: false)
                            }
                            HStack(spacing: 8) {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.tertiaryText)
                                ShimmerText(text: "Preparing a question…", font: .callout)
                            }
                        }
                    } else {
                        AssistantTimeline(message: displayedMessage)
                            .contextMenu {
                                if !displayedMessage.content.isEmpty {
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(displayedMessage.content, forType: .string)
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }
                                if alternateIndex == 0 {
                                    Button {
                                        appModel.regenerate(message)
                                    } label: {
                                        Label("Regenerate", systemImage: "arrow.counterclockwise")
                                    }
                                    .disabled(appModel.isGenerating)
                                    Button {
                                        appModel.continueGenerating(message)
                                    } label: {
                                        Label("Continue Generating", systemImage: "arrow.forward.to.line")
                                    }
                                    .disabled(appModel.isGenerating)
                                }
                                Button {
                                    if let conversation = appModel.activeConversation {
                                        appModel.branchConversation(from: message, in: conversation)
                                    }
                                } label: {
                                    Label("Branch from Here", systemImage: "arrow.triangle.branch")
                                }
                                Button {
                                    appModel.toggleMessagePin(message)
                                } label: {
                                    Label(message.isPinned ? "Unpin" : "Pin", systemImage: message.isPinned ? "pin.slash" : "pin")
                                }
                                Button(role: .destructive) {
                                    appModel.deleteMessage(message)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }

                    if !message.isStreaming {
                        HStack(spacing: 10) {
                            if let summary = appModel.usageByMessage[displayedMessage.id] ?? displayedMessage.usage,
                               let label = summary.label {
                                // Price against the provider that actually
                                // produced this reply (stamped by name at
                                // send time), not whatever is selected now.
                                let costProviderID = appModel.providers.profiles
                                    .first(where: { $0.name == displayedMessage.providerName })?.id
                                    ?? appModel.activeConversation?.providerID
                                    ?? UUID()
                                let cost = summary.costUSD(for: appModel.providers.modelInfo(
                                    for: costProviderID,
                                    model: displayedMessage.modelID ?? ""
                                ))
                                Text(cost.map { label + String(format: " · $%.4f", $0) } ?? label)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            MessageActionRow(
                                message: message,
                                displayedMessage: displayedMessage,
                                canRegenerate: alternateIndex == 0
                            )
                            if appModel.isHoverTimestampsEnabled {
                                Text(Self.timestampLabel(for: displayedMessage.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.tertiaryText)
                                    .opacity(isHovering ? 1 : 0)
                                    .animation(.easeOut(duration: 0.15), value: isHovering)
                            }
                            Spacer(minLength: 0)
                        }
                        // Persistent, not hover-revealed — dim at rest,
                        // brightening when the pointer arrives.
                        .opacity(isHovering ? 1 : 0.65)
                        .animation(.easeOut(duration: 0.15), value: isHovering)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onHover { isHovering = $0 }
        }
    }
}

/// Staged attachments in the composer — thumbnail for images, an icon chip
/// with filename/size for everything else, each removable before send.
private struct AttachmentChipRow: View {
    @Binding var attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
        }
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if attachment.kind == .image, let nsImage = NSImage(data: attachment.data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.modelAccent)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(attachment.sizeLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.controlBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                .stroke(Theme.controlStroke.opacity(0.5), lineWidth: 1)
        }
    }

    private var symbol: String {
        switch attachment.kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.text"
        case .git: "arrow.triangle.branch"
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
        let saved = UserDefaults.standard.double(forKey: "velachat.inspector-width")
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
                            UserDefaults.standard.set(width, forKey: "velachat.inspector-width")
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
            .animation(.easeOut(duration: 0.12), value: copied)
            Button {
                downloadArtifact()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(VelaIconButtonStyle())
            .foregroundStyle(Theme.tertiaryText)
            .help("Save to disk")
            Button {
                artifactPresenter.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(VelaIconButtonStyle())
            .foregroundStyle(Theme.tertiaryText)
            .help("Close")
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
                .background(Theme.controlBackground.opacity(0.35))
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

private enum SlashItem: Identifiable {
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

/// The `/` menu — built-in actions, saved prompt snippets, and Skills in one
/// filtered list, matching how claude.ai's own slash-command menu combines
/// the same three kinds of things rather than keeping them separate.
private struct SlashCommandList: View {
    let items: [SlashItem]
    let onSelect: (SlashItem) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: symbol(for: item))
                                .frame(width: 16)
                                .foregroundStyle(tint(for: item))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title(for: item))
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(Theme.text)
                                if let subtitle = subtitle(for: item) {
                                    Text(subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.tertiaryText)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.controlStroke.opacity(0.6), lineWidth: 1)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func symbol(for item: SlashItem) -> String {
        switch item {
        case .action(_, let symbol, _): symbol
        case .snippet: "text.quote"
        case .skill: "sparkles"
        }
    }
    private func tint(for item: SlashItem) -> Color {
        switch item {
        case .action: Theme.tertiaryText
        case .snippet: Theme.modelAccent
        case .skill: Theme.accent
        }
    }
    private func title(for item: SlashItem) -> String {
        switch item {
        case .action(let title, _, _): title
        case .snippet(let snippet): snippet.name
        case .skill(let skill): skill.name
        }
    }
    private func subtitle(for item: SlashItem) -> String? {
        switch item {
        case .action: nil
        case .snippet(let snippet): snippet.body
        case .skill(let skill): skill.description
        }
    }
}

/// A `role: "notice"` message rendered as a quiet system card — everything
/// that used to be a banner above the composer (no provider chosen, already
/// generating, saved history unreadable) now shows up here instead, so
/// errors always appear in one place: the conversation itself.
private struct NoticeCard: View {
    let message: ChatMessage

    private var symbol: String {
        switch message.noticeKind {
        case "success": "checkmark.circle"
        case "info": "info.circle"
        default: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch message.noticeKind {
        case "success": Theme.success
        case "info": Theme.secondaryText
        default: Theme.warning
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(message.content)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.controlBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Marks where a conversation was compacted — nothing above this is ever
/// deleted or hidden, only left out of the request payload for future
/// turns. Collapsed by default, expandable to see the actual generated
/// summary (what's really being sent in its place).
private struct CompactionCard: View {
    let message: ChatMessage
    @State private var isExpanded = false

    var body: some View {
        ActivityRow(
            symbol: "arrow.down.right.and.arrow.up.left",
            title: "Conversation compacted here",
            tint: Theme.tertiaryText,
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing above was deleted — this summary just replaces those messages in what's actually sent to the model from here on.")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The run_command approval gate. Generation is genuinely paused behind
/// this card: the exact command and working directory are shown, the
/// command text is editable before approving, and a denial goes back to
/// the model as a normal tool result. "Allow all in this chat" is armed
/// separately and deliberately — never a side effect of approving once.
struct CommandApprovalCard: View {
    let approval: AppModel.CommandApproval
    @State private var editedCommand: String = ""
    @State private var didAppear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(Theme.warning)
                Text("Run this command?")
                    .font(.body.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text(approval.reason)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            TextField("Command", text: $editedCommand, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .flatFieldStyle()
                .lineLimit(1...6)
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.caption2)
                Text(approval.directory.path)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.tertiaryText)
            HStack(spacing: 8) {
                Button("Run") { approval.decide(.approveOnce(trimmed)) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                Button("Always Allow This") { approval.decide(.approveAlways(trimmed)) }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button("Deny") { approval.decide(.deny) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            Button {
                approval.decide(.approveAll(trimmed))
            } label: {
                Label("Allow every command in this chat (until you quit)", systemImage: "lock.open")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryText)
        }
        .padding(16)
        .frame(width: 460)
        .background(Theme.sidebarBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.warning.opacity(0.4), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            editedCommand = approval.command
        }
    }

    private var trimmed: String {
        editedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? approval.command
            : editedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The model's live task plan (`update_plan`) — a compact checklist that
/// updates in place as steps advance, and collapses to a one-line summary
/// once the reply is done, so a finished conversation doesn't stay full of
/// scaffolding.
private struct PlanCard: View {
    let steps: [ToolCatalog.PlanStep]
    let isWorking: Bool
    @State private var isExpanded = true

    private var completed: Int { steps.filter { $0.status == "completed" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(completed == steps.count ? "Completed \(steps.count) steps" : "Plan · \(completed)/\(steps.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: symbol(for: step.status))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(color(for: step.status))
                                .frame(width: 13)
                            if step.status == "in_progress", isWorking {
                                ShimmerText(text: step.step, font: .caption)
                            } else {
                                Text(step.step)
                                    .font(.caption)
                                    .foregroundStyle(step.status == "completed" ? Theme.tertiaryText : Theme.text)
                                    .strikethrough(step.status == "completed", color: Theme.tertiaryText)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.controlBackground.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                .stroke(Theme.controlStroke.opacity(0.4), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.2), value: steps)
        .onChange(of: isWorking) { _, working in
            // Fold the scaffolding away once the work is finished.
            if !working, completed == steps.count {
                withAnimation(.easeOut(duration: 0.25)) { isExpanded = false }
            }
        }
    }

    private func symbol(for status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted"
        default: "circle"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": Theme.success
        case "in_progress": Theme.accent
        default: Theme.tertiaryText
        }
    }
}

/// Renders a ````ask-user` block as a real interactive picker instead of raw
/// JSON — the model's answer to "what do you want me to do" becomes a click
/// (plus an optional note) instead of a typed reply. Submitting composes a
/// plain-text summary and sends it as the next message, so no new wire
/// format is needed on the way back to the provider.
private struct AskUserQuestionCard: View {
    @Environment(AppModel.self) private var appModel
    let payload: AskUserQuestionPayload
    let interactive: Bool

    /// Selections keyed by question text — each question answers
    /// independently; Send unlocks once every one has an answer.
    @State private var selected: [String: Set<String>] = [:]
    @State private var notes = ""
    @State private var submitted = false

    private var canSubmit: Bool {
        payload.questions.allSatisfy { !(selected[$0.id] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(payload.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = question.header, !header.isEmpty {
                        Text(header.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.accentSoft.opacity(0.5), in: Capsule())
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                        Text(question.question)
                            .font(.body.weight(.semibold))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(question.options) { option in
                            optionRow(option, in: question)
                        }
                    }
                }
            }
            if payload.allowNotes, interactive, !submitted {
                TextField("Add a note (optional)", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .flatFieldStyle()
                    .lineLimit(1...4)
            }
            if interactive, !submitted {
                Button("Send") { submit() }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentStrong)
                    .disabled(!canSubmit)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.controlBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.accent.opacity(0.2), lineWidth: 1)
        }
        // Selection and the post-submit state settle with a fade instead of
        // controls vanishing in one frame.
        .animation(.easeOut(duration: 0.15), value: selected)
        .animation(.easeOut(duration: 0.2), value: submitted)
    }

    private func optionRow(_ option: AskUserQuestionPayload.Option, in question: AskUserQuestionPayload.Question) -> some View {
        let isOn = (selected[question.id] ?? []).contains(option.label)
        return Button {
            guard interactive, !submitted else { return }
            var current = selected[question.id] ?? []
            if question.multiSelect {
                if current.contains(option.label) { current.remove(option.label) } else { current.insert(option.label) }
            } else {
                current = [option.label]
            }
            selected[question.id] = current
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol(isOn: isOn, multiSelect: question.multiSelect))
                    .foregroundStyle(isOn ? Theme.accent : Theme.tertiaryText)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.text)
                        if option.recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isOn ? Theme.accentSoft.opacity(0.7) : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                    .stroke(
                        isOn ? Theme.accent.opacity(0.35) : Theme.controlStroke.opacity(0.4),
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!interactive || submitted)
    }

    private func symbol(isOn: Bool, multiSelect: Bool) -> String {
        if multiSelect { return isOn ? "checkmark.square.fill" : "square" }
        return isOn ? "largecircle.fill.circle" : "circle"
    }

    private func submit() {
        guard canSubmit else { return }
        submitted = true
        var lines: [String] = []
        for question in payload.questions {
            let chosen = question.options
                .filter { (selected[question.id] ?? []).contains($0.label) }
                .map(\.label)
            let name = question.header ?? question.question
            lines.append(payload.questions.count == 1
                ? "I choose: \(chosen.joined(separator: ", "))"
                : "\(name): \(chosen.joined(separator: ", "))")
        }
        var summary = lines.joined(separator: "\n")
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            summary += "\n\nNote: \(trimmedNotes)"
        }
        appModel.send(summary)
    }
}

private struct MessageActionRow: View {
    @Environment(AppModel.self) private var appModel
    let message: ChatMessage
    let displayedMessage: ChatMessage
    let canRegenerate: Bool

    var body: some View {
        HStack(spacing: 10) {
            if !displayedMessage.content.isEmpty {
                CopyButton(text: displayedMessage.content)
            }
            if canRegenerate {
                Button {
                    appModel.regenerate(message)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(Theme.tertiaryText)
                .disabled(appModel.isGenerating)
                .help("Regenerate")

                Button {
                    appModel.continueGenerating(message)
                } label: {
                    Image(systemName: "arrow.forward.to.line")
                }
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(Theme.tertiaryText)
                .disabled(appModel.isGenerating)
                .help("Continue generating")
            }
            if !displayedMessage.content.isEmpty {
                Button {
                    appModel.toggleReadAloud(displayedMessage)
                } label: {
                    Image(systemName: appModel.speakingMessageID == displayedMessage.id ? "stop.circle" : "speaker.wave.2")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(appModel.speakingMessageID == displayedMessage.id ? Theme.accent : Theme.tertiaryText)
                .help(appModel.speakingMessageID == displayedMessage.id ? "Stop reading" : "Read aloud")
                .animation(.easeOut(duration: 0.12), value: appModel.speakingMessageID)

                ShareButton(text: displayedMessage.content)
                    .frame(width: 14, height: 14)
                    .help("Share")
            }
        }
        .font(.caption)
    }
}

/// A real macOS share sheet (Mail, Messages, Notes, AirDrop, etc.) for the
/// message text — distinct from Copy, which just fills the pasteboard.
private struct ShareButton: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSButton {
        // Matched to the sibling SwiftUI icon buttons in this row, which all
        // render at `.font(.caption)` — an AppKit NSButton doesn't inherit
        // that, so its symbol needs the same point size spelled out here.
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let button = NSButton(
            image: (NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share") ?? NSImage())
                .withSymbolConfiguration(symbolConfig) ?? NSImage(),
            target: context.coordinator,
            action: #selector(Coordinator.share)
        )
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .tertiaryLabelColor
        context.coordinator.button = button
        context.coordinator.text = text
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.text = text
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var text = ""
        weak var button: NSButton?

        @objc func share() {
            guard let button else { return }
            NSSharingServicePicker(items: [text]).show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }
}

/// "Searched the web · N results", expanding to the real sources as
/// clickable cards — the pattern ChatGPT and Claude both use for tool output.

/// An assistant reply rendered as its real timeline: text runs with dim
/// activity lines woven between them exactly where the model paused to act
/// — the Claude-web pattern. Messages from before segments existed fall
/// back to one plain text run.
struct AssistantTimeline: View {
    let message: ChatMessage

    private enum Item: Identifiable {
        case text(id: UUID, content: String)
        case activities([ActivityRecord])

        var id: UUID {
            switch self {
            case .text(let id, _): id
            case .activities(let records): records.first?.id ?? UUID()
            }
        }
    }

    private var items: [Item] {
        guard !message.segments.isEmpty else {
            return message.content.isEmpty ? [] : [.text(id: message.id, content: message.content)]
        }
        var items: [Item] = []
        for segment in message.segments {
            switch segment {
            case .text(let id, let content):
                // Whitespace-only runs (blank lines between tool rounds)
                // are invisible — they must not break line aggregation.
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                items.append(.text(id: id, content: content))
            case .activity(let record):
                // Consecutive completed, successful calls aggregate into one
                // line; a running or failed call always stands alone.
                if case .activities(let group) = items.last,
                   !record.isRunning, !record.isError,
                   group.allSatisfy({ !$0.isRunning && !$0.isError }) {
                    items[items.count - 1] = .activities(group + [record])
                } else {
                    items.append(.activities([record]))
                }
            }
        }
        return items
    }

    private var allActivities: [ActivityRecord] {
        message.segments.compactMap {
            if case .activity(let record) = $0 { return record }
            return nil
        }
    }

    /// Markdown parsing of the whole growing reply on every reveal tick was
    /// the single biggest source of streaming lag — the still-growing tail
    /// renders as plain text and becomes real Markdown when the reply
    /// finishes.
    @ViewBuilder
    private func textRun(_ content: String, isTail: Bool) -> some View {
        if message.isStreaming && isTail {
            Text(content)
                .font(.body)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            RichMessageText(text: content, isUser: false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.isStreaming, !allActivities.isEmpty {
                // Finished: the whole streamed stack settles into one dim
                // summary line on top — the response owns the screen, the
                // full per-call record stays one click away.
                ActivityLine(records: allActivities, style: .summary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                ForEach(items) { item in
                    if case .text(_, let content) = item {
                        RichMessageText(text: content, isUser: false)
                    }
                }
            } else {
                let lastID = items.last?.id
                ForEach(items) { item in
                    switch item {
                    case .text(_, let content):
                        textRun(content, isTail: item.id == lastID)
                    case .activities(let records):
                        ActivityLine(records: records)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: message.isStreaming)
    }
}

/// One dim, icon-led line — "Searching the web for 'X'" while running
/// (shimmering, never a spinner), a past-tense summary once done, counts
/// emphasized when several calls collapse into one line. Click to unfold
/// the real arguments and results in place.
struct ActivityLine: View {
    enum Style { case interleaved, summary }

    @Environment(ArtifactPresenter.self) private var artifactPresenter
    @Environment(AppModel.self) private var appModel
    let records: [ActivityRecord]
    var style: Style = .interleaved
    @State private var isExpanded = false
    @State private var isHovering = false

    private var isRunning: Bool { records.contains { $0.isRunning } }
    private var isError: Bool { records.contains { $0.isError } }

    private var label: String {
        if style == .summary { return summaryLabel }
        guard records.count > 1 else {
            guard let record = records.first else { return "" }
            if record.isRunning { return record.kind.runningLabel(argument: record.argument) }
            if record.isError { return record.kind.finishedLabel(argument: record.argument) + " — failed" }
            return record.kind.finishedLabel(argument: record.argument)
        }
        // Aggregate: counts per kind, in order of first appearance —
        // "Ran 3 web searches, read 2 pages".
        var orderedKinds: [ActivityKind] = []
        var counts: [ActivityKind: Int] = [:]
        for record in records {
            if counts[record.kind] == nil { orderedKinds.append(record.kind) }
            counts[record.kind, default: 0] += 1
        }
        var parts: [String] = []
        for (index, kind) in orderedKinds.enumerated() {
            var unit = kind.aggregateUnit(count: counts[kind] ?? 0)
            if index == 0, kind == .webSearch || kind == .conversationSearch || kind == .calculation || kind == .memory {
                unit = "Ran " + unit
            }
            parts.append(unit)
        }
        var sentence = parts.joined(separator: ", ")
        if let first = sentence.first {
            sentence = first.uppercased() + sentence.dropFirst()
        }
        return sentence
    }

    /// The one-line settle of a finished reply's whole activity stack:
    /// successes aggregated per kind, failures counted as "blocked" —
    /// "Browsed the web · read 2 pages, 8 blocked".
    private var summaryLabel: String {
        let succeeded = records.filter { !$0.isError && !$0.isRunning }
        let failed = records.filter { $0.isError }
        guard records.count > 1 else {
            guard let record = records.first else { return "" }
            if record.isError { return record.kind.finishedLabel(argument: record.argument) + " — failed" }
            return record.kind.finishedLabel(argument: record.argument)
        }
        var orderedKinds: [ActivityKind] = []
        var counts: [ActivityKind: Int] = [:]
        for record in succeeded {
            if counts[record.kind] == nil { orderedKinds.append(record.kind) }
            counts[record.kind, default: 0] += 1
        }
        var parts = orderedKinds.map { ($0, counts[$0] ?? 0) }.map { $0.0.aggregateUnit(count: $0.1) }
        if !failed.isEmpty {
            parts.append("\(failed.count) blocked")
        }
        let browsed = records.contains { $0.kind == .webSearch || $0.kind == .fetchURL }
        var sentence = parts.joined(separator: ", ")
        if browsed {
            sentence = "Browsed the web · " + sentence
        } else if let first = sentence.first {
            sentence = first.uppercased() + sentence.dropFirst()
        }
        return sentence
    }

    /// Digit runs render slightly brighter and semibold — the Claude Code
    /// aggregated-line look.
    private var emphasizedLabel: Text {
        var result = Text("")
        var run = ""
        var runIsDigit = false
        func flush() {
            guard !run.isEmpty else { return }
            if runIsDigit {
                let piece = Text(run).fontWeight(.semibold).foregroundStyle(Theme.secondaryText)
                result = Text("\(result)\(piece)")
            } else {
                result = Text("\(result)\(Text(run))")
            }
            run = ""
        }
        for character in label {
            let isDigit = character.isNumber
            if isDigit != runIsDigit { flush(); runIsDigit = isDigit }
            run.append(character)
        }
        flush()
        return result
    }

    private var symbol: String {
        if style == .summary, records.contains(where: { $0.kind == .webSearch || $0.kind == .fetchURL }) {
            return "globe"
        }
        return records.first?.kind.symbol ?? "circle"
    }

    /// In summary style a few blocked pages shouldn't paint the whole line
    /// as an error — only an all-failed stack does.
    private var showsErrorTint: Bool {
        style == .summary ? records.allSatisfy(\.isError) : isError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: showsErrorTint ? "exclamationmark.triangle" : symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(showsErrorTint ? Theme.danger.opacity(0.85) : Theme.tertiaryText)
                    .frame(width: 16)
                if isRunning {
                    ShimmerText(text: label, font: .callout)
                } else {
                    emphasizedLabel
                        .font(.callout)
                        .foregroundStyle(Theme.tertiaryText)
                }
                if !isRunning {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText.opacity(isHovering ? 0.9 : 0))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isRunning else { return }
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            if !record.argument.isEmpty {
                                HStack(spacing: 8) {
                                    Text(record.kind.finishedLabel(argument: record.argument))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.secondaryText)
                                    // Files the model wrote or read open in
                                    // the inspector, rendered for real.
                                    if record.kind == .fileWrite || record.kind == .fileRead,
                                       !record.isError,
                                       let conversationID = appModel.activeConversationID {
                                        Button {
                                            artifactPresenter.openWorkspaceFile(conversationID: conversationID, relativePath: record.argument)
                                        } label: {
                                            Label("Open", systemImage: "sidebar.right")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            if !record.result.isEmpty {
                                Text(record.result)
                                    .font(.caption)
                                    .foregroundStyle(record.isError ? Theme.danger.opacity(0.85) : Theme.tertiaryText)
                                    .textSelection(.enabled)
                                    .lineLimit(14)
                            }
                        }
                    }
                }
                .padding(.leading, 24)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.separator.opacity(0.5))
                        .frame(width: 1)
                        .padding(.leading, 7)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct SearchResultsDisclosure: View {
    let record: WebSearchRecord
    @Binding var isExpanded: Bool

    var body: some View {
        ActivityRow(
            symbol: "globe",
            title: "Searched the web · \(record.results.count) source\(record.results.count == 1 ? "" : "s")",
            tint: Theme.accent,
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("“\(record.query)”")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                ForEach(record.results) { result in
                    // Search-result URLs are model/provider-supplied text —
                    // never force-unwrap them into URL(string:).
                    if let destination = URL(string: result.url) ?? URL(string: "https://\(result.url)") {
                        Link(destination: destination) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "link")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.tertiaryText)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.accent)
                                    .lineLimit(1)
                                Text(result.url)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.tertiaryText)
                                    .lineLimit(1)
                                if !result.snippet.isEmpty {
                                    Text(result.snippet)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .background(Theme.controlBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Reasoning presented as an activity step rather than a "Thinking summary"
/// box: a pulsing icon and live timer while it runs, a settled "Thought for
/// Ns" once it's done, and the raw chain kept behind a disclosure.
private struct ReasoningDisclosure: View {
    let reasoning: String
    let isThinking: Bool
    @Binding var isExpanded: Bool
    @State private var startedAt: Date?
    @State private var elapsedWhenFinished: Int?

    var body: some View {
        // Only ticks while actually thinking — once it settles, the label is
        // a fixed string ("Thought for Ns" / "Reasoning") that never changes
        // again, so a periodic TimelineView left running for as long as the
        // message stays on screen was a permanent, pointless once-a-second
        // re-render for every reasoning-bearing message in the transcript.
        // `.onAppear`/`.onChange` sit on this outer `Group`, not inside the
        // conditional branch below, so they keep firing reliably across the
        // isThinking → false transition instead of being torn down with it.
        Group {
            if isThinking {
                TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
                    row(title: label(at: context.date))
                }
            } else {
                row(title: label(at: .now))
            }
        }
        .onAppear {
            if isThinking, startedAt == nil { startedAt = Date() }
        }
        .onChange(of: isThinking) { _, thinking in
            guard !thinking, elapsedWhenFinished == nil else { return }
            if let startedAt {
                elapsedWhenFinished = max(1, Int(Date().timeIntervalSince(startedAt)))
            }
            // Deliberately does NOT collapse here — snapping the disclosure
            // shut while the user reads along was the single most annoying
            // reasoning behavior in the app.
        }
    }

    private func row(title: String) -> some View {
        ActivityRow(
            symbol: "brain",
            title: title,
            tint: Theme.reasoningAccent,
            isActive: isThinking,
            isExpanded: $isExpanded
        ) {
            Text(reasoning)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(at now: Date) -> String {
        if isThinking {
            let elapsed = Int(now.timeIntervalSince(startedAt ?? now))
            return "Thinking… \(elapsed)s"
        }
        if let elapsedWhenFinished {
            return "Thought for \(elapsedWhenFinished)s"
        }
        return "Reasoning"
    }
}

private struct AlternateStepper: View {
    @Binding var index: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            Button {
                index = min(index + 1, total - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index >= total - 1)

            Text("\(total - index)/\(total)")
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
                .monospacedDigit()

            Button {
                index = max(index - 1, 0)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index <= 0)
        }
        .buttonStyle(VelaIconButtonStyle())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.tertiaryText)
    }
}
