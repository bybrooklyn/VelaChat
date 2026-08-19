import SwiftUI
import AppKit
import MarkdownUI

struct VelaMark: View {
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.markBackground)
            Image(systemName: "sailboat.fill")
                .font(.system(size: size * 0.48, weight: .medium))
                .foregroundStyle(Theme.accent)
                .offset(y: size * 0.015)
            Capsule()
                .fill(Theme.coral)
                .frame(width: size * 0.28, height: max(1.5, size * 0.055))
                .rotationEffect(.degrees(-8))
                .offset(x: size * 0.18, y: size * 0.25)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("VelaChat")
    }
}

struct ProviderMark: View {
    let kind: ProviderKind
    var size: CGFloat = 18

    var body: some View {
        ProviderLogo(kind: kind, size: size)
    }
}

/// The collapsed "what the model did" row — a small icon, a plain-language
/// label, and an optional disclosure. Modeled directly on how ChatGPT and
/// Claude surface tool activity: quiet by default, expandable for detail.
struct ActivityRow<Detail: View>: View {
    let symbol: String
    let title: String
    var tint: Color = Theme.secondaryText
    var isActive = false
    var isExpandable = true
    @Binding var isExpanded: Bool
    @ViewBuilder var detail: () -> Detail

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard isExpandable else { return }
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 18, height: 18)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .symbolEffect(.pulse, isActive: isActive)

                    Text(title)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)

                    if isExpandable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .opacity(isHovering || isExpanded ? 1 : 0.45)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    isHovering && isExpandable ? Theme.controlBackground.opacity(0.5) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }

            if isExpanded {
                detail()
                    .padding(.leading, 14)
                    .padding(.top, 6)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.controlStroke.opacity(0.8))
                            .frame(width: 1.5)
                            .padding(.leading, 6)
                            .padding(.vertical, 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct ConnectionPill: View {
    let status: ProviderStore.Status

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(Theme.secondaryText)
    }

    private var color: Color {
        switch status {
        case .idle: Theme.tertiaryText
        case .connecting: Theme.warning
        case .connected: Theme.success
        case .connectedEmpty: Theme.warning
        case .failed: Theme.danger
        }
    }

    private var label: String {
        switch status {
        case .idle: "Not tested"
        case .connecting: "Connecting"
        case .connected(let message): message
        case .connectedEmpty(let message): message
        case .failed: "Connection failed"
        }
    }
}

struct ModelPickerButton: View {
    @Environment(AppModel.self) private var appModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                if let provider = appModel.selectedProvider {
                    ProviderMark(kind: provider.kind, size: 14)
                } else {
                    Image(systemName: "cpu")
                        .foregroundStyle(Theme.modelAccent)
                }
                Text(appModel.selectedModelInfo?.displayName ?? appModel.selectedModel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .buttonStyle(VelaControlButtonStyle(tint: Theme.modelAccent))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelPaletteView(isPresented: $isPresented)
        }
        .help("Choose a model. Your last choice is remembered for this provider.")
    }
}

struct ThinkingPickerButton: View {
    @Environment(AppModel.self) private var appModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: appModel.thinkingLevel.symbol)
                    .foregroundStyle(Theme.reasoningAccent)
                Text(appModel.thinkingLevel.displayName)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .buttonStyle(VelaControlButtonStyle(tint: Theme.reasoningAccent))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ThinkingPaletteView(isPresented: $isPresented)
        }
        .help("Choose the exact thinking controls supported by the selected model.")
    }
}

struct ContextButton: View {
    @Environment(AppModel.self) private var appModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "circle.dotted")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accentSoft.opacity(0.8), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ContextInspector()
        }
        .help(appModel.contextTooltip)
        .accessibilityLabel("Context window")
        .accessibilityValue(appModel.contextTooltip)
    }
}

/// Appears when search is reachable — either the provider searches natively
/// (Perplexity, OpenRouter) or a SearXNG endpoint is set. Sticky like
/// ChatGPT's search toggle: stays on across sends until turned off again.
struct WebSearchToggleButton: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        Button {
            appModel.isWebSearchEnabled.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                if appModel.isWebSearchEnabled {
                    Text("Search")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .buttonStyle(VelaControlButtonStyle(tint: appModel.isWebSearchEnabled ? Theme.accentStrong : Theme.tertiaryText))
        .help(appModel.webSearchDescription)
    }
}

private struct VelaControlButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(configuration.isPressed ? 0.16 : 0.07), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(configuration.isPressed ? 0.42 : 0.12), lineWidth: 1)
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ModelPaletteView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isPresented: Bool
    @State private var query = ""

    private var profile: ProviderProfile? { appModel.selectedProvider }
    private var models: [RemoteModel] {
        guard let profile else { return [] }
        return appModel.providers.models(for: profile.id)
    }
    private var filteredModels: [RemoteModel] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = models.sorted { lhs, rhs in
            if lhs.id == appModel.currentModelID { return true }
            if rhs.id == appModel.currentModelID { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        guard !value.isEmpty else { return source }
        return source.filter {
            $0.id.lowercased().contains(value) ||
            $0.displayName.lowercased().contains(value) ||
            ($0.ownedBy?.lowercased().contains(value) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose a model")
                        .font(.headline)
                    Text(profile?.name ?? "No provider")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.bottom, 12)

            TextField("Search model names or IDs", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 10)

            Divider()

            if profile == nil {
                EmptyState(symbol: "server.rack", title: "No provider", message: "Choose a connection first.")
                    .frame(height: 220)
            } else if let profile, appModel.providers.isDiscovering(id: profile.id) && models.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Finding available models…")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                    Text("The catalog comes directly from \(profile.name).")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else if models.isEmpty {
                providerDefault
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if filteredModels.isEmpty {
                ContentUnavailableView("No matching models", systemImage: "magnifyingglass", description: Text("Try a different name or model ID."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredModels) { model in
                            ModelPaletteRow(
                                model: model,
                                selected: model.id == appModel.currentModelID,
                                action: {
                                    appModel.selectModel(model)
                                    isPresented = false
                                }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 390)
            }

            Divider()
                .padding(.top, 10)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.arrow.trianglehead.counterclockwise")
                    .foregroundStyle(Theme.accent)
                Text("Last exact choice is remembered")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                if let profile, profile.kind != .preview {
                    Button("Refresh") {
                        Task { await appModel.providers.refreshModels(id: profile.id) }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.top, 9)
        }
        .padding(16)
        .frame(width: 430)
        .frame(minHeight: 250)
    }

    private var providerDefault: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            Text("Provider default")
                .font(.body.weight(.medium))
            Text("The endpoint did not publish a catalog. VelaChat will use its provider fallback without asking you to type a model ID.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }
}

private struct ModelPaletteRow: View {
    let model: RemoteModel
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.isLocal ? "internaldrive" : "cpu")
                    .foregroundStyle(model.isLocal ? Theme.success : Theme.modelAccent)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if model.supportsReasoning {
                            Text("Think")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.reasoningAccent)
                        }
                    }
                    Text(model.id)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        if let context = model.contextLabel { Text(context) }
                        if let size = model.sizeLabel { Text(size) }
                        if model.supportsVision { Text("Vision") }
                        if model.supportsTools { Text("Tools") }
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(selected ? Theme.accentSoft.opacity(0.82) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ThinkingPaletteView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isPresented: Bool

    private var levels: [ThinkingLevel] { appModel.availableThinkingLevels }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Thinking controls")
                        .font(.headline)
                    Text(appModel.selectedModelInfo?.displayName ?? appModel.selectedModel)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(levels) { level in
                    Button {
                        appModel.setThinkingLevel(level)
                        isPresented = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: level.symbol)
                                .foregroundStyle(level == .off ? Theme.tertiaryText : Theme.reasoningAccent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(level.displayName)
                                    .font(.body.weight(.medium))
                                Text(level.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                if level != .auto {
                                    Text("Sends \(level.wireLabel)")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                            }
                            Spacer()
                            if level == appModel.thinkingLevel {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.reasoningAccent)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .background(level == appModel.thinkingLevel ? Theme.reasoningAccent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(reasoningNote)
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 10)
        }
        .padding(16)
        .frame(width: 360)
    }

    private var reasoningNote: String {
        if levels.count == 1 {
            return "This model does not advertise a configurable reasoning parameter. Auto leaves its native behavior unchanged."
        }
        if appModel.selectedProvider?.kind == .deepSeek {
            return "DeepSeek’s current API supports Auto, Off, Low, High, and Max. Medium and Extra High are intentionally not shown because DeepSeek maps them to other values."
        }
        return "Only controls supported or documented for the selected provider and model are shown."
    }
}

private struct ContextInspector: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Context window")
                        .font(.headline)
                    Text(appModel.selectedModelInfo?.displayName ?? appModel.selectedModel)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }

            if let window = appModel.contextWindow {
                let used = min(appModel.contextTokenEstimate, window)
                let fraction = min(1, max(0, Double(used) / Double(window)))
                ProgressView(value: fraction)
                    .tint(fraction > 0.8 ? Theme.warning : Theme.accent)
                HStack {
                    Text("~\(appModel.formattedTokenCount(used)) used")
                    Spacer()
                    Text("\(appModel.formattedTokenCount(window)) available")
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            } else {
                Text("This provider did not publish a context limit. The endpoint will enforce its own window.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }

            Divider()
            Text("The estimate counts the current conversation text. Reasoning tokens and provider-side caching can use additional capacity.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 330)
    }
}

struct RichMessageText: View {
    let text: String
    let isUser: Bool
    var parseMarkdown = true

    var body: some View {
        if parseMarkdown, !text.isEmpty {
            Markdown(text)
                .markdownTheme(.vela(isUser: isUser))
                .textSelection(.enabled)
        } else {
            Text(text.isEmpty ? " " : text)
                .font(.body)
                .foregroundStyle(isUser ? .white : Theme.text)
                .textSelection(.enabled)
        }
    }
}

/// A real, always-visible way out of native fullscreen. macOS hides the
/// traffic lights (including the green exit-fullscreen control) for every
/// app while in fullscreen — that's a system limit, not something any app's
/// window configuration can override — so this is the substitute rather than
/// a fake traffic light.
struct ExitFullScreenButton: View {
    var body: some View {
        Button {
            NSApp.keyWindow?.toggleFullScreen(nil)
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.tertiaryText)
        .help("Exit Full Screen")
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Theme.success : Theme.tertiaryText)
        .help(copied ? "Copied" : "Copy response")
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
