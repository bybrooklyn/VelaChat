import SwiftUI
import VelaCore

private enum PaletteItem: Identifiable, Equatable {
    case newConversation
    case openSettings
    case conversation(Conversation)

    var id: String {
        switch self {
        case .newConversation: "action.new"
        case .openSettings: "action.settings"
        case .conversation(let conversation): "conv.\(conversation.id.uuidString)"
        }
    }

    static func == (lhs: PaletteItem, rhs: PaletteItem) -> Bool { lhs.id == rhs.id }
}

/// A Spotlight-style ⌘K palette: search and jump straight to a conversation,
/// or run one of a small set of fixed actions.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var searchFocused: Bool

    private var actionItems: [PaletteItem] { [.newConversation, .openSettings] }

    private var filteredItems: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchingActions = actionItems.filter { trimmed.isEmpty || title(for: $0).lowercased().contains(trimmed) }
        let matchingConversations: [PaletteItem]
        if trimmed.isEmpty {
            matchingConversations = Array(appModel.conversations.prefix(8)).map { .conversation($0) }
        } else {
            matchingConversations = appModel.conversations
                .filter { conversation in
                    conversation.title.lowercased().contains(trimmed) ||
                    conversation.realMessages.contains { $0.content.lowercased().contains(trimmed) }
                }
                .map { .conversation($0) }
        }
        return matchingActions + matchingConversations
    }

    private func title(for item: PaletteItem) -> String {
        switch item {
        case .newConversation: "New Conversation"
        case .openSettings: "Open Settings"
        case .conversation(let conversation): conversation.title
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiaryText)
                TextField("Search conversations or actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
            }
            .padding(14)

            Divider()

            let items = filteredItems
            if items.isEmpty {
                Text("No matches")
                    .foregroundStyle(Theme.secondaryText)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            PaletteRow(title: title(for: item), item: item, selected: selectedID == item.id) {
                                activate(item)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 480)
        .nativeMaterial(cornerRadius: Theme.Radius.card)
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onAppear {
            searchFocused = true
            selectedID = filteredItems.first?.id
        }
        .onChange(of: query) { _, _ in
            selectedID = filteredItems.first?.id
        }
        .onKeyPress(.return) {
            if let selectedID, let item = filteredItems.first(where: { $0.id == selectedID }) {
                activate(item)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
    }

    private func moveSelection(by offset: Int) {
        let items = filteredItems
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        let newIndex = max(0, min(items.count - 1, currentIndex + offset))
        selectedID = items[newIndex].id
    }

    private func activate(_ item: PaletteItem) {
        switch item {
        case .newConversation:
            _ = appModel.newConversation()
            appModel.section = .chat
        case .openSettings:
            appModel.section = .settings
        case .conversation(let conversation):
            appModel.selectConversation(conversation)
        }
        isPresented = false
    }
}

private struct PaletteRow: View {
    let title: String
    let item: PaletteItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(selected ? Theme.sidebarSelection : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch item {
        case .newConversation: "square.and.pencil"
        case .openSettings: "slider.horizontal.3"
        case .conversation: "text.bubble"
        }
    }

    private var subtitle: String? {
        if case .conversation(let conversation) = item { return conversation.lastMessage }
        return nil
    }
}
