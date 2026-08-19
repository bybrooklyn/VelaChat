import SwiftUI
import AppKit

struct ChatView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(WindowChrome.self) private var chrome
    @State private var lastScrollAt = Date.distantPast
    @FocusState private var inputFocused: Bool

    /// Content is capped wide enough to read comfortably without becoming the
    /// narrow column it used to be — the old 720pt cap wasted most of the
    /// window on any reasonably sized display.
    private let contentWidth: CGFloat = 880

    private var input: Binding<String> {
        Binding(
            get: { appModel.activeConversation?.draftText ?? "" },
            set: { appModel.activeConversation?.draftText = $0 }
        )
    }

    private let suggestions = [
        "Summarize this idea in three bullets",
        "Help me think through a hard decision",
        "Write a clean first draft"
    ]

    private var topBarHeight: CGFloat { chrome.isFullScreen ? 44 : 52 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if let conversation = appModel.activeConversation, !conversation.messages.isEmpty {
                        ForEach(conversation.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    } else {
                        welcome
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 20)
                .padding(.bottom, 26)
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity)
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: appModel.activeConversation?.messages.count ?? 0)
            }
            // Reserves room under the floating glass header so the first
            // message never starts underneath it.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: topBarHeight)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
            .onChange(of: appModel.activeConversation?.messages.count ?? 0) { _, _ in
                scrollToLast(proxy)
            }
            .onChange(of: appModel.activeConversation?.messages.last?.content.count ?? 0) { _, _ in
                let now = Date()
                guard now.timeIntervalSince(lastScrollAt) > 0.12 else { return }
                lastScrollAt = now
                scrollToLast(proxy, animated: false)
            }
        }
        .overlay(alignment: .top) { chatTopBar }
        .task { inputFocused = true }
    }

    /// A real glass header pinned above the transcript. Without it, message
    /// text scrolled straight into the empty titlebar strip and the two
    /// visually merged — there was nothing separating content from chrome.
    private var chatTopBar: some View {
        HStack(spacing: 10) {
            // Native fullscreen hides traffic lights system-wide — no app can
            // override that — so this is a real, always-reachable substitute
            // rather than an attempt to fake the OS control.
            if chrome.isFullScreen {
                ExitFullScreenButton()
            }

            Text(appModel.activeConversation?.title ?? "New conversation")
                .font(.headline)
                .foregroundStyle(Theme.text)
                .lineLimit(1)

            if appModel.isGenerating {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 12)

            if let conversation = appModel.activeConversation, !conversation.messages.isEmpty {
                Text("\(conversation.messages.count) message\(conversation.messages.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .frame(height: topBarHeight, alignment: .bottom)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Theme.background.opacity(0.55)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator.opacity(0.4))
                .frame(height: 1)
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
            providerReadout
                .padding(.top, 2)
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        input.wrappedValue = suggestion
                        inputFocused = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 5)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    @ViewBuilder
    private var providerReadout: some View {
        if let provider = appModel.selectedProvider {
            Button {
                if provider.kind == .preview {
                    appModel.section = .settings
                }
            } label: {
                HStack(spacing: 7) {
                    ProviderMark(kind: provider.kind, size: 14)
                    Text(provider.name)
                        .font(.caption.weight(.semibold))
                    Text("·")
                        .foregroundStyle(Theme.tertiaryText)
                    Text(provider.kind == .preview ? "Connect a provider for live replies" : provider.kind.shortDescription)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(provider.kind == .preview ? Theme.accent : Theme.secondaryText)
            .help(provider.kind == .preview ? "Open Settings" : provider.kind.shortDescription)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let error = appModel.lastError {
                HStack(spacing: 7) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        appModel.lastError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
                .frame(maxWidth: 720)
            }

            VStack(alignment: .leading, spacing: 10) {
                // Sized by its own content: one line at rest, growing only as
                // the message does, instead of reserving a fixed tall block.
                TextField("Message", text: input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...12)
                    .focused($inputFocused)
                    .onSubmit { send() }
                    .padding(.horizontal, 6)
                    .padding(.top, 2)

                VelaGlassContainer {
                    HStack(spacing: 7) {
                        ModelPickerButton()
                        if appModel.availableThinkingLevels.count > 1 {
                            ThinkingPickerButton()
                        }
                        ContextButton()
                        if appModel.canUseWebSearch {
                            WebSearchToggleButton()
                        }
                        Spacer(minLength: 8)
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
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: contentWidth)
            .nativeMaterial(cornerRadius: Theme.Radius.composer)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
                    .stroke(Theme.accent.opacity(inputFocused ? 0.5 : 0.16), lineWidth: inputFocused ? 1.4 : 1)
            }
            .animation(.easeOut(duration: 0.18), value: inputFocused)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(Theme.background.opacity(0.92))
    }

    private var canSend: Bool {
        !input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appModel.isGenerating
    }

    private func send() {
        guard canSend else { return }
        appModel.send(input.wrappedValue)
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id = appModel.activeConversation?.messages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

/// Muted outline when there's nothing to send, solid filled accent once
/// there is, and a filled stop target while a reply is streaming — one
/// control that communicates all three states in place.
private struct SendButtonStyle: ButtonStyle {
    let isReady: Bool
    var isStopping = false

    private var fill: Color {
        if isStopping { return Theme.text.opacity(0.92) }
        return isReady ? Theme.accentStrong : .clear
    }

    private var foreground: Color {
        if isStopping { return Theme.background }
        return isReady ? Theme.accentForeground : Theme.tertiaryText
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 30)
            .background {
                Circle().fill(fill)
            }
            .overlay {
                if !isReady && !isStopping {
                    Circle().stroke(Theme.controlStroke.opacity(0.7), lineWidth: 1.2)
                }
            }
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

    var body: some View {
        if message.role == "user" {
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 120)
                if isHovering, !isEditing {
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
                }
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
                        .padding(.vertical, 10)
                        .frame(minWidth: 220)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                    } else {
                        RichMessageText(text: message.content, isUser: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                    }
                }
            }
            .onHover { isHovering = $0 }
        } else {
            HStack(alignment: .top, spacing: 11) {
                VelaMark(size: 23)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(appModel.selectedProvider?.name ?? "Assistant")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                        if message.isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Spacer()
                        if totalVersions > 1 {
                            AlternateStepper(index: $alternateIndex, total: totalVersions)
                        }
                    }

                    if alternateIndex == 0, let record = appModel.searchByMessage[message.id] {
                        SearchResultsDisclosure(record: record, isExpanded: $showingSearchResults)
                    }

                    if let reasoning = displayedMessage.reasoning, !reasoning.isEmpty {
                        ReasoningDisclosure(
                            reasoning: reasoning,
                            isThinking: alternateIndex == 0 && message.isStreaming && displayedMessage.content.isEmpty,
                            isExpanded: $showingReasoning
                        )
                    }

                    if let error = displayedMessage.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.danger)
                            if alternateIndex == 0 {
                                Button("Try Again") { appModel.retryLastMessage() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        RichMessageText(text: displayedMessage.content, isUser: false)
                        if let usage = appModel.usageByMessage[displayedMessage.id]?.label {
                            Text(usage)
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }

                    if !message.isStreaming {
                        MessageActionRow(
                            message: message,
                            displayedMessage: displayedMessage,
                            canRegenerate: alternateIndex == 0
                        )
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                        .animation(.easeOut(duration: 0.15), value: isHovering)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onHover { isHovering = $0 }
        }
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
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.tertiaryText)
                .disabled(appModel.isGenerating)
                .help("Regenerate")
            }
            if !displayedMessage.content.isEmpty {
                Button {
                    appModel.toggleReadAloud(displayedMessage)
                } label: {
                    Image(systemName: appModel.speakingMessageID == displayedMessage.id ? "stop.circle" : "speaker.wave.2")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(appModel.speakingMessageID == displayedMessage.id ? Theme.accent : Theme.tertiaryText)
                .help(appModel.speakingMessageID == displayedMessage.id ? "Stop reading" : "Read aloud")

                ShareButton(text: displayedMessage.content)
                    .frame(width: 15, height: 15)
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
        let button = NSButton(
            image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share") ?? NSImage(),
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
                    Link(destination: URL(string: result.url) ?? URL(string: "https://\(result.url)")!) {
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
                        .padding(.vertical, 7)
                        .background(Theme.controlBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
                    }
                    .buttonStyle(.plain)
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
        TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
            ActivityRow(
                symbol: "brain",
                title: label(at: context.date),
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
        .onAppear {
            if isThinking, startedAt == nil { startedAt = Date() }
        }
        .onChange(of: isThinking) { _, thinking in
            guard !thinking, elapsedWhenFinished == nil else { return }
            if let startedAt {
                elapsedWhenFinished = max(1, Int(Date().timeIntervalSince(startedAt)))
            }
            isExpanded = false
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
        .buttonStyle(.plain)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.tertiaryText)
    }
}
