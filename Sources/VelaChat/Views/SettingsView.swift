import SwiftUI
import AppKit
import KeyboardShortcuts

/// The jump-rail's section catalog — order matches the cards.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case providers = "Providers"
    case instructions = "Instructions"
    case memory = "Memory"
    case skills = "Skills"
    case snippets = "Snippets"
    case webSearch = "Web Search"
    case tools = "Tools"
    case statistics = "Statistics"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .providers: "server.rack"
        case .instructions: "person.text.rectangle"
        case .memory: "brain"
        case .skills: "sparkles"
        case .snippets: "text.badge.plus"
        case .webSearch: "globe"
        case .tools: "wrench.and.screwdriver"
        case .general: "gearshape"
        case .statistics: "chart.bar.xaxis"
        case .about: "info.circle"
        }
    }
}

private struct SettingsSectionPreference: PreferenceKey {
    static let defaultValue: [SettingsSection: CGFloat] = [:]
    static func reduce(value: inout [SettingsSection: CGFloat], nextValue: () -> [SettingsSection: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// One glass card per settings area — icon tile, title, content, footer —
/// replacing the grouped Form's plain rows.
private struct SettingsCard<Content: View>: View {
    let section: SettingsSection
    var footer: Text? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.rawValue)
                .font(.headline)
                .foregroundStyle(Theme.text)
            content()
                .toggleStyle(.switch)
                .tint(Theme.accentStrong)
                .controlSize(.small)
            if let footer {
                footer
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.controlBackground.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.controlStroke.opacity(0.5), lineWidth: 1)
        }
        .id(section)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SettingsSectionPreference.self,
                    value: [section: geometry.frame(in: .named("settings-scroll")).minY]
                )
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(WindowChrome.self) private var chrome
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var confirmFullReset = false
    @State private var editingProfileID: UUID?
    @State private var isAddingSnippet = false
    @State private var isAddingProvider = false
    @State private var activeSection: SettingsSection = .general
    @State private var newMemoryText = ""

    private var topBarHeight: CGFloat { chrome.isFullScreen ? 44 : 52 }

    var body: some View {
        // The header is a normal flow element that respects the safe area —
        // only its own background ignores it (below) — rather than the whole
        // VStack ignoring it and guessing a compensating height. The old
        // approach was only ever right at the exact window size it was tuned
        // against; at any other size it either clipped the header or left an
        // empty reserved strip above it.
        VStack(spacing: 0) {
            header
            NavigationStack {
                settingsForm
                    .navigationDestination(item: $editingProfileID) { id in
                        ProviderEditorView(profileID: id)
                    }
            }
            .clipped()
        }
    }

    /// Matches the chat pane's glass header so the two panes read as one app
    /// rather than two differently-chromed screens.
    private var header: some View {
        HStack(spacing: 10) {
            Button {
                appModel.section = .chat
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accentForeground)
                    .frame(width: 30, height: 30)
                    .glassCircle(tint: Theme.accentStrong)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Back to conversations (Esc)")

            Text("Settings")
                .font(.headline)
                .foregroundStyle(Theme.text)
                .padding(.leading, 4)

            Spacer(minLength: 0)
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

    private var settingsForm: some View {
        @Bindable var appModel = appModel
        return HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                HStack(alignment: .top, spacing: 0) {
                    jumpRail(proxy: proxy)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                    SettingsCard(section: .general, footer: Text("Messages are never relayed through an app-owned server.")) {

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
                            .animation(.easeOut(duration: 0.15), value: appModel.accentPreset)
                        }
                    }
                }
                Toggle("Auto-title chats", isOn: $appModel.isAutoTitleEnabled)
                Toggle("Hover timestamps", isOn: $appModel.isHoverTimestampsEnabled)
                KeyboardShortcuts.Recorder("Summon VelaChat:", name: .summonVelaChat)
                Toggle("Auto-title chats", isOn: $appModel.isAutoTitleEnabled)
                Toggle("Hover timestamps", isOn: $appModel.isHoverTimestampsEnabled)
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
                Button("Clear conversation history", role: .destructive) {
                    confirmClear = true
                }
                .confirmationDialog("Delete all conversations?", isPresented: $confirmClear) {
                    Button("Delete Everything", role: .destructive) {
                        appModel.clearHistory()
                    }
                } message: {
                    Text("This cannot be undone.")
                }
                Button("Reset built-in provider presets", role: .destructive) {
                    confirmReset = true
                }
                Button("Reset VelaChat completely…", role: .destructive) {
                    confirmFullReset = true
                }
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


                    SettingsCard(section: .providers, footer: Text("Keys stay in your macOS Keychain. Requests go straight to the provider.")) {

                ForEach(visibleProfiles) { profile in
                    // Viewing a provider must not switch to it — selection
                    // is an explicit action inside the editor now.
                    Button {
                        editingProfileID = profile.id
                    } label: {
                        ProviderSettingsRow(
                            profile: profile,
                            status: appModel.providers.status(for: profile.id),
                            isActive: appModel.providers.selectedID == profile.id,
                            hasKey: appModel.providers.hasStoredKey(for: profile.id)
                        )
                    }
                    .buttonStyle(.plain)
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
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                    }


                    SettingsCard(section: .instructions, footer: Text("Sent invisibly with every message \u{2014} who you are and how the model should respond.")) {

                TextEditor(text: $appModel.customInstructions)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .background(Theme.controlBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
                    }


                    SettingsCard(section: .memory, footer: Text("Written by the model as you chat, kept on this Mac only \u{2014} yours to edit or remove, grouped by topic.")) {

                if appModel.memories.isEmpty {
                    Label("Nothing remembered yet — the model saves facts as you chat.", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    ForEach(memoryTopics, id: \.self) { topic in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(topic)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.tertiaryText)
                            ForEach($appModel.memories) { $memory in
                                if memory.displayTopic == topic {
                                    HStack(spacing: 8) {
                                        Image(systemName: "brain")
                                            .font(.caption)
                                            .foregroundStyle(Theme.tertiaryText)
                                        TextField("Memory", text: $memory.content, axis: .vertical)
                                            .textFieldStyle(.plain)
                                        Button {
                                            appModel.removeMemory(memory)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(VelaIconButtonStyle())
                                        .foregroundStyle(Theme.tertiaryText)
                                    }
                                    .transition(.opacity)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                HStack(spacing: 8) {
                    TextField("Add a memory…", text: $newMemoryText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .flatFieldStyle()
                    Button("Add") {
                        appModel.addMemory(newMemoryText)
                        newMemoryText = ""
                    }
                    .buttonStyle(VelaControlButtonStyle(tint: Theme.accent))
                    .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                    }


                    SettingsCard(section: .skills, footer: Text("Add any folder containing a SKILL.md \u{2014} the same format Claude Code and Codex use. Invoke one from the / menu.")) {

                if appModel.skills.skills.isEmpty {
                    Label("No skills added yet.", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
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
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(Theme.accent)
                    }


                    SettingsCard(section: .snippets, footer: Text("Save a prompt once, reuse it from the / menu.")) {

                if appModel.promptSnippets.isEmpty {
                    Label("No snippets saved yet.", systemImage: "text.badge.plus")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
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
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(Theme.accent)
                    }


                    SettingsCard(section: .webSearch, footer: Text("A SearXNG fallback for providers without built-in search (pick one from searx.space). Toggle search on in the composer.")) {

                LabeledContent("Fallback search") {
                    TextField("https://searx.example.org", text: $appModel.searchEndpoint)
                        .textFieldStyle(.plain)
                        .flatFieldStyle()
                        .textContentType(.URL)
                        .frame(maxWidth: 320)
                }
                    }


                    SettingsCard(section: .tools, footer: Text("Lets tool-capable models search your past conversations and use a private per-conversation folder. There is no shell or command execution.")) {

                Toggle("Workspace files", isOn: $appModel.isWorkspaceEnabled)
                Toggle("Conversation search", isOn: $appModel.isConversationSearchEnabled)
                if let conversation = appModel.activeConversation {
                    Button("Reveal This Conversation's Workspace in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([SandboxManager.directory(for: conversation.id)])
                    }
                    .buttonStyle(VelaIconButtonStyle())
                    .foregroundStyle(Theme.accent)
                }
                    }


                    SettingsCard(section: .statistics, footer: Text("Lifetime messages, tokens, and per-model usage.")) {

                NavigationLink {
                    StatisticsView()
                } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }
                    }


                    SettingsCard(section: .about) {

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
                NavigationLink {
                    ChangelogView()
                } label: {
                    Label("What's New", systemImage: "sparkles")
                }
                Link(destination: URL(string: "https://opensource.org/license/mit") ?? URL(fileURLWithPath: "/")) {
                    Label("MIT license \u{2014} free and open source", systemImage: "arrow.up.right.square")
                }
                .foregroundStyle(Theme.accent)
                    }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .coordinateSpace(name: "settings-scroll")
                    .onPreferenceChange(SettingsSectionPreference.self) { tops in
                        // The section whose card top is nearest (but above)
                        // the viewport's upper edge is "current".
                        let current = tops
                            .filter { $0.value < 140 }
                            .max { $0.value < $1.value }?.key
                            ?? tops.min { $0.value < $1.value }?.key
                        if let current, current != activeSection {
                            activeSection = current
                        }
                    }
                }
            }
        }
        .frame(maxWidth: Theme.Layout.settingsWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .sheet(isPresented: $isAddingSnippet) {
            AddSnippetSheet(isPresented: $isAddingSnippet)
        }
        .sheet(isPresented: $isAddingProvider) {
            AddProviderSheet(isPresented: $isAddingProvider) { newID in
                editingProfileID = newID
            }
        }
    }

    /// The real bundle version — the hardcoded constant is only the
    /// fallback for `swift run`, where no bundle exists.
    private static var bundleVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? AppModel.appVersion
    }

    private func jumpRail(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(section, anchor: .top)
                    }
                } label: {
                    HStack {
                        Text(section.rawValue)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(activeSection == section ? Theme.accent : Theme.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        activeSection == section ? Theme.sidebarSelection.opacity(0.7) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 150)
        .padding(.leading, 14)
        .padding(.top, 20)
        .animation(.easeOut(duration: 0.15), value: activeSection)
    }

    private var memoryTopics: [String] {
        var topics: [String] = []
        for memory in appModel.memories where !topics.contains(memory.displayTopic) {
            topics.append(memory.displayTopic)
        }
        // "General" (untopiced) sorts last, everything else alphabetical.
        return topics.sorted { lhs, rhs in
            if lhs == "General" { return false }
            if rhs == "General" { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    /// Preview disappears for good once any real provider is usable.
    private var visibleProfiles: [ProviderProfile] {
        appModel.providers.profiles.filter { profile in
            profile.kind != .preview || !appModel.providers.hasConfiguredRealProvider
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

/// A real draft: Cancel creates nothing, and nothing is selected until the
/// user explicitly chooses to use the endpoint — adding no longer instantly
/// switched the whole app to an unconfigured localhost profile.
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
                .textFieldStyle(.plain)
                .flatFieldStyle()
            TextField("Base endpoint (\u{2026}/v1)", text: $endpoint)
                .textFieldStyle(.plain)
                .flatFieldStyle()
                .textContentType(.URL)
            SecureField("API key (optional)", text: $apiKey)
                .textFieldStyle(.plain)
                .flatFieldStyle()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.bordered)
                Button("Add") {
                    let id = appModel.providers.createCompatible(name: name, endpoint: endpoint)
                    if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = appModel.providers.setAPIKey(apiKey, for: id)
                    }
                    isPresented = false
                    onCreate(id)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentStrong)
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
                .textFieldStyle(.plain)
                .flatFieldStyle()
            TextEditor(text: $snippetBody)
                .font(.body)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .background(Theme.controlBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.bordered)
                Button("Save") {
                    appModel.addSnippet(name: name, body: snippetBody)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
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
        Form {
            ForEach(Changelog.entries) { entry in
                Section("Version \(entry.version) · \(entry.date)") {
                    ForEach(entry.highlights, id: \.self) { highlight in
                        Label(highlight, systemImage: "sparkle")
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("What's New")
        .frame(maxWidth: Theme.Layout.settingsWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
