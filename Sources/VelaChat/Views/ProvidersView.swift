import SwiftUI

/// The per-provider editor, pushed from the Providers section of Settings.
/// There is no separate "Connections" screen any more — provider management
/// is part of Settings, and this is only its detail page.
struct ProviderEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID

    @State private var name = ""
    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var isTesting = false
    @State private var message: String?
    /// True once the user types in the key field — from then on, background
    /// catalog refreshes stop resyncing (and overwriting) it.
    @State private var apiKeyEdited = false
    @State private var pullModelName = ""

    private var profile: ProviderProfile? {
        appModel.providers.profile(id: profileID)
    }

    var body: some View {
        Group {
            if let profile {
                Form {
                    // The window toolbar is deliberately removed app-wide
                    // (titlebar treatment), so the NavigationStack's own
                    // back chevron never renders — without this row there
                    // is no visible way back out of the editor.
                    Section {
                        Button {
                            dismiss()
                        } label: {
                            Label("All Providers", systemImage: "chevron.left")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("Back to the provider list (Esc)")
                    }
                    Section {
                        HStack(spacing: 12) {
                            ProviderLogoView(kind: profile.kind, endpoint: profile.endpoint, size: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                    .font(.title3.weight(.semibold))
                                Text(profile.kind.shortDescription)
                                    .font(.callout)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        HStack(spacing: 10) {
                            ConnectionPill(status: appModel.providers.status(for: profile.id))
                            Spacer(minLength: 0)
                            if appModel.providers.selectedID == profile.id {
                                Label("Active", systemImage: "checkmark.circle.fill")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(Theme.accent)
                            } else {
                                Button {
                                    appModel.providers.select(profile.id)
                                } label: {
                                    Label("Use This Provider", systemImage: "checkmark.circle")
                                }
                                .buttonStyle(VelaControlButtonStyle(tint: Theme.accent))
                            }
                        }
                    }

                    Section("Connection") {
                        if profile.kind == .compatible {
                            TextField("Name", text: $name)
                        }
                        TextField("Base endpoint", text: $endpoint)
                            .textContentType(.URL)
                        if profile.kind == .codex {
                            Text("Codex login requests go to ChatGPT's fixed backend — this endpoint only applies when a manual API key is used.")
                                .font(.caption)
                                .foregroundStyle(Theme.tertiaryText)
                        }

                        if profile.kind.requiresKey {
                            SecureField(profile.kind == .codex ? "Manual API key (optional)" : "API key", text: $apiKey)
                                .onChange(of: apiKey) { _, _ in apiKeyEdited = true }
                            if let console = profile.kind.consoleURL {
                                Link(destination: console) {
                                    Label("Get a key from \(console.host ?? "the provider")", systemImage: "arrow.up.right.square")
                                }
                                .font(.callout)
                                .foregroundStyle(Theme.accent)
                            }
                        } else if profile.kind.isLocal {
                            Label("No API key required. Requests stay on this Mac.", systemImage: "checkmark.circle")
                                .foregroundStyle(Theme.secondaryText)
                        } else {
                            Label("Preview replies are generated locally.", systemImage: "sparkles")
                                .foregroundStyle(Theme.secondaryText)
                        }

                        HStack {
                            Button("Save") { save(profile) }
                                .buttonStyle(.glassProminent)
                                .tint(Theme.accent)
                            Button {
                                Task { await test(profile) }
                            } label: {
                                HStack(spacing: 6) {
                                    if isTesting {
                                        ShimmerText(text: "Testing…", font: .body)
                                    } else {
                                        Text("Test Connection")
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            if let message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }

                    modelControl(profile)
                    ollamaModelManager(profile)
                    capabilities(profile)
                    providerDetails(profile)
                    // In the form, not the toolbar — the removed window
                    // toolbar would swallow a toolbar-placed button.
                    if profile.kind == .compatible {
                        Section {
                            Button("Remove This Endpoint", role: .destructive) {
                                appModel.providers.remove(id: profile.id)
                                dismiss()
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: Theme.Layout.settingsWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .navigationTitle(profile.name)
                .onAppear {
                    syncFields()
                    appModel.providers.discoverIfNeeded(id: profileID)
                }
                .onChange(of: appModel.providers.models(for: profile.id)) { _, _ in
                    syncFields()
                }
            } else {
                ContentUnavailableView("Provider unavailable", systemImage: "questionmark.circle")
            }
        }
    }

    private func modelControl(_ profile: ProviderProfile) -> some View {
        let models = appModel.providers.models(for: profile.id)
        return Section("Model") {
            if models.isEmpty {
                HStack {
                    Label(
                        appModel.providers.status(for: profile.id) == .connecting ? "Finding models…" : (profile.model.isEmpty ? "Provider default" : "Using \(profile.model)"),
                        systemImage: appModel.providers.status(for: profile.id) == .connecting ? "arrow.triangle.2.circlepath" : "cpu"
                    )
                    .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button {
                        Task { await appModel.providers.refreshModels(id: profile.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(appModel.providers.status(for: profile.id) == .connecting || profile.kind == .preview)
                }
                if profile.kind == .compatible {
                    TextField("Optional model override", text: $model)
                        .font(.system(.body, design: .monospaced))
                }
            } else {
                Picker("Model", selection: $model) {
                    ForEach(models) { remoteModel in
                        Text(remoteModel.id).tag(remoteModel.id)
                    }
                }
                .onChange(of: model) { _, value in
                    appModel.providers.update(id: profile.id, model: value)
                }
            }
            Text("The first compatible model is selected automatically when the provider responds.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    /// Real Ollama model management, not just a picker over whatever's
    /// already pulled: each installed model shows its actual quantization
    /// and disk footprint (straight from `/api/tags`), cloud-hosted models
    /// (`:cloud` tag) are marked distinctly since they don't run on this
    /// Mac, and a new model can be pulled with live progress — the same
    /// `/api/pull` stream `ollama pull` itself uses.
    @ViewBuilder
    private func ollamaModelManager(_ profile: ProviderProfile) -> some View {
        if profile.kind == .ollama {
            Section("Installed models") {
                let models = appModel.providers.models(for: profile.id)
                if models.isEmpty {
                    Text("No models pulled yet.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    ForEach(models) { remoteModel in
                        HStack(spacing: 10) {
                            Image(systemName: remoteModel.isCloudHosted ? "cloud" : "internaldrive")
                                .foregroundStyle(remoteModel.isCloudHosted ? Theme.accent : Theme.success)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(remoteModel.displayName)
                                    .font(.callout.weight(.medium))
                                if let resource = remoteModel.resourceLabel {
                                    Text(resource)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                            }
                            Spacer()
                            if remoteModel.isCloudHosted {
                                Text("Cloud")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("Model to pull, e.g. qwen3:8b", text: $pullModelName)
                        .textFieldStyle(.plain)
                        .flatFieldStyle()
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { startPull(profile) }
                    Button("Pull") { startPull(profile) }
                        .buttonStyle(.bordered)
                        .disabled(isPullDisabled)
                }

                ForEach(Array(appModel.providers.pullState.keys.sorted()), id: \.self) { name in
                    if let state = appModel.providers.pullState[name] {
                        pullProgressRow(name: name, state: state)
                    }
                }

                Link(destination: URL(string: "https://ollama.com/search")!) {
                    Label("Browse the Ollama model library", systemImage: "arrow.up.right.square")
                }
                .font(.callout)
                .foregroundStyle(Theme.accent)
            }
        }
    }

    private var isPullDisabled: Bool {
        let trimmed = pullModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || appModel.providers.pullState[trimmed] != nil
    }

    private func startPull(_ profile: ProviderProfile) {
        guard !isPullDisabled else { return }
        appModel.providers.pullModel(id: profile.id, name: pullModelName)
        pullModelName = ""
    }

    private func pullProgressRow(name: String, state: ProviderStore.PullState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let error = state.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(1)
                } else {
                    Button {
                        appModel.providers.cancelPull(name: name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.tertiaryText)
                }
            }
            if state.errorMessage == nil {
                if let fraction = state.fraction {
                    ProgressView(value: fraction)
                } else {
                    ShimmerText(text: state.status, font: .caption)
                }
                Text(state.status)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.vertical, 2)
    }

    /// Surfaces what this provider can actually do, so search and reasoning
    /// support aren't things you only discover by trying them.
    @ViewBuilder
    private func capabilities(_ profile: ProviderProfile) -> some View {
        Section("Capabilities") {
            LabeledContent("Protocol") {
                Text(profile.kind.speaksOpenAIProtocol ? "OpenAI chat completions" : "Provider-specific")
                    .foregroundStyle(Theme.secondaryText)
            }
            LabeledContent("Web search") {
                switch profile.kind.nativeWebSearch {
                case .always:
                    Label("Built in, always on", systemImage: "globe")
                        .foregroundStyle(Theme.success)
                case .onlineSuffix:
                    Label("Built in, via :online", systemImage: "globe")
                        .foregroundStyle(Theme.success)
                case .none:
                    Text("Uses your SearXNG fallback")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            LabeledContent("Runs") {
                Text(profile.kind.isLocal ? "Locally on this Mac" : "On the provider’s servers")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func providerDetails(_ profile: ProviderProfile) -> some View {
        switch profile.kind {
        case .appleIntelligence:
            Section("On-device") {
                Text(AppleIntelligence.unavailabilityReason ?? "Runs entirely on this Mac — no key, no network, no cost. Conversations never leave the device.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .chatGPT:
            ChatGPTLoginSection()
        case .codex:
            Section("Codex login") {
                Text(appModel.providers.codexMessage ?? "Use the official Codex CLI login, or enter an API key above.")
                    .foregroundStyle(Theme.secondaryText)
                HStack {
                    Button("Run codex login") { appModel.providers.launchCodexLogin() }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                    Button("Refresh auth") { appModel.providers.refreshCodex() }
                        .buttonStyle(.bordered)
                    if appModel.providers.codexCredential != nil {
                        Label("Credentials found", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.success)
                    }
                }
            }
        case .openAI:
            Section("OpenAI") {
                Text("OpenAI defined the chat-completions format every other provider in this list implements. A key here talks to OpenAI’s own servers; the same request shape pointed at a different base URL is exactly what “OpenAI Compatible” means.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .anthropic:
            Section("Anthropic") {
                Text("Claude models through Anthropic’s OpenAI-compatible endpoint, so the same request shape works unchanged. Some Anthropic-only features are not exposed over this compatibility layer.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .google:
            Section("Google Gemini") {
                Text("Gemini through Google’s OpenAI-compatible endpoint on Generative Language API. Create a key in Google AI Studio — the free tier is generous for personal use.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .deepSeek:
            Section("DeepSeek") {
                Text("The preset uses DeepSeek’s current API base at api.deepseek.com. Thinking is provider-accurate: Auto, Off, Low, High, and Max — DeepSeek’s API does not expose a separate Medium or Extra High setting.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .openRouter:
            Section("OpenRouter") {
                Text("One key for hundreds of models, with a live catalog including context, modality, tools, and reasoning metadata. Turning search on in the composer appends OpenRouter’s :online suffix, so the model searches the web itself.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .perplexity:
            Section("Perplexity") {
                Text("Sonar models search the live web on every request and answer with citations — there is nothing to configure and no SearXNG instance needed.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .groq:
            Section("Groq") {
                Text("Open models served on Groq’s LPU hardware, usually at far higher tokens per second than GPU inference.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .mistral:
            Section("Mistral") {
                Text("Mistral’s hosted API, including the Large and Codestral families, over the standard chat-completions shape.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .xai:
            Section("xAI") {
                Text("Grok models from xAI through their OpenAI-compatible API.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .ollama:
            Section("Ollama") {
                Text("Start Ollama and pull any chat model, such as `ollama pull gpt-oss:20b`. VelaChat discovers local models through Ollama’s native /api/tags endpoint. Nothing leaves this Mac.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .lmStudio:
            Section("LM Studio") {
                Text("Start LM Studio’s local server (default port 1234) and load a model. It exposes an OpenAI-compatible API, so no key is needed and nothing leaves this Mac.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .blockrun:
            Section("blockrun.ai") {
                Text("A free, anonymous OpenAI-compatible endpoint — no key, no sign-up. Only its free-tier models are shown here; the rest of its catalog is priced per request through the x402 crypto-micropayment protocol rather than a traditional login, which VelaChat doesn't support. It rate-limits by IP address instead of by API key, so it can get slower or briefly unavailable under load. Good for trying VelaChat out before connecting a provider of your own.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .compatible:
            Section("Compatible endpoint") {
                Text("Works with vLLM, llama.cpp server, LiteLLM, Jan, TGI, and anything else implementing POST /chat/completions — the same format the hosted providers above use.")
                    .foregroundStyle(Theme.secondaryText)
            }
        case .preview:
            Section("Preview") {
                Text("Preview replies are generated locally so the interface can be explored without an account or server. It disappears from this list once you configure a real provider.")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func syncFields() {
        guard let profile else { return }
        // Fields sync from storage only while the user hasn't diverged
        // from it — a background catalog refresh re-running this used to
        // overwrite half-typed edits (key, name, endpoint, AND model)
        // with the stored values. A field that still matches storage is
        // safe to refill; one that differs is an in-progress edit.
        if name == profile.name || name.isEmpty { name = profile.name }
        if endpoint == profile.endpoint || endpoint.isEmpty { endpoint = profile.endpoint }
        if model == profile.model || model.isEmpty { model = profile.model }
        if !apiKeyEdited {
            apiKey = appModel.providers.apiKey(for: profile.id)
        }
        appModel.providers.discoverIfNeeded(id: profile.id)
    }

    private func save(_ profile: ProviderProfile) {
        appModel.providers.update(id: profile.id, endpoint: endpoint, model: model, name: profile.kind == .compatible ? name : nil)
        let keySaved = appModel.providers.setAPIKey(apiKey, for: profile.id)
        apiKeyEdited = false
        message = keySaved ? "Saved" : "Saved, but the API key could not be written to Keychain"
        if keySaved {
            // Self-clearing — a permanent "Saved" next to the buttons read
            // as stuck UI.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if message == "Saved" { message = nil }
            }
        }
    }

    private func test(_ profile: ProviderProfile) async {
        save(profile)
        isTesting = true
        await appModel.providers.test(id: profile.id)
        isTesting = false
        message = statusMessage(profile.id)
    }

    private func statusMessage(_ id: UUID) -> String {
        switch appModel.providers.status(for: id) {
        case .idle: ""
        case .connecting: "Connecting…"
        case .connected(let value): value
        case .connectedEmpty(let value): value
        case .failed(let value): value
        }
    }
}
