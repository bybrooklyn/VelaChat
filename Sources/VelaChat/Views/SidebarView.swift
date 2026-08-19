import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchQuery = ""
    @State private var isSearchExpanded = false
    @State private var renamingConversationID: UUID?
    @State private var renameText = ""
    @State private var pendingDeleteConversation: Conversation?
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var searchResults: [ConversationSearchResult] {
        ConversationSearch.results(for: trimmedQuery, in: appModel.conversations)
    }

    var body: some View {
        Group {
            if appModel.isSidebarRail {
                railBody
            } else {
                expandedBody
            }
        }
        .sidebarMaterial(tint: Theme.sidebarBackground)
        // No custom divider here — `NavigationSplitView` (RootView.swift)
        // already draws a native NSSplitView divider at this exact seam.
        // A hand-drawn fade+hairline used to sit on top of it, producing a
        // visibly doubled/misaligned border between the sidebar and chat
        // pane.
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size.width) { _, newValue in
                        // Only the expanded width is worth remembering, and
                        // only within the range the column actually allows.
                        // Persisting the rail's 60pt made the *expanded*
                        // sidebar come back too narrow to fit its own
                        // "New Chat" label.
                        guard !appModel.isSidebarRail, newValue >= 220, newValue <= 420 else { return }
                        UserDefaults.standard.set(newValue, forKey: DefaultsKey.sidebarWidth)
                    }
            }
        }
        .confirmationDialog(
            "Delete conversation?",
            isPresented: isDeleteConfirmationPresented,
            presenting: pendingDeleteConversation
        ) { conversation in
            Button("Delete", role: .destructive) {
                appModel.deleteConversation(conversation)
            }
        } message: { conversation in
            Text("“\(conversation.title)” will be deleted. This cannot be undone.")
        }
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)

            topActionsRow
                .padding(.horizontal, 10)
                .padding(.bottom, 14)

            conversationList

            settingsFooter
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    /// The narrow state: the same actions as icons with tooltips, plus the
    /// most recent conversations as compact glyphs, so you can still switch
    /// chats without expanding. The toggle keeps its exact shape and place
    /// in both states — it is the one control that must never move.
    private var railBody: some View {
        VStack(spacing: 8) {
            sidebarToggleButton
                .padding(.top, 10)

            railButton(symbol: "square.and.pencil", help: "New Chat (⌘N)", tint: Theme.accentStrong) {
                _ = appModel.newConversation()
                appModel.section = .chat
            }
            railButton(symbol: "magnifyingglass", help: "Search conversations (⇧⌘F)") {
                appModel.toggleSidebar()
                DispatchQueue.main.async {
                    isSearchExpanded = true
                    searchFocused = true
                }
            }
            UsageGaugeButton()

            Divider()
                .padding(.horizontal, 12)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(orderedConversations.prefix(14)) { conversation in
                        railConversationButton(conversation)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)

            railButton(symbol: "gearshape", help: "Settings (⌘,)") {
                appModel.section = .settings
            }
            .padding(.bottom, 12)
        }
        .frame(width: AppModel.sidebarRailWidth)
    }

    private func railButton(
        symbol: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint == nil ? Theme.secondaryText : Theme.accentForeground)
                .frame(width: 34, height: 34)
                .background(
                    tint ?? Theme.surfaceHigh,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .stroke(Theme.controlStroke.opacity(tint == nil ? 0.6 : 0), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// One conversation as a glyph. The title lives in the tooltip, and
    /// the active chat keeps the same accent treatment its full row has.
    private func railConversationButton(_ conversation: Conversation) -> some View {
        let selected = appModel.activeConversationID == conversation.id
        return Button {
            appModel.selectConversation(conversation)
        } label: {
            Image(systemName: conversation.isPinned ? "pin.fill" : (conversation.realMessages.isEmpty ? "bubble.left" : "text.bubble"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.tertiaryText)
                .frame(width: 34, height: 30)
                .background(
                    selected ? Theme.sidebarSelection.opacity(0.55) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(conversation.title)
    }

    /// Shared by both states so the control is literally the same view —
    /// same size, same chrome, same position at the top of the sidebar.
    private var sidebarToggleButton: some View {
        Button {
            appModel.toggleSidebar()
        } label: {
            Image(systemName: appModel.isSidebarRail ? "sidebar.leading" : "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceHigh, in: Circle())
                .overlay {
                    Circle().stroke(Theme.controlStroke.opacity(0.6), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(appModel.isSidebarRail ? "Expand Sidebar" : "Collapse to Icons")
    }

    /// Brand only. The new-chat action used to be crammed into this row right
    /// beside the system sidebar-toggle button, which made the whole corner
    /// read as two colliding buttons — it now has its own full-width row.
    private var sidebarHeader: some View {
        HStack(spacing: 11) {
            VelaMark(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("VelaChat")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(conversationCountLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer(minLength: 0)
            // The app's own sidebar toggle, opposite the wordmark — the
            // system toolbar (and its long band) is hidden entirely. Same
            // view the rail uses, so it keeps its shape across states.
            sidebarToggleButton
        }
    }

    private var conversationCountLabel: String {
        let count = appModel.conversations.count
        return count == 1 ? "1 conversation" : "\(count) conversations"
    }

    /// New Chat and search share one row — search collapses to a plain icon
    /// button until clicked, then expands in place to take the row (macOS's
    /// own collapsing-search-field pattern), instead of permanently reserving
    /// a full-width text field most of the time shows nothing typed into it.
    private var topActionsRow: some View {
        HStack(spacing: 8) {
            newChatButton
            if !isSearchExpanded {
                UsageGaugeButton()
            }
            if isSearchExpanded {
                searchField
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92, anchor: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else {
                searchToggleButton
            }
        }
        .animation(.easeOut(duration: 0.16), value: isSearchExpanded)
    }

    /// Not full-width on its own anymore — shares the row with search, so it
    /// grows to fill whatever space search isn't using.
    private var newChatButton: some View {
        Button {
            _ = appModel.newConversation()
            appModel.section = .chat
            searchQuery = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                Text("New Chat")
                    .font(.subheadline.weight(.semibold))
                if !isSearchExpanded {
                    Spacer(minLength: 0)
                    Text("⌘N")
                        .font(.caption2)
                        .foregroundStyle(Theme.accentForeground.opacity(0.6))
                }
            }
            .foregroundStyle(Theme.accentForeground)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: isSearchExpanded ? nil : .infinity, alignment: .leading)
            .background(Theme.accentStrong, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: isSearchExpanded ? nil : .infinity, alignment: .leading)
        .help("Start a new conversation (⌘N)")
    }

    private var searchToggleButton: some View {
        Button {
            isSearchExpanded = true
            DispatchQueue.main.async { searchFocused = true }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 34, height: 34)
                // Flat, matching `newChatButton`/`searchField` beside it —
                // a standalone `glassEffect` here (see Materials.swift)
                // rendered its own halo/shadow ring against those flat
                // siblings, reading as a stray box-in-a-box outline.
                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .help("Search conversations (⇧⌘F)")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(searchFocused ? Theme.accent : Theme.tertiaryText)
            TextField("Search messages and titles", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($searchFocused)
                .onExitCommand {
                    searchQuery = ""
                    searchFocused = false
                    isSearchExpanded = false
                }
            // Always present once expanded — not just when there's text to
            // clear — so there's an obvious, always-available way to close
            // search back down instead of only an unlabeled empty field.
            Button {
                searchQuery = ""
                searchFocused = false
                isSearchExpanded = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryText)
            .help("Close search (Esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .stroke(searchFocused ? Theme.accent.opacity(0.45) : Theme.controlStroke.opacity(0.6), lineWidth: 1)
        }
        .onChange(of: searchFocused) { _, focused in
            guard !focused, trimmedQuery.isEmpty else { return }
            isSearchExpanded = false
        }
    }

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteConversation != nil },
            set: { if !$0 { pendingDeleteConversation = nil } }
        )
    }

    /// Pinned conversations sort to the top of one continuous list — no
    /// "Pinned"/"Recent" section headers, no separate cap on how many can be
    /// pinned. A small pin glyph on the row itself (`ConversationRow`) is
    /// the only thing marking a conversation as pinned now.
    private var orderedConversations: [Conversation] {
        appModel.conversations.filter(\.isPinned) + appModel.conversations.filter { !$0.isPinned }
    }

    @ViewBuilder
    private var conversationList: some View {
        if isSearching {
            searchResultsList
        } else if appModel.conversations.isEmpty {
            VStack(spacing: 6) {
                Text("No conversations yet")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                Text("Start one with ⌘N")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            // A plain ScrollView + LazyVStack, not `List(selection:)` — on
            // macOS a selection-bound List is backed by NSTableView and
            // draws its own native "source list" selection highlight
            // underneath any custom row background, at a different inset
            // and corner radius than `ConversationRow`'s own fill. The two
            // overlapping rectangles read as a stray double outline around
            // the selected row. This mirrors `searchResultsList` below,
            // which already avoids `List` for exactly this reason.
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(orderedConversations) { conversation in
                        row(for: conversation)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                // Without an animation bound to the list change, the rows'
                // transitions never actually play — inserts (a new chat
                // earning its row) and removals both hard-cut.
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appModel.conversations.count)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
        }
    }

    /// Search is its own mode rather than a filtered title list: results are
    /// ranked, show which message matched, and highlight the term in context
    /// so you can tell *why* a conversation matched before opening it.
    @ViewBuilder
    private var searchResultsList: some View {
        let results = searchResults
        VStack(spacing: 0) {
            if !results.isEmpty {
                HStack {
                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            if results.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing matched “\(trimmedQuery)”.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(results) { result in
                            SearchResultRow(
                                result: result,
                                query: trimmedQuery,
                                selected: appModel.activeConversationID == result.conversation.id
                            ) {
                                appModel.selectConversation(result.conversation)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func row(for conversation: Conversation) -> some View {
        ConversationRow(
            conversation: conversation,
            selected: appModel.activeConversationID == conversation.id,
            renamingConversationID: $renamingConversationID,
            renameText: $renameText,
            onCommitRename: { appModel.renameConversation(conversation, to: renameText) }
        )
        .onTapGesture {
            if renamingConversationID != nil, renamingConversationID != conversation.id {
                renamingConversationID = nil
            }
            appModel.selectConversation(conversation)
        }
        .contextMenu {
            Button {
                appModel.togglePin(conversation)
            } label: {
                Label(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin")
            }
            Button {
                renameText = conversation.title
                renamingConversationID = conversation.id
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                appModel.regenerateTitle(for: conversation)
            } label: {
                Label("Regenerate Title", systemImage: "sparkles")
            }
            .disabled(!conversation.realMessages.contains { $0.role == "assistant" })
            Button {
                appModel.compactConversation(conversation)
            } label: {
                Label("Compact Conversation", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(conversation.isGenerating)
            Button {
                appModel.generateHandoffDocument(for: conversation)
            } label: {
                Label("Copy Handoff Document", systemImage: "arrow.turn.up.right")
            }
            Menu {
                Button("Markdown…") { ConversationExporter.exportMarkdown(conversation) }
                Button("PDF…") { ConversationExporter.exportPDF(conversation) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(conversation.isGenerating)
            Divider()
            Button(role: .destructive) {
                pendingDeleteConversation = conversation
            } label: {
                Label("Delete conversation", systemImage: "trash")
            }
        }
    }

    /// Outlined rather than a filled glass card — it reads as a quiet control
    /// anchored to the sidebar's bottom edge instead of a floating pane.
    private var settingsFooter: some View {
        Button {
            appModel.section = .settings
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 18)
                Text("Settings")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text("v\(AppModel.appVersion)")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .foregroundStyle(appModel.section == .settings ? Theme.accent : Theme.secondaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                appModel.section == .settings ? Theme.sidebarSelection.opacity(0.85) : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .stroke(
                        appModel.section == .settings ? Theme.accent.opacity(0.4) : Theme.controlStroke.opacity(0.75),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open Settings")
    }
}

// MARK: - Search

struct ConversationSearchResult: Identifiable {
    let conversation: Conversation
    /// The best matching message excerpt, if the match wasn't title-only.
    let excerpt: String?
    let matchCount: Int
    let score: Int

    var id: UUID { conversation.id }
}

@MainActor
enum ConversationSearch {
    /// Ranks title hits above body hits, prefers more matches, and pulls a
    /// window of text around the first body hit so the row can show context.
    static func results(for query: String, in conversations: [Conversation]) -> [ConversationSearchResult] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }

        return conversations.compactMap { conversation -> ConversationSearchResult? in
            let titleHit = conversation.title.lowercased().contains(needle)
            var matchCount = titleHit ? 1 : 0
            var excerpt: String?

            for message in conversation.realMessages {
                let lower = message.content.lowercased()
                guard lower.contains(needle) else { continue }
                matchCount += lower.components(separatedBy: needle).count - 1
                if excerpt == nil {
                    excerpt = snippet(from: message.content, around: needle)
                }
            }

            guard matchCount > 0 else { return nil }
            var score = matchCount
            if titleHit { score += 40 }
            if conversation.isPinned { score += 10 }
            return ConversationSearchResult(
                conversation: conversation,
                excerpt: excerpt,
                matchCount: matchCount,
                score: score
            )
        }
        .sorted { $0.score > $1.score }
    }

    /// ~90 characters centred on the hit, trimmed to whole words.
    private static func snippet(from content: String, around needle: String) -> String {
        guard let range = content.lowercased().range(of: needle) else {
            return String(content.prefix(90))
        }
        let padding = 42
        let lower = content.index(range.lowerBound, offsetBy: -padding, limitedBy: content.startIndex) ?? content.startIndex
        let upper = content.index(range.upperBound, offsetBy: padding, limitedBy: content.endIndex) ?? content.endIndex
        var text = String(content[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
        text = text.trimmingCharacters(in: .whitespaces)
        if lower != content.startIndex { text = "…" + text }
        if upper != content.endIndex { text += "…" }
        return text
    }

    /// Bolds and tints every occurrence of the query inside a snippet.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let found = attributed[searchRange].range(of: query, options: .caseInsensitive) {
            attributed[found].foregroundColor = Theme.accent
            attributed[found].inlinePresentationIntent = .stronglyEmphasized
            guard found.upperBound < attributed.endIndex else { break }
            searchRange = found.upperBound..<attributed.endIndex
        }
        return attributed
    }
}

private struct SearchResultRow: View {
    let result: ConversationSearchResult
    let query: String
    let selected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(ConversationSearch.highlighted(result.conversation.title, query: query))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if result.matchCount > 1 {
                        Text("\(result.matchCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.controlBackground, in: Capsule())
                    }
                }
                if let excerpt = result.excerpt {
                    Text(ConversationSearch.highlighted(excerpt, query: query))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("Title match")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected ? Theme.sidebarSelection : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .stroke(
                        selected ? Color.clear : Theme.controlStroke.opacity(isHovering ? 0.9 : 0.35),
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let selected: Bool
    @Binding var renamingConversationID: UUID?
    @Binding var renameText: String
    let onCommitRename: () -> Void

    @State private var isHovering = false
    @State private var displayedTitle: String = ""
    @State private var typewriterTask: Task<Void, Never>?

    private var isRenaming: Bool { renamingConversationID == conversation.id }

    /// Erases the old title one character at a time, then types the new
    /// one back in, instead of an instant swap — runs whenever
    /// `conversation.title` changes (auto-generated after the first
    /// exchange, or a manual "Regenerate Title"/rename).
    private func animateTitleChange(to newValue: String) {
        typewriterTask?.cancel()
        typewriterTask = Task { @MainActor in
            while !displayedTitle.isEmpty {
                if Task.isCancelled { return }
                displayedTitle.removeLast()
                try? await Task.sleep(nanoseconds: 7_000_000)
            }
            for character in newValue {
                if Task.isCancelled { return }
                displayedTitle.append(character)
                try? await Task.sleep(nanoseconds: 9_000_000)
            }
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: conversation.realMessages.isEmpty ? "bubble.left" : "text.bubble")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.tertiaryText)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Title", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.subheadline.weight(.medium))
                        .onSubmit {
                            onCommitRename()
                            renamingConversationID = nil
                        }
                        .onExitCommand { renamingConversationID = nil }
                } else {
                    HStack(spacing: 6) {
                        Text(displayedTitle)
                            .font(.subheadline.weight(selected ? .medium : .regular))
                            .foregroundStyle(selected ? Theme.text : Theme.secondaryText)
                            .lineLimit(1)
                            .onAppear { displayedTitle = conversation.title }
                            .onChange(of: conversation.title) { _, newValue in
                                animateTitleChange(to: newValue)
                            }
                        if conversation.isGenerating && !selected {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 5, height: 5)
                                .symbolEffectPulse()
                        }
                    }
                }
                if !conversation.realMessages.isEmpty {
                    Text(conversation.lastMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if conversation.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        // Selected rows are filled; everything else always shows a faint
        // hairline outline, brightening on hover — a fully-invisible resting
        // state read as "rows with no border at all" rather than a calm
        // column of unobtrusive ones.
        .background(
            selected ? Theme.sidebarSelection : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .stroke(
                    selected ? Color.clear : Theme.controlStroke.opacity(isHovering ? 0.9 : 0.35),
                    lineWidth: 1
                )
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onDisappear { typewriterTask?.cancel() }
    }
}
