import SwiftUI
import AppKit
import MarkdownUI

/// The plus button's glass menu: file, GitHub repo (only when the gh CLI
/// is installed and logged in), clipboard, and a cloud page that morphs in
/// with providers marked coming-soon.
struct AttachMenu: View {
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

struct MenuRowButtonStyle: ButtonStyle {
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
struct AttachPlusButtonStyle: ButtonStyle {
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

struct SendButtonBackground: ViewModifier {
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

struct SendButtonStyle: ButtonStyle {
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

/// The `/` menu — built-in actions, saved prompt snippets, and Skills in one
/// filtered list, matching how claude.ai's own slash-command menu combines
/// the same three kinds of things rather than keeping them separate.
struct SlashCommandList: View {
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
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
struct ChatFindBar: View {
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

/// Bookmarked replies within this conversation — distinct from pinning the
/// whole conversation in the sidebar — jump back to directly instead of
/// scrolling to find them again.
struct PinnedMessagesButton: View {
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
