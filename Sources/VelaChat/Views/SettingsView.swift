import SwiftUI
import Combine
import VelaCore
import AppKit
import KeyboardShortcuts

/// The selectable Settings panes. Each selection renders exactly one pane;
/// there is no scroll-position-derived navigation state.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case providers = "Providers"
    case instructions = "Instructions"
    case memory = "Memory"
    case skills = "Skills"
    case snippets = "Snippets"
    case webSearch = "Web Search"
    case tools = "Tools"
    case agentAbilities = "Agent Abilities"
    case mcpServers = "MCP Servers"
    case privacy = "Privacy"
    case statistics = "Usage & Limits"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .providers: "server.rack"
        case .instructions: "person.text.rectangle"
        case .memory: "archivebox"
        case .skills: "puzzlepiece"
        case .snippets: "text.badge.plus"
        case .webSearch: "globe"
        case .tools: "wrench.and.screwdriver"
        case .agentAbilities: "slider.horizontal.3"
        case .mcpServers: "puzzlepiece.extension"
        case .privacy: "hand.raised"
        case .general: "gearshape"
        case .statistics: "chart.bar.xaxis"
        case .about: "info.circle"
        }
    }
}

/// Cross-view entry points into Settings. The pending destination is retained
/// until `SettingsView` appears, so callers do not have to guess whether the
/// root section switch has installed its notification subscriber yet.
@MainActor
enum SettingsNavigator {
    fileprivate static let requestNotification = Notification.Name("VelaChat.SettingsDestinationRequested")
    private static var pendingSection: SettingsSection?

    static func openUsageAndLimits(in appModel: AppModel) {
        pendingSection = .statistics
        appModel.section = .settings
        NotificationCenter.default.post(name: requestNotification, object: nil)
    }

    fileprivate static func takePendingSection() -> SettingsSection? {
        defer { pendingSection = nil }
        return pendingSection
    }
}

private enum SettingsCategoryGroup: String, CaseIterable, Identifiable {
    case app = "App"
    case personalization = "Personalization"
    case capabilities = "Capabilities"
    case privacyAndData = "Privacy & Data"

    var id: String { rawValue }

    var sections: [SettingsSection] {
        switch self {
        case .app:
            [.general, .providers, .about]
        case .personalization:
            [.instructions, .memory, .skills, .snippets]
        case .capabilities:
            [.webSearch, .tools, .agentAbilities, .mcpServers]
        case .privacyAndData:
            [.privacy, .statistics]
        }
    }
}

/// One pane card on the shared `SettingsPanel` chrome. Inactive cards return
/// `EmptyView`, so the existing inline controls can stay near their actions
/// without rendering a hidden stack of every category.
private struct SettingsCard<Content: View>: View {
    let section: SettingsSection
    let isVisible: Bool
    var footer: Text? = nil
    @ViewBuilder var content: () -> Content

    init(
        section: SettingsSection,
        isVisible: Bool,
        footer: Text? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.section = section
        self.isVisible = isVisible
        self.footer = footer
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if isVisible {
            SettingsPanel(title: section.rawValue, symbol: section.symbol, footer: footer, content: content)
        }
    }
}

/// The `run_command` prefix rules remembered for the attached folder, and
/// the only way to take them back. Read into `@State` rather than off
/// `CommandTrust` on every body pass, so forgetting them redraws.
private struct CommandTrustRow: View {
    let folderPath: String
    @State private var rules: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if rules.isEmpty {
                Text("No always-allowed commands remembered for \((folderPath as NSString).lastPathComponent).")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Text("Always allowed in \((folderPath as NSString).lastPathComponent): \(rules.map { "\($0)…" }.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Forget These Command Rules") {
                    CommandTrust.forget(folderPath: folderPath)
                    rules = []
                }
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(Theme.warning)
                .accessibilityLabel("Forget the remembered always-allowed commands for this folder")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { rules = CommandTrust.rules(for: folderPath) }
    }
}

/// Where Settings currently is. Deliberately *not* a `NavigationStack`
/// path: a `NavigationStack` nested in `NavigationSplitView`'s detail
/// column caused two verified bugs. (1) While a destination was pushed it
/// held the detail pane open, so switching `AppModel.section` away from
/// `.settings` — clicking New Chat in the sidebar, say — changed the state
/// but left Settings on screen until the push was popped. (2) Pushing
/// installed the stack's own navigation bar into the window titlebar,
/// which changed the safe-area inset and visibly shifted every pane
/// (traffic lights, sidebar, header) the moment a provider was opened.
/// Owning the route ourselves keeps one header in one place at all times
/// and lets the section swap happen immediately.
private enum SettingsRoute: Hashable {
    case root
    case provider(UUID)
    case changelog

    var title: String {
        switch self {
        case .root: "Settings"
        case .provider: "Provider"
        case .changelog: "What's New"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(WindowChrome.self) private var chrome
    @State private var route: SettingsRoute = .root
    @State private var isAddingSnippet = false
    @State private var isAddingProvider = false
    @State private var activeSection: SettingsSection = .general
    @State private var newMemoryText = ""

    private var topBarHeight: CGFloat { chrome.isFullScreen ? 44 : 52 }

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width - SettingsMetrics.categorySidebarWidth
                < SettingsMetrics.minimumDetailWidth
            VStack(spacing: 0) {
                header(isCompact: isCompact)
                routeContent(isCompact: isCompact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $isAddingSnippet) {
            AddSnippetSheet(isPresented: $isAddingSnippet)
        }
        .sheet(isPresented: $isAddingProvider) {
            AddProviderSheet(isPresented: $isAddingProvider) { newID in
                activeSection = .providers
                route = .provider(newID)
            }
        }
        .onAppear { applyPendingDestination() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigator.requestNotification)) { _ in
            applyPendingDestination()
        }
    }

    /// One title, one back button, one position — for every route. The back
    /// button steps up a level and only leaves Settings from the root, so
    /// Esc always means "up", never "somewhere unpredictable".
    private var headerTitle: String {
        if case .provider(let id) = route {
            return appModel.providers.profile(id: id)?.name ?? "Provider"
        }
        return route.title
    }

    private var backHelp: String {
        route == .root ? "Back to conversations (Esc)" : "Back to Settings (Esc)"
    }

    /// Wide windows keep the category list visible while a provider or the
    /// changelog is open. Compact windows move that selector into the root
    /// header so the detail pane never gets squeezed below its readable
    /// width.
    private func routeContent(isCompact: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if !isCompact {
                categorySidebar
            }
            routeBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: SettingsMetrics.shellWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var routeBody: some View {
        switch route {
        case .root:
            settingsForm
                .transition(.opacity)
        case .provider(let id):
            ProviderEditorView(profileID: id, onBack: { goBack() })
                .transition(.opacity)
        case .changelog:
            ChangelogView()
                .transition(.opacity)
        }
    }

    private func goBack() {
        if route == .root {
            appModel.section = .chat
        } else {
            withAnimation(.easeOut(duration: 0.18)) { route = .root }
        }
    }

    /// Matches the chat pane's glass header so the two panes read as one app
    /// rather than two differently-chromed screens.
    private func header(isCompact: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accentForeground)
                    .frame(width: 30, height: 30)
                    .glassCircle(tint: Theme.accentStrong)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(backHelp)
            .accessibilityLabel(backHelp)

            Text(headerTitle)
                .font(.headline)
                .foregroundStyle(Theme.text)
                .padding(.leading, 4)
                // The title is the only thing in this bar that changes
                // between routes, and it crossfades in place instead of the
                // bar itself moving or resizing.
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.18), value: headerTitle)

            Spacer(minLength: 0)

            if isCompact, route == .root {
                categoryMenu
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: topBarHeight, alignment: .center)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator.opacity(0.4))
                .frame(height: 1)
        }
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(SettingsCategoryGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.sections) { section in
                        Button {
                            selectSection(section)
                        } label: {
                            Label(section.rawValue, systemImage: section.symbol)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: activeSection.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 15)
                Text(activeSection.rawValue)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                Theme.surfaceHigh.opacity(0.72),
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
            .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose a Settings category")
        .accessibilityLabel("Settings category")
        .accessibilityValue(activeSection.rawValue)
    }

    private var categorySidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(SettingsCategoryGroup.allCases) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .textCase(.uppercase)
                            .padding(.horizontal, 10)
                        ForEach(group.sections) { section in
                            Button {
                                selectSection(section)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: section.symbol)
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 17)
                                    Text(section.rawValue)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(SettingsNavigationButtonStyle(isSelected: activeSection == section))
                            .accessibilityLabel(section.rawValue)
                            .accessibilityAddTraits(activeSection == section ? .isSelected : [])
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 18)
        }
        .frame(width: SettingsMetrics.categorySidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.surfaceLow.opacity(0.32))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.separator.opacity(0.4))
                .frame(width: 1)
        }
    }

    private func selectSection(_ section: SettingsSection) {
        activeSection = section
        if route != .root {
            withAnimation(.easeOut(duration: 0.18)) { route = .root }
        }
    }

    private func applyPendingDestination() {
        guard let section = SettingsNavigator.takePendingSection() else { return }
        activeSection = section
        route = .root
    }

    private var settingsForm: some View {
        @Bindable var appModel = appModel
        return Group {
            if activeSection == .statistics {
                StatisticsView()
            } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                    SettingsCard(section: .general, isVisible: activeSection == .general, footer: Text("Messages are never relayed through an app-owned server.")) {
                        GeneralCard()
                    }


                    SettingsCard(section: .providers, isVisible: activeSection == .providers, footer: Text("Keys stay in your macOS Keychain. Requests go straight to the provider.")) {

                ForEach(visibleProfiles) { profile in
                    // Viewing a provider must not switch to it — selection
                    // is an explicit action inside the editor now.
                    Button {
                        activeSection = .providers
                        withAnimation(.easeOut(duration: 0.18)) { route = .provider(profile.id) }
                    } label: {
                        ProviderSettingsRow(
                            profile: profile,
                            status: appModel.providers.status(for: profile.id),
                            isActive: appModel.providers.selectedID == profile.id,
                            hasKey: appModel.providers.hasStoredKey(for: profile.id)
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .contextMenu {
                        if profile.kind == .compatible {
                            Button(role: .destructive) {
                                appModel.providers.remove(id: profile.id)
                            } label: {
                                Label("Remove endpoint", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    isAddingProvider = true
                } label: {
                    Label("Add a custom OpenAI-compatible endpoint", systemImage: "plus.circle")
                }
                .buttonStyle(SettingsAddButtonStyle())
                    }


                    SettingsCard(section: .instructions, isVisible: activeSection == .instructions, footer: Text("Sent invisibly with every message \u{2014} who you are and how the model should respond.")) {

                TextEditor(text: $appModel.customInstructions)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 180)
                    .settingsMultilineFieldStyle()
                    }


                    SettingsCard(section: .memory, isVisible: activeSection == .memory, footer: Text("Durable facts about you \u{2014} stable preferences, standing constraints, things still true next month. Written by the model as you chat, kept on this Mac, yours to edit or remove.")) {

                if appModel.facts.isEmpty {
                    SettingsEmptyState(
                        text: "Nothing remembered yet — the model saves durable facts as you chat.",
                        symbol: "archivebox"
                    )
                } else {
                    ForEach(memoryTopics, id: \.self) { topic in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(topic)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.tertiaryText)
                            ForEach(appModel.facts.filter { $0.displayTopic == topic }) { fact in
                                MemoryFactRow(fact: fact)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                HStack(spacing: 8) {
                    TextField("Add a memory…", text: $newMemoryText, axis: .vertical)
                        .settingsFieldStyle()
                    Button("Add") {
                        appModel.addMemory(newMemoryText)
                        newMemoryText = ""
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Divider()
                ConversationIndexRow()
                Divider()
                RemoteEmbeddingRow()
                    }


                    SettingsCard(section: .skills, isVisible: activeSection == .skills, footer: Text("Add any folder containing a SKILL.md \u{2014} the same format Claude Code and Codex use. Invoke one from the / menu.")) {

                if appModel.skills.skills.isEmpty {
                    SettingsEmptyState(text: "No skills added yet.", symbol: "puzzlepiece")
                } else {
                    ForEach(appModel.skills.skills) { skill in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(skill.name)
                                    .font(.callout.weight(.medium))
                            }
                            Text(skill.description)
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                            if let tools = skill.allowedTools, !tools.isEmpty {
                                Text("Allowed tools: \(tools.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button(role: .destructive) {
                                appModel.skills.removeCustomFolder(skill.folderPath)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                if !appModel.skills.failedPaths.isEmpty {
                    Text("Couldn't read a SKILL.md in: \(appModel.skills.failedPaths.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                }
                Button {
                    addSkillFolder()
                } label: {
                    Label("Add a Skill Folder…", systemImage: "plus.circle")
                }
                .buttonStyle(SettingsAddButtonStyle())
                    }


                    SettingsCard(section: .snippets, isVisible: activeSection == .snippets, footer: Text("Save a prompt once, reuse it from the / menu.")) {

                if appModel.promptSnippets.isEmpty {
                    SettingsEmptyState(text: "No snippets saved yet.", symbol: "text.badge.plus")
                } else {
                    ForEach(appModel.promptSnippets) { snippet in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.name)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.accent)
                            Text(snippet.body)
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button(role: .destructive) {
                                appModel.removeSnippet(snippet)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .transition(.opacity)
                    }
                }
                Button {
                    isAddingSnippet = true
                } label: {
                    Label("Add a Snippet…", systemImage: "plus.circle")
                }
                .buttonStyle(SettingsAddButtonStyle())
                    }


                    SettingsCard(section: .webSearch, isVisible: activeSection == .webSearch, footer: Text("A SearXNG fallback for providers without built-in search (pick one from searx.space). Toggle search on in the composer.")) {

                LabeledContent("Fallback search") {
                    TextField("https://searx.example.org", text: $appModel.searchEndpoint)
                        .settingsFieldStyle()
                        .textContentType(.URL)
                        .frame(maxWidth: 320)
                }
                    }


                    SettingsCard(section: .tools, isVisible: activeSection == .tools, footer: Text("Lets tool-capable models search your past conversations and work in a workspace folder — the private per-conversation one, or a real folder you attach from the + menu.")) {

                Toggle("Workspace files", isOn: $appModel.isWorkspaceEnabled)
                Toggle("Conversation search", isOn: $appModel.isConversationSearchEnabled)
                Toggle("Calendar & reminders", isOn: $appModel.isScheduleToolEnabled)
                Toggle("Clipboard", isOn: $appModel.isClipboardToolEnabled)
                if let conversation = appModel.activeConversation {
                    Button("Reveal This Conversation's Workspace in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([conversation.workspaceRoot])
                    }
                    .buttonStyle(VelaIconButtonStyle())
                    .foregroundStyle(Theme.accent)
                    if conversation.workspaceRootPath != nil {
                        Button("Detach Folder (back to the private workspace)") {
                            appModel.clearWorkspaceRoot(for: conversation)
                        }
                        .buttonStyle(VelaIconButtonStyle())
                        .foregroundStyle(Theme.secondaryText)
                    }
                }
                    }

                    SettingsCard(section: .agentAbilities, isVisible: activeSection == .agentAbilities, footer: Text("Agent abilities let the model plan visible multi-step work and edit/search files in the workspace. Read-only commands (ls, cat, rg, git status…) run immediately; anything else pauses for your approval in the chat, showing the exact command and folder first. Commands you always-allow run unsandboxed as you — a build or test command executes project code, including code the model just wrote.")) {
                Toggle("Planning, file editing & search", isOn: $appModel.isAgentToolsEnabled)
                // Bound to the EFFECTIVE state, not the raw stored bool: a
                // chat with a project folder attached has commands on
                // whether or not this switch was ever touched (see
                // `AppModel.isCommandToolAvailable`), and a switch reading
                // "off" beside a model that is running commands is the kind
                // of quiet disagreement nobody forgives. Writing either
                // value makes the choice explicit and it wins from then on.
                Toggle("Run shell commands (with approval)", isOn: Binding(
                    get: {
                        appModel.activeConversation.map { appModel.isCommandToolAvailable(for: $0) }
                            ?? appModel.isCommandToolEnabled
                    },
                    set: { appModel.isCommandToolEnabled = $0 }
                ))
                if !Defaults.has(DefaultsKey.commandToolEnabled),
                   let conversation = appModel.activeConversation,
                   conversation.commandTrustFolderPath != nil {
                    Text("On because this chat has a project folder attached. Switch it off here to keep commands off everywhere.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Offer planning mode for big requests", isOn: $appModel.isPlanningSuggestionEnabled)
                Toggle("Parallel subagents", isOn: $appModel.isSubagentsEnabled)
                if appModel.isSubagentsEnabled {
                    Toggle("Ask before each fan-out", isOn: $appModel.isSubagentApprovalRequired)
                    LabeledContent("Subagent model") {
                        TextField("Same as the chat's model", text: $appModel.subagentModelOverride)
                            .settingsFieldStyle()
                            .frame(maxWidth: 240)
                    }
                }
                if let conversation = appModel.activeConversation,
                   let folder = conversation.commandTrustFolderPath {
                    CommandTrustRow(folderPath: folder)
                }
                if let conversation = appModel.activeConversation, conversation.allowAllCommands {
                    Button("Revoke \u{201C}allow all commands\u{201D} for this chat") {
                        conversation.allowAllCommands = false
                        conversation.alwaysAllowedCommands.removeAll()
                    }
                    .buttonStyle(VelaIconButtonStyle())
                    .foregroundStyle(Theme.warning)
                }
                    }


                    SettingsCard(section: .mcpServers, isVisible: activeSection == .mcpServers, footer: Text("MCP servers run as local processes with your account, and their tools run without per-call confirmation \u{2014} add only servers you trust. Enabled servers start and verify lazily when a send needs their tools; \u{201C}unverified\u{201D} is not a health check. Standard mcpServers JSON works here.")) {
                        McpServersCard()
                    }

                    SettingsCard(section: .privacy, isVisible: activeSection == .privacy, footer: Text("Redaction rewrites matches before a message leaves your Mac, and marks what it changed in the transcript. Local-only mode refuses every request to a non-loopback host at the network layer, not just in the provider picker.")) {
                        PrivacyCard()
                    }

                    SettingsCard(section: .about, isVisible: activeSection == .about) {

                HStack(spacing: 12) {
                    VelaMark(size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VelaChat")
                            .font(.headline)
                        Text("Version \(Self.bundleVersion)")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.vertical, 4)
                SettingsDisclosureRow(
                    title: "What's New",
                    symbol: "sparkles"
                ) {
                    activeSection = .about
                    withAnimation(.easeOut(duration: 0.18)) { route = .changelog }
                }
                Link(destination: URL(string: "https://opensource.org/license/mit") ?? URL(fileURLWithPath: "/")) {
                    Label("MIT license \u{2014} free and open source", systemImage: "arrow.up.right.square")
                }
                .foregroundStyle(Theme.accent)
                    }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: SettingsMetrics.columnWidth)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .id(activeSection)
            }
        }
    }

    /// The real bundle version — the hardcoded constant is only the
    /// fallback for `swift run`, where no bundle exists.
    private static var bundleVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? AppModel.appVersion
    }

    private var memoryTopics: [String] {
        var topics: [String] = []
        for memory in appModel.facts where !topics.contains(memory.displayTopic) {
            topics.append(memory.displayTopic)
        }
        // "General" (untopiced) sorts last, everything else alphabetical.
        return topics.sorted { lhs, rhs in
            if lhs == "General" { return false }
            if rhs == "General" { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    /// The offline Preview provider kind was retired; this list now only
    /// hides Apple Intelligence when it is disabled or unavailable.
    private var visibleProfiles: [ProviderProfile] {
        appModel.providers.profiles.filter { profile in
            if profile.kind == .appleIntelligence { return appModel.isAppleIntelligenceEnabled }
            return true
        }
    }

    private func addSkillFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder containing a SKILL.md file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appModel.skills.addCustomFolder(url.path)
    }
}

/// Appearance, behavior, updates, and the destructive data controls —
/// extracted from `settingsForm` so a toggle in here invalidates this
/// card's body only. The lag was never "Settings is big": it was every
/// control living inside one body that observed the whole `AppModel`,
/// so flipping any switch re-evaluated all ~600 lines of cards at once.
private struct GeneralCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var confirmFullReset = false

    var body: some View {
        @Bindable var appModel = appModel
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            LabeledContent("Accent color") {
                HStack(spacing: 7) {
                    ForEach(AccentPreset.allCases) { preset in
                        Button {
                            appModel.accentPreset = preset
                        } label: {
                            Circle()
                                .fill(Color(hex: preset.baseHex))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Circle().stroke(Theme.text, lineWidth: preset == appModel.accentPreset ? 2 : 0)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(preset.displayName)
                        .accessibilityLabel(preset.displayName)
                        .animation(.easeOut(duration: 0.15), value: appModel.accentPreset)
                    }
                }
            }
            Toggle("Use Apple Intelligence", isOn: $appModel.isAppleIntelligenceEnabled)
            Toggle("Auto-title chats", isOn: $appModel.isAutoTitleEnabled)
            Toggle("Hover timestamps", isOn: $appModel.isHoverTimestampsEnabled)
            KeyboardShortcuts.Recorder("Summon VelaChat:", name: .summonVelaChat)
            UpdatesRow()
            Picker("Message width", selection: $appModel.messageWidth) {
                ForEach(MessageWidthPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            Picker("Density", selection: $appModel.density) {
                ForEach(DensityPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            LabeledContent("Conversation history") {
                Text("Stored locally")
                    .foregroundStyle(Theme.secondaryText)
            }
            Button("Clear conversation history") {
                confirmClear = true
            }
            .buttonStyle(SettingsDestructiveButtonStyle())
            .confirmationDialog("Delete all conversations?", isPresented: $confirmClear) {
                Button("Delete Everything", role: .destructive) {
                    appModel.clearHistory()
                }
            } message: {
                Text("This cannot be undone.")
            }
            Button("Reset built-in provider presets") {
                confirmReset = true
            }
            .buttonStyle(SettingsDestructiveButtonStyle())
            Button("Reset VelaChat completely…") {
                confirmFullReset = true
            }
            .buttonStyle(SettingsDestructiveButtonStyle())
            .confirmationDialog("Reset VelaChat completely?", isPresented: $confirmFullReset) {
                Button("Erase Everything", role: .destructive) {
                    appModel.performFullReset()
                }
            } message: {
                Text("Every conversation, memory, setting, API key, and workspace file on this Mac is erased, and the app returns to first launch. This cannot be undone.")
            }
            .confirmationDialog("Reset provider presets?", isPresented: $confirmReset) {
                Button("Reset Presets", role: .destructive) {
                    appModel.providers.resetBuiltIns()
                }
            } message: {
                Text("Custom endpoints are kept, but built-in endpoint and model values return to their defaults.")
            }
        }
    }
}

/// A real draft: Cancel creates nothing, and nothing is selected until the
/// user explicitly chooses to use the endpoint — adding no longer instantly
/// switched the whole app to an unconfigured localhost profile.
/// Egress controls. Both switches here change what physically leaves the
/// machine, so both say so in plain language rather than in a tooltip.
private struct PrivacyCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var testText = ""
    @State private var newName = ""
    @State private var newPattern = ""
    @State private var isAddingRule = false

    private var invalidIDs: Set<UUID> { appModel.redaction.invalidRuleIDs }

    var body: some View {
        @Bindable var model = appModel

        Toggle("Local-only mode", isOn: $model.isLocalOnlyMode)
        Text("Refuses every request to a host that isn't loopback — hosted providers, model discovery, quota checks, web search, and provider logos alike. A model server on another machine on your network counts as remote and is also refused.")
            .font(.caption)
            .foregroundStyle(Theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

        Divider()

        // `redaction` is a `let` sub-object, so `@Bindable` can't reach
        // through it — an explicit binding is the supported route.
        Toggle("Redact secrets before sending", isOn: Binding(
            get: { appModel.redaction.isEnabled },
            set: { appModel.redaction.isEnabled = $0 }
        ))

        if appModel.redaction.isEnabled {
            rulesList
            testField
            addRuleControls
        }
    }

    private var rulesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(appModel.redaction.rules) { rule in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.name)
                            .font(.callout.weight(.medium))
                        Text(rule.pattern)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                        if invalidIDs.contains(rule.id) {
                            // A rule that cannot compile matches nothing,
                            // which is indistinguishable from a rule that
                            // found nothing. Say it out loud.
                            Text("This pattern isn't a valid regular expression, so it never matches.")
                                .font(.caption2)
                                .foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { rule.isEnabled },
                        set: { appModel.redaction.setEnabled($0, for: rule.id) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("\(rule.name) rule")
                    if !rule.isBuiltIn {
                        Button {
                            appModel.redaction.delete(rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(VelaIconButtonStyle())
                        .foregroundStyle(Theme.tertiaryText)
                        .accessibilityLabel("Delete the \(rule.name) rule")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Live test: type anything and see exactly what would be sent. This is
    /// the only way to gain confidence in a regex without leaking a real
    /// credential to find out.
    private var testField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Test")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            TextField("Paste something to see how it would be sent", text: $testText, axis: .vertical)
                .settingsFieldStyle()
                .lineLimit(1...4)
                .accessibilityLabel("Redaction test input")
            let result = appModel.redaction.redactor.redact(testText)
            if testText.isEmpty {
                Text("Nothing to test yet.")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Text(result.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(result.didRedact ? Theme.warning : Theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Redaction test result")
                Text(result.didRedact
                     ? "\(result.spans.count) match\(result.spans.count == 1 ? "" : "es") would be replaced."
                     : "No rule matches this — it would be sent unchanged.")
                    .font(.caption2)
                    .foregroundStyle(result.didRedact ? Theme.warning : Theme.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private var addRuleControls: some View {
        if isAddingRule {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Rule name", text: $newName)
                    .settingsFieldStyle()
                TextField("Regular expression", text: $newPattern)
                    .settingsFieldStyle()
                    .font(.system(.body, design: .monospaced))
                if !newPattern.isEmpty, (try? NSRegularExpression(pattern: newPattern)) == nil {
                    SettingsInlineMessage(text: "Not a valid regular expression yet.", tone: .error)
                }
                HStack(spacing: 8) {
                    Button("Add") {
                        appModel.redaction.add(name: newName, pattern: newPattern)
                        newName = ""
                        newPattern = ""
                        isAddingRule = false
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .disabled(
                        newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (try? NSRegularExpression(pattern: newPattern)) == nil
                    )
                    Button("Cancel") {
                        isAddingRule = false
                        newName = ""
                        newPattern = ""
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    Spacer()
                }
            }
        } else {
            HStack(spacing: 12) {
                Button {
                    isAddingRule = true
                } label: {
                    Label("Add a Rule…", systemImage: "plus.circle")
                }
                .buttonStyle(SettingsAddButtonStyle())
                Button("Restore Built-Ins") {
                    appModel.redaction.restoreBuiltIns()
                }
                .buttonStyle(SettingsAddButtonStyle())
            }
        }
    }
}

private struct McpServersCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var editing: McpServerConfig?
    @State private var isImporting = false
    @State private var importText = ""
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appModel.mcp.servers.isEmpty {
                SettingsEmptyState(text: "No MCP servers configured.", symbol: "puzzlepiece.extension")
            }
            ForEach(appModel.mcp.servers) { server in
                let status = status(for: server)
                HStack(spacing: 8) {
                    Image(systemName: status.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.tint)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 7) {
                            Text(server.name)
                                .font(.callout.weight(.medium))
                            Text(status.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(status.tint)
                        }
                        Text(([server.command] + server.args).joined(separator: " "))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                        if let error = appModel.mcp.lastErrorByServer[server.id] {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(Theme.danger)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { server.enabled },
                        set: { enabled in
                            var updated = server
                            updated.enabled = enabled
                            appModel.mcp.update(updated)
                        }
                    ))
                    .labelsHidden()
                    // This one is a bare switch inside its own row, not a
                    // labelled settings line, so it opts out of the card's
                    // label-left/switch-right style.
                    .toggleStyle(.switch)
                    Button {
                        editing = server
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(VelaIconButtonStyle())
                    .foregroundStyle(Theme.tertiaryText)
                    Button {
                        appModel.mcp.remove(id: server.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(VelaIconButtonStyle())
                    .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 12) {
                Button {
                    editing = McpServerConfig(name: "", command: "")
                } label: {
                    Label("Add a Server…", systemImage: "plus.circle")
                }
                .buttonStyle(SettingsAddButtonStyle())
                Button {
                    importText = ""
                    importError = nil
                    isImporting = true
                } label: {
                    Label("Import from JSON…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(SettingsAddButtonStyle())
            }
        }
        .sheet(item: $editing) { server in
            McpServerSheet(config: server) { saved in
                if appModel.mcp.servers.contains(where: { $0.id == saved.id }) {
                    appModel.mcp.update(saved)
                } else if !saved.command.trimmingCharacters(in: .whitespaces).isEmpty {
                    appModel.mcp.add(saved)
                }
            }
        }
        .sheet(isPresented: $isImporting) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import MCP servers")
                    .font(.title3.weight(.semibold))
                Text("Paste a standard mcpServers JSON block (Claude Desktop's config works).")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                TextEditor(text: $importText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 140)
                    .settingsMultilineFieldStyle()
                if let importError {
                    SettingsInlineMessage(text: importError, tone: .error)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { isImporting = false }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                    Button("Import") {
                        if let error = appModel.mcp.importJSON(importText) {
                            importError = error
                        } else {
                            isImporting = false
                        }
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    /// The manager exposes failures but intentionally starts servers lazily,
    /// so absence of an error is not proof of health. Label that state as
    /// unverified instead of drawing the previous false-green dot.
    private func status(for server: McpServerConfig) -> (label: String, symbol: String, tint: Color) {
        if !server.enabled {
            return ("Disabled", "pause.circle", Theme.tertiaryText)
        }
        if appModel.mcp.lastErrorByServer[server.id] != nil {
            return ("Last check failed", "xmark.circle.fill", Theme.danger)
        }
        return ("Enabled · unverified", "questionmark.circle", Theme.warning)
    }
}

private struct McpServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var config: McpServerConfig
    @State private var argsText: String
    @State private var envText: String
    let onSave: (McpServerConfig) -> Void

    init(config: McpServerConfig, onSave: @escaping (McpServerConfig) -> Void) {
        _config = State(initialValue: config)
        _argsText = State(initialValue: config.args.joined(separator: " "))
        _envText = State(initialValue: config.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(config.name.isEmpty ? "New MCP Server" : config.name)
                .font(.title3.weight(.semibold))
            TextField("Name", text: $config.name)
                .settingsFieldStyle()
            TextField("Command (e.g. npx)", text: $config.command)
                .settingsFieldStyle()
            TextField("Arguments (space-separated)", text: $argsText)
                .settingsFieldStyle()
            VStack(alignment: .leading, spacing: 4) {
                Text("Environment (KEY=value per line)")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                TextEditor(text: $envText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 60)
                    .settingsMultilineFieldStyle()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                Button("Save") {
                    var saved = config
                    saved.args = argsText.split(separator: " ").map(String.init)
                    saved.env = Dictionary(uniqueKeysWithValues: envText
                        .split(separator: "\n")
                        .compactMap { line -> (String, String)? in
                            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                            return parts.count == 2 ? (parts[0], parts[1]) : nil
                        })
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty || config.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Sparkle's controls, kept honest: the app is ad-hoc signed, so updates
/// are verified by Sparkle's own key rather than by a Developer ID.
private struct UpdatesRow: View {
    @Environment(UpdaterController.self) private var updater

    /// Two settings lines, not one crammed one. As a single `LabeledContent`
    /// this put a label, a switch, a button, and a timestamp on one row, so
    /// its switch sat nowhere near the switches directly above it and the
    /// timestamp had no room left to render.
    var body: some View {
        Toggle("Check for updates automatically", isOn: Binding(
            get: { updater.automaticallyChecks },
            set: { updater.automaticallyChecks = $0 }
        ))
        .disabled(!updater.isAvailable)
        LabeledContent {
            HStack(spacing: 10) {
                Text(updater.lastCheckDescription)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                Button("Check Now") { updater.checkForUpdates() }
                    .buttonStyle(SettingsAddButtonStyle())
                    .disabled(!updater.canCheckForUpdates)
                    .accessibilityLabel("Check for updates now")
            }
        } label: {
            Text("Updates")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Updates")
        .accessibilityValue(updater.lastCheckDescription)
        // A dead control with no explanation reads as a bug. Say why it is
        // off: Sparkle needs a real .app, which `swift run` never produces.
        if !updater.isAvailable {
            Text("Updating is only available in the bundled app (`just app`). A `swift run` build has no bundle for Sparkle to update.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One stored fact, editable in place.
///
/// The list used to bind straight into the old `AppModel.memories` array,
/// so every keystroke rewrote it — and, through its `didSet`, re-encoded
/// the whole `UserDefaults` blob. Facts live in SQLite now and an edit is
/// a real write with re-embedding behind it, so the text is buffered here
/// and committed once: on Return, or when focus leaves the field.
private struct MemoryFactRow: View {
    @Environment(AppModel.self) private var appModel
    let fact: MemoryItem

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
            TextField("Memory", text: $draft, axis: .vertical)
                .settingsFieldStyle()
                .focused($isFocused)
                .onSubmit { commit() }
                .accessibilityLabel("Stored memory")
            Button {
                appModel.removeMemory(fact)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(VelaIconButtonStyle())
            .foregroundStyle(Theme.tertiaryText)
            .help("Forget this memory")
            .accessibilityLabel("Forget this memory")
        }
        .transition(.opacity)
        .onAppear { draft = fact.content }
        // The store normalizes phrasing on write ("i like tea" becomes
        // "User likes tea"), so what comes back can differ from what was
        // typed. Adopt it — unless the field is still being edited, where
        // overwriting under the cursor would be maddening.
        .onChange(of: fact.content) { _, updated in
            if !isFocused { draft = updated }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        appModel.updateMemory(fact, content: draft)
    }
}

/// The opt-in hosted embedder.
///
/// On-device embeddings measurably cannot retrieve on their own — the
/// query "zzzqqq unrelated gibberish xyzzy" once scored an unrelated note
/// higher than the correct hit for a real question scored — which is why
/// recall is keyword-first and why a real embedding model is a functional
/// requirement rather than a refinement. Every real one runs on somebody
/// else's computer.
///
/// So: off unless explicitly switched on, with the consequence stated in
/// the UI rather than buried, and unavailable at all in local-only mode.
/// `EgressPolicy.check` is enforced inside `RemoteEmbedding.vector`, so
/// this screen is the explanation, not the enforcement.
private struct RemoteEmbeddingRow: View {
    @Environment(AppModel.self) private var appModel

    @State private var isEnabled = RemoteEmbedding.isEnabled
    @State private var endpoint = Defaults.string(DefaultsKey.remoteEmbeddingEndpoint) ?? ""
    @State private var model = Defaults.string(DefaultsKey.remoteEmbeddingModel) ?? ""
    @State private var providerID = Defaults.string(DefaultsKey.remoteEmbeddingProvider) ?? ""
    @State private var status: String?
    @State private var statusTone: SettingsMessageTone = .information
    @State private var isTesting = false

    private var keyedProfiles: [ProviderProfile] {
        appModel.providers.profiles.filter { appModel.providers.hasStoredKey(for: $0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { isEnabled }, set: { newValue in
                isEnabled = newValue
                Defaults.set(newValue, DefaultsKey.remoteEmbeddingsEnabled)
                status = nil
            })) {
                HStack(spacing: 7) {
                    Text("Configure hosted embeddings")
                        .font(.callout)
                    Text("Not active")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Theme.warning.opacity(0.1),
                            in: Capsule()
                        )
                }
            }
            .toggleStyle(.switch)
            .disabled(appModel.isLocalOnlyMode)
            .accessibilityLabel("Configure hosted embedding model for memory; not active")

            Text(appModel.isLocalOnlyMode
                 ? "Unavailable while local-only mode is on — a hosted embedder is network egress by definition."
                 : "Sends the text of your saved memories and recall queries to the endpoint below, so a real embedding model can rank them. Off by default; on-device embeddings never leave this Mac.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            if isEnabled && !appModel.isLocalOnlyMode {
                SettingsInlineMessage(
                    text: "Configuration only: memory search still embeds on device. Hosted indexing needs a safe full re-embed migration before this endpoint can become active.",
                    tone: .warning
                )
                TextField("https://api.example.com/v1/embeddings", text: $endpoint)
                    .settingsFieldStyle()
                    .accessibilityLabel("Embedding endpoint URL")
                    .onChange(of: endpoint) { _, value in
                        Defaults.set(value, DefaultsKey.remoteEmbeddingEndpoint)
                    }
                TextField("Embedding model, e.g. text-embedding-3-small", text: $model)
                    .settingsFieldStyle()
                    .accessibilityLabel("Embedding model name")
                    .onChange(of: model) { _, value in
                        Defaults.set(value, DefaultsKey.remoteEmbeddingModel)
                    }
                // Keys are never stored twice: this borrows an existing
                // provider's Keychain entry rather than minting another
                // secret to look after.
                Picker("Authenticate with", selection: $providerID) {
                    Text("No key").tag("")
                    ForEach(keyedProfiles) { profile in
                        Text(profile.name).tag(profile.id.uuidString)
                    }
                }
                .accessibilityLabel("Provider key used for the embedding endpoint")
                .onChange(of: providerID) { _, value in
                    Defaults.set(value, DefaultsKey.remoteEmbeddingProvider)
                }
                HStack(spacing: 8) {
                    Button(isTesting ? "Testing…" : "Test") { test() }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .disabled(isTesting || endpoint.isEmpty || model.isEmpty)
                        .accessibilityLabel("Test the embedding endpoint")
                    Spacer(minLength: 0)
                }
                if let status {
                    SettingsInlineMessage(text: status, tone: statusTone)
                }
            }
        }
    }

    /// Proof rather than a green tick: an endpoint that claims to be
    /// OpenAI-compatible has to actually return a vector, and the
    /// dimension it returns is the evidence.
    private func test() {
        isTesting = true
        status = nil
        let key = UUID(uuidString: providerID).map { appModel.providers.apiKey(for: $0) } ?? ""
        Task {
            guard let remote = RemoteEmbedding.configured(apiKey: key) else {
                status = "Fill in the endpoint and model first."
                statusTone = .warning
                isTesting = false
                return
            }
            switch await remote.verify() {
            case .success(let dimension):
                status = "Returned a \(dimension)-dimension vector."
                statusTone = .success
            case .failure(let error):
                status = error.localizedDescription
                statusTone = .error
            }
            isTesting = false
        }
    }
}

/// The state of the conversation index, and control over it.
///
/// Memory that quietly reads everything you've ever written should be
/// visible and switchable off, not a background process you have to
/// infer from CPU usage.
private struct ConversationIndexRow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                if appModel.memoryIndexer.isBackfilling {
                    ShimmerText(
                        text: "Indexing past conversations — \(appModel.memoryIndexer.backfilled) of \(appModel.memoryIndexer.backfillTotal)",
                        font: .caption
                    )
                    Spacer(minLength: 0)
                    Button("Stop") { appModel.memoryIndexer.cancelBackfill() }
                        .buttonStyle(VelaIconButtonStyle())
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("\(appModel.memoryIndexer.indexedMessages) messages searchable")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 0)
                    Button("Index Now") {
                        appModel.memoryIndexer.startBackfill(conversations: appModel.conversations)
                    }
                    .buttonStyle(VelaIconButtonStyle())
                    .foregroundStyle(Theme.accent)
                }
            }
            Text(MemoryEmbedder.shared.isSemanticAvailable
                 ? "Replies can draw on relevant excerpts from your earlier conversations. Matching is keyword-driven, with on-device embeddings refining the order — nothing is sent anywhere to build this index."
                 : "On-device language assets aren't available, so matching is keyword-only.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AddProviderSheet: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isPresented: Bool
    let onCreate: (UUID) -> Void

    @State private var name = ""
    @State private var endpoint = "http://127.0.0.1:8000/v1"
    @State private var apiKey = ""

    private var canSave: Bool {
        URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            && !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Endpoint")
                .font(.title3.weight(.semibold))
            TextField("Name (e.g. \u{201C}vLLM on my server\u{201D})", text: $name)
                .settingsFieldStyle()
            TextField("Base endpoint (\u{2026}/v1)", text: $endpoint)
                .settingsFieldStyle()
                .textContentType(.URL)
            SecureField("API key (optional)", text: $apiKey)
                .settingsFieldStyle()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                Button("Add") {
                    let id = appModel.providers.createCompatible(name: name, endpoint: endpoint)
                    if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = appModel.providers.setAPIKey(apiKey, for: id)
                    }
                    isPresented = false
                    onCreate(id)
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct AddSnippetSheet: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var snippetBody = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Snippet")
                .font(.title3.weight(.semibold))
            TextField("Name (shown in the / menu)", text: $name)
                .settingsFieldStyle()
            TextEditor(text: $snippetBody)
                .font(.body)
                .frame(minHeight: 120)
                .settingsMultilineFieldStyle()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                Button("Save") {
                    appModel.addSnippet(name: name, body: snippetBody)
                    isPresented = false
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || snippetBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct ProviderSettingsRow: View {
    let profile: ProviderProfile
    let status: ProviderStore.Status
    let isActive: Bool
    let hasKey: Bool

    var body: some View {
        HStack(spacing: 11) {
            ProviderLogoView(kind: profile.kind, endpoint: profile.endpoint, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.text)
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accentForeground)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)
            readiness
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if profile.model.isEmpty { return profile.kind.shortDescription }
        return profile.model
    }

    @ViewBuilder
    private var readiness: some View {
        if profile.kind.requiresKey && !hasKey {
            Image(systemName: "key.slash")
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .help("Needs an API key")
                .accessibilityLabel("Needs an API key")
        } else if case .connecting = status {
            Circle()
                .fill(Theme.warning)
                .frame(width: 5, height: 5)
                .symbolEffectPulse()
        } else if case .failed = status {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.danger)
        } else if case .connectedEmpty = status {
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(Theme.warning)
        } else if case .connected = status {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.success)
        }
    }
}

private struct ChangelogEntry: Identifiable {
    let id = UUID()
    let version: String
    let date: String
    let highlights: [String]
}

/// Hand-maintained, not generated — add a new entry here whenever a release
/// actually ships. Sets up naturally for the (still-backlogged) auto-update
/// flow, which will want somewhere to point "see what's new" at.
private enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.0",
            date: "2026",
            highlights: [
                "13 providers, including real native Anthropic support and blockrun.ai — a free, anonymous connection with no key required",
                "Rich Ollama support: pull models with live progress, real quantization and disk size per model, and cloud-hosted (:cloud) models marked distinctly",
                "The model picker shows every configured provider at once, grouped, instead of only the one currently selected",
                "Errors show up as real cards in the conversation instead of raw JSON or a banner that could vanish before you read it",
                "The model can ask you a multiple-choice question mid-reply — with optional notes — instead of guessing",
                "A real global summon hotkey, pinned conversations with no artificial limit, and a manual context-window override for providers that don't publish one"
            ]
        )
    ]
}

struct ChangelogView: View {
    var body: some View {
        SettingsPage {
            ForEach(Changelog.entries) { entry in
                SettingsPanel(title: "Version \(entry.version) · \(entry.date)", symbol: "sparkles") {
                    ForEach(entry.highlights, id: \.self) { highlight in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: "sparkle")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 15)
                            Text(highlight)
                                .font(.callout)
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }
}
