import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(WindowChrome.self) private var chrome
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var editingProfileID: UUID?

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
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Chat")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to conversations")

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
                Text("Every provider here speaks the same OpenAI chat-completions format — the “OpenAI Compatible” option is that same protocol pointed at any other server. Keys are stored in your macOS Keychain and requests go directly to the provider.")
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
                Text("Sent with every message from now on \u{2014} tell the model about yourself and how you want it to respond. It's invisible in the conversation, not shown as a chat message.")
            }

            Section {
                LabeledContent("Fallback search") {
                    TextField("https://searx.example.org", text: $appModel.searchEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                        .frame(maxWidth: 320)
                }
            } header: {
                Text("Web Search")
            } footer: {
                Text("Perplexity searches the live web on every request, and OpenRouter searches through its :online routing \u{2014} both work with no setup here. For every other provider, a SearXNG instance (free and keyless \u{2014} pick one from searx.space or self-host) is used as the fallback. Toggle search on in the composer.")
            }

            Section {
                KeyboardShortcuts.Recorder("Summon VelaChat:", name: .summonVelaChat)
            } header: {
                Text("Global Shortcut")
            } footer: {
                Text("Works from anywhere on the Mac, even while another app is active.")
            }

            Section {
                LabeledContent("Appearance") {
                    Label("Dark", systemImage: "moon.fill")
                        .foregroundStyle(Theme.secondaryText)
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
                LabeledContent("License") {
                    Text("MIT")
                        .foregroundStyle(Theme.secondaryText)
                }
                Link(destination: URL(string: "https://opensource.org/license/mit")!) {
                    Label("Read the MIT license", systemImage: "arrow.up.right.square")
                }
                .foregroundStyle(Theme.accent)
                Text("VelaChat is free and open source software, released under the MIT license \u{2014} use it, fork it, and ship it however you like.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            } header: {
                Text("About VelaChat")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Preview disappears for good once any real provider is usable.
    private var visibleProfiles: [ProviderProfile] {
        appModel.providers.profiles.filter { profile in
            profile.kind != .preview || !appModel.providers.hasConfiguredRealProvider
        }
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
        } else if case .failed = status {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.danger)
        } else if case .connected = status {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.success)
        }
    }
}
