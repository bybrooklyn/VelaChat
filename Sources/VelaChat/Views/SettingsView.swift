import SwiftUI
import AppKit
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(WindowChrome.self) private var chrome
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var editingProfileID: UUID?
    @State private var isAddingSnippet = false
    @State private var newMemoryText = ""
    @State private var accentPreset = AccentPreset.current

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
            if chrome.isFullScreen {
                ExitFullScreenButton()
            }

            Button {
                appModel.section = .chat
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 30, height: 30)
                    .glassCircle(tint: Theme.accent)
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
        return Form {
            // Providers lead, because they're the thing you actually come
            // here to change, and they now live inline instead of behind a
            // separate "Connections" screen.
            Section {
                ForEach(visibleProfiles) { profile in
                    Button {
                        appModel.providers.select(profile.id)
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
                    editingProfileID = appModel.providers.addCompatible()
                } label: {
                    Label("Add a custom OpenAI-compatible endpoint", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            } header: {
                Text("Providers")
            } footer: {
                Text("Keys stay in your macOS Keychain. Requests go straight to the provider.")
            }

            Section {
                TextEditor(text: $appModel.customInstructions)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .background(Theme.controlBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
            } header: {
                Text("Custom Instructions")
            } footer: {
                Text("Sent invisibly with every message \u{2014} who you are and how the model should respond.")
            }

            Section {
                if appModel.memories.isEmpty {
                    Label("No memories yet.", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    ForEach($appModel.memories) { $memory in
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
                HStack(spacing: 8) {
                    TextField("Add a memory…", text: $newMemoryText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .flatFieldStyle()
                    Button("Add") {
                        appModel.addMemory(newMemoryText)
                        newMemoryText = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Facts the model keeps across every conversation \u{2014} yours to edit or remove.")
            }

            Section {
                if appModel.skills.skills.isEmpty {
                    Label("No skills found yet.", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    ForEach(appModel.skills.skills) { skill in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(skill.name)
                                    .font(.callout.weight(.medium))
                                Text(skill.source.rawValue)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.controlBackground, in: Capsule())
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
                            if skill.source == .custom {
                                Button(role: .destructive) {
                                    appModel.skills.removeCustomFolder(skill.folderPath)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
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
            } header: {
                Text("Skills")
            } footer: {
                Text("Auto-discovered from ~/.claude/skills and ~/.codex/skills. Invoke one from the / menu.")
            }

            Section {
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
            } header: {
                Text("Prompt Snippets")
            } footer: {
                Text("Save a prompt once, reuse it from the / menu.")
            }

            Section {
                LabeledContent("Fallback search") {
                    TextField("https://searx.example.org", text: $appModel.searchEndpoint)
                        .textFieldStyle(.plain)
                        .flatFieldStyle()
                        .textContentType(.URL)
                        .frame(maxWidth: 320)
                }
            } header: {
                Text("Web Search")
            } footer: {
                Text("A SearXNG fallback for providers without built-in search (pick one from searx.space). Toggle search on in the composer.")
            }

            Section {
                Toggle("Workspace files", isOn: $appModel.isWorkspaceEnabled)
                Toggle("Conversation search", isOn: $appModel.isConversationSearchEnabled)
                if let conversation = appModel.activeConversation {
                    Button("Reveal This Conversation's Workspace in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([SandboxManager.directory(for: conversation.id)])
                    }
                    .buttonStyle(VelaIconButtonStyle())
                    .foregroundStyle(Theme.accent)
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Lets tool-capable models search your past conversations and use a private per-conversation folder. There is no shell or command execution.")
            }

            Section {
                KeyboardShortcuts.Recorder("Summon VelaChat:", name: .summonVelaChat)
            } header: {
                Text("Global Shortcut")
            } footer: {
                Text("Works from anywhere on the Mac.")
            }

            Section {
                LabeledContent("Appearance") {
                    Label("Dark", systemImage: "moon.fill")
                        .foregroundStyle(Theme.secondaryText)
                }
                LabeledContent("Accent color") {
                    HStack(spacing: 7) {
                        ForEach(AccentPreset.allCases) { preset in
                            Button {
                                accentPreset = preset
                                AccentPreset.current = preset
                            } label: {
                                Circle()
                                    .fill(Color(hex: preset.baseHex))
                                    .frame(width: 20, height: 20)
                                    .overlay {
                                        Circle().stroke(Theme.text, lineWidth: preset == accentPreset ? 2 : 0)
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(preset.displayName)
                            .animation(.easeOut(duration: 0.15), value: accentPreset)
                        }
                    }
                }
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
                .confirmationDialog("Reset provider presets?", isPresented: $confirmReset) {
                    Button("Reset Presets", role: .destructive) {
                        appModel.providers.resetBuiltIns()
                    }
                } message: {
                    Text("Custom endpoints are kept, but built-in endpoint and model values return to their defaults.")
                }
            } header: {
                Text("General")
            } footer: {
                Text("Messages are never relayed through an app-owned server.")
            }

            Section {
                LabeledContent("Version") {
                    Text(AppModel.appVersion)
                        .foregroundStyle(Theme.secondaryText)
                }
                NavigationLink {
                    ChangelogView()
                } label: {
                    Label("What's New", systemImage: "sparkles")
                }
                NavigationLink {
                    StatisticsView()
                } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }
                LabeledContent("License") {
                    Text("MIT")
                        .foregroundStyle(Theme.secondaryText)
                }
                Link(destination: URL(string: "https://opensource.org/license/mit")!) {
                    Label("Read the MIT license", systemImage: "arrow.up.right.square")
                }
                .foregroundStyle(Theme.accent)
            } header: {
                Text("About VelaChat")
            } footer: {
                Text("Free and open source \u{2014} use it, fork it, ship it.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .center)
        .sheet(isPresented: $isAddingSnippet) {
            AddSnippetSheet(isPresented: $isAddingSnippet)
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
            ProviderLogo(kind: profile.kind, size: 26)

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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if profile.model.isEmpty { return profile.kind.shortDescription }
        return profile.model
    }

    @ViewBuilder
    private var readiness: some View {
        if profile.kind.requiresKey && !hasKey {
            Text("Needs key")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.warning)
        } else if case .connecting = status {
            ProgressView()
                .controlSize(.mini)
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
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
