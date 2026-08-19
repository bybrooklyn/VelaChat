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

/// The provider's real fetched logo when available, the hand-drawn vector
/// mark otherwise. Custom endpoints derive their host from the base URL
/// (skipping localhost/private ranges, which have no public logo).
struct ProviderLogoView: View {
    let kind: ProviderKind
    var endpoint: String? = nil
    var size: CGFloat = 26

    private var host: String? {
        if kind == .compatible, let endpoint, let host = URL(string: endpoint)?.host {
            let lowered = host.lowercased()
            let isPrivate = lowered == "localhost"
                || lowered.hasSuffix(".local")
                || lowered.hasPrefix("127.")
                || lowered.hasPrefix("10.")
                || lowered.hasPrefix("192.168.")
                || lowered.hasPrefix("0.")
            return isPrivate ? nil : lowered
        }
        return kind.logoDomain
    }

    var body: some View {
        Group {
            if let host, let image = RemoteLogoLoader.shared.images[host] {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Theme.controlBackground)
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size * 0.72, height: size * 0.72)
                            .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
                    .frame(width: size, height: size)
            } else {
                ProviderLogo(kind: kind, size: size)
            }
        }
        .task(id: host) {
            if let host { await RemoteLogoLoader.shared.ensure(host: host) }
        }
    }
}

struct ProviderMark: View {
    let kind: ProviderKind
    var size: CGFloat = 18

    var body: some View {
        ProviderLogoView(kind: kind, size: size)
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

                    // Active rows shimmer instead of showing a spinner —
                    // the app-wide "something is happening" treatment.
                    if isActive {
                        ShimmerText(text: title, font: .callout)
                            .lineLimit(1)
                    } else {
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }

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
                    isHovering && isExpandable ? Theme.surfaceMid : Color.clear,
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
                    .contentTransition(.opacity)
                    // A stable floor so the control doesn't visibly shrink
                    // and grow as the label resolves from "Finding a
                    // model…" to a real ID.
                    .frame(minWidth: 78, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .animation(.easeOut(duration: 0.15), value: appModel.currentModelID)
        }
        .buttonStyle(VelaControlButtonStyle(tint: Theme.modelAccent))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelPaletteView(isPresented: $isPresented)
        }
        .help("Choose a model. Your last choice is remembered for this provider.")
        .accessibilityLabel("Choose a model. Your last choice is remembered for this provider.")
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
                    .contentTransition(.symbolEffect(.replace))
                Text(appModel.thinkingLevel.displayName)
                    .font(.caption.weight(.semibold))
                    .contentTransition(.opacity)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .animation(.easeOut(duration: 0.15), value: appModel.thinkingLevel)
        }
        .buttonStyle(VelaControlButtonStyle(tint: Theme.reasoningAccent))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ThinkingPaletteView(isPresented: $isPresented)
        }
        .help("Choose the exact thinking controls supported by the selected model.")
        .accessibilityLabel("Choose the exact thinking controls supported by the selected model.")
    }
}

struct ContextButton: View {
    @Environment(AppModel.self) private var appModel
    @State private var isPresented = false

    /// Fraction of the detected context window in use — `nil` when the
    /// window is unknown (the ring falls back to the dotted glyph).
    private var fraction: Double? {
        guard let window = appModel.contextWindow, window > 0 else { return nil }
        return min(1, Double(appModel.contextTokenEstimate) / Double(window))
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            // The button shows its state: a filled progress ring, warning-
            // tinted past 80% — no click needed to learn you're nearly full.
            // Fill tint is accentStrong (like Send), not the pale foreground
            // accent that used to render this as a blown-out white disc.
            // Neutral chrome like the plus button — the teal glass disc
            // read as oddly bright, and its glass merged with Send's.
            ZStack {
                if let fraction {
                    Circle()
                        .stroke(Theme.controlStroke.opacity(0.8), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(
                            fraction > 0.8 ? Theme.warning : Theme.accent,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle()
                        .stroke(Theme.controlStroke.opacity(0.9), lineWidth: 2)
                }
            }
            .frame(width: 14, height: 14)
            .frame(width: 30, height: 30)
            .background(Theme.surfaceHigh, in: Circle())
            .overlay { Circle().stroke(Theme.controlStroke.opacity(0.6), lineWidth: 1) }
            .animation(.easeOut(duration: 0.35), value: fraction)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ContextInspector()
        }
        .help(appModel.contextTooltip)
        .accessibilityLabel(appModel.contextTooltip)
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
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: appModel.isWebSearchEnabled)
        }
        .buttonStyle(VelaControlButtonStyle(tint: appModel.isWebSearchEnabled ? Theme.accentStrong : Theme.tertiaryText))
        .help(appModel.webSearchDescription)
        .accessibilityLabel(appModel.webSearchDescription)
    }
}

/// A quiet left-to-right sheen sweeping dim text — the app's "something is
/// happening" treatment. Deliberately not a ProgressView: no spinners.
struct ShimmerText: View {
    let text: String
    var font: Font = .callout

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            let phase = CGFloat(cycle) * 1.5 - 0.25  // sweep past both edges
            Text(text)
                .font(font)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Theme.tertiaryText, location: 0),
                            .init(color: Theme.tertiaryText, location: max(0, min(1, phase - 0.22))),
                            .init(color: Theme.secondaryText, location: max(0, min(1, phase))),
                            .init(color: Theme.tertiaryText, location: max(0, min(1, phase + 0.22))),
                            .init(color: Theme.tertiaryText, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}

extension View {
    /// A quiet opacity pulse for tiny status dots — the no-spinner stand-in
    /// for ProgressView(.mini).
    func symbolEffectPulse() -> some View {
        modifier(PulseOpacity())
    }
}

private struct PulseOpacity: ViewModifier {
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}

struct VelaControlButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            // A fixed height, not just vertical padding, so every pill in
            // the composer row lines up exactly with the 30pt circular send
            // and context buttons instead of each control finding its own
            // height off its own font size.
            .frame(height: 30)
            // Flat, not `.glassCapsule` — every pill in the composer used to
            // share one `GlassEffectContainer`, whose whole purpose is to
            // visually lens/merge adjacent glass shapes together, which read
            // as one fused blob instead of separate controls. A flat
            // neutral fill (tinted only by its own icon/text, matching the
            // sidebar's already-fixed search-toggle button) keeps each pill
            // a clearly distinct box.
            .background(Theme.surfaceHigh, in: Capsule())
            .overlay {
                Capsule().stroke(Theme.controlStroke.opacity(0.6), lineWidth: 1)
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Press feedback for a bare icon-only `.borderless` button — no
/// background chrome (unlike `VelaControlButtonStyle`), just the same
/// opacity+scale spring `SendButtonStyle` already established, so icon
/// buttons scattered through message rows/panels/Settings don't feel dead
/// next to controls that do have this feedback.
struct VelaIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Shows every provider that's actually usable right now — not just the
/// currently selected one — grouped with its own models underneath, so
/// switching to a model on a different provider is one click instead of
/// switching providers first and reopening this picker. Preview only
/// appears when nothing real is configured yet, so a fresh install still
/// has something to click.
private struct ModelPaletteView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isPresented: Bool
    @State private var query = ""

    private var groupProfiles: [ProviderProfile] {
        // Every provider is listed, configured or not — the picker's job
        // is to show what you could switch to, and an unconfigured row
        // still explains what it needs.
        let configured = appModel.providers.profiles.filter { appModel.providers.isConfigured($0) }
        return configured.isEmpty ? appModel.providers.profiles : configured
    }

    private func filteredModels(for profile: ProviderProfile) -> [RemoteModel] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isCurrentProvider = profile.id == appModel.selectedProvider?.id
        // Strongest-to-weakest within each provider, using the same
        // heuristic that already picks the default model on first connect
        // — not alphabetical, which told you nothing about which model was
        // actually worth picking.
        let source = appModel.providers.models(for: profile.id).sorted { lhs, rhs in
            if isCurrentProvider {
                if lhs.id == appModel.currentModelID { return true }
                if rhs.id == appModel.currentModelID { return false }
            }
            let lhsScore = ModelCatalog.score(lhs, for: profile.kind)
            let rhsScore = ModelCatalog.score(rhs, for: profile.kind)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        guard !value.isEmpty else { return source }
        return source.filter {
            $0.id.lowercased().contains(value) ||
            $0.displayName.lowercased().contains(value) ||
            ($0.ownedBy?.lowercased().contains(value) ?? false)
        }
    }

    /// While searching, a provider group with no matching models (and whose
    /// own name doesn't match either) is hidden entirely rather than shown empty.
    private var visibleGroups: [ProviderProfile] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return groupProfiles }
        return groupProfiles.filter { profile in
            profile.name.lowercased().contains(value) || !filteredModels(for: profile).isEmpty
        }
    }

    /// Favorites (starred) and Recents pinned above the provider groups —
    /// keys resolved against live profiles/catalogs, stale ones skipped.
    @ViewBuilder
    private var pinnedGroups: some View {
        let resolvedFavorites = resolve(keys: Array(appModel.providers.favoriteModelKeys).sorted())
        let resolvedRecents = resolve(keys: appModel.providers.recentModelKeys)
            .filter { pair in !resolvedFavorites.contains { $0.1.id == pair.1.id && $0.0.id == pair.0.id } }
        if !resolvedFavorites.isEmpty {
            pinnedGroup(title: "Favorites", symbol: "star.fill", pairs: resolvedFavorites)
        }
        if !resolvedRecents.isEmpty {
            pinnedGroup(title: "Recent", symbol: "clock", pairs: resolvedRecents)
        }
    }

    private func resolve(keys: [String]) -> [(ProviderProfile, RemoteModel)] {
        keys.compactMap { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let providerID = UUID(uuidString: parts[0]),
                  let profile = groupProfiles.first(where: { $0.id == providerID }),
                  let model = appModel.providers.models(for: providerID).first(where: { $0.id == parts[1] }) else { return nil }
            return (profile, model)
        }
    }

    private func pinnedGroup(title: String, symbol: String, pairs: [(ProviderProfile, RemoteModel)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(pairs, id: \.1.id) { profile, model in
                    ModelPaletteRow(
                        model: model,
                        selected: profile.id == appModel.selectedProvider?.id && model.id == appModel.currentModelID,
                        recommended: false,
                        providerKind: profile.kind,
                        providerID: profile.id,
                        action: {
                            appModel.selectProviderAndModel(profile, model: model)
                            isPresented = false
                        }
                    )
                }
            }
            .padding(6)
        }
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous), emphasis: 0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose a model")
                        .font(.headline)
                    Text(appModel.selectedModelInfo?.displayName ?? appModel.selectedModel)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.glass)
                    .tint(Theme.accent)
            }
            .padding(.bottom, 12)

            TextField("Search models or providers", text: $query)
                .textFieldStyle(.plain)
                .flatFieldStyle()
                .padding(.bottom, 10)

            Divider()

            if groupProfiles.isEmpty {
                EmptyState(symbol: "server.rack", title: "No provider", message: "Choose a connection first.")
                    .frame(height: 220)
            } else if visibleGroups.isEmpty {
                ContentUnavailableView("No matching models", systemImage: "magnifyingglass", description: Text("Try a different name or model ID."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            pinnedGroups
                        }
                        ForEach(visibleGroups) { profile in
                            ModelPaletteGroup(
                                profile: profile,
                                models: filteredModels(for: profile),
                                selectedModelID: profile.id == appModel.selectedProvider?.id ? appModel.currentModelID : nil,
                                showRecommended: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                action: { model in
                                    appModel.selectProviderAndModel(profile, model: model)
                                    isPresented = false
                                }
                            )
                        }
                    }
                    .padding(.top, 10)
                    .animation(.easeOut(duration: 0.18), value: visibleGroups.map(\.id))
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 560)
            }

            Divider()
                .padding(.top, 10)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.arrow.trianglehead.counterclockwise")
                    .foregroundStyle(Theme.accent)
                Text("Last exact choice is remembered per provider")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
            }
            .padding(.top, 9)
        }
        .padding(16)
        .frame(width: 560)
        .frame(minHeight: 250)
        // Every configured provider's catalog starts fetching the moment
        // this popover opens, not just the currently-selected one —
        // previously only the selected provider was ever auto-discovered,
        // so any other configured provider sat empty ("did not publish a
        // catalog") until the user manually tapped its refresh icon.
        // `discoverIfNeeded` already no-ops for a freshly-fetched catalog
        // and de-dupes in-flight requests, so calling it broadly here is
        // safe on every open.
        .task {
            for profile in groupProfiles {
                appModel.providers.discoverIfNeeded(id: profile.id)
            }
        }
    }
}

private struct ModelPaletteGroup: View {
    @Environment(AppModel.self) private var appModel
    let profile: ProviderProfile
    let models: [RemoteModel]
    let selectedModelID: String?
    let showRecommended: Bool
    let action: (RemoteModel) -> Void

    var body: some View {
        // Each provider is its own visible card — spacing alone read as one
        // continuous list with faint seams between providers instead of
        // clearly separate groups.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ProviderGlyphView(kind: profile.kind, size: 17, color: Theme.text)
                Text(profile.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                if appModel.providers.isDiscovering(id: profile.id) {
                    Circle()
                        .fill(Theme.tertiaryText)
                        .frame(width: 5, height: 5)
                        .symbolEffectPulse()
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            // Refresh moved off the visible header (redundant now that
            // every configured provider auto-fetches on open — a manual
            // refresh icon on every card just read as clutter/a
            // broken-looking control) and into a context menu, still
            // reachable for the rare case a catalog genuinely needs a
            // forced re-fetch.
            .contextMenu {
                if true {
                    Button {
                        Task { await appModel.providers.refreshModels(id: profile.id) }
                    } label: {
                        Label("Refresh Catalog", systemImage: "arrow.clockwise")
                    }
                }
            }

            Divider()

            if models.isEmpty {
                Text(appModel.providers.isDiscovering(id: profile.id) ? "Finding available models…" : "Uses \(profile.kind.automaticFallbackModel) automatically — this endpoint did not publish a catalog.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        ModelPaletteRow(
                            model: model,
                            selected: model.id == selectedModelID,
                            recommended: showRecommended && index == 0 && models.count > 1,
                            providerKind: profile.kind,
                            providerID: profile.id,
                            action: { action(model) }
                        )
                    }
                }
                .padding(6)
            }
        }
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous), emphasis: 0.5)
    }
}

private struct ModelPaletteRow: View {
    @Environment(AppModel.self) private var appModel
    let model: RemoteModel
    let selected: Bool
    let recommended: Bool
    var providerKind: ProviderKind = .compatible
    var providerID: UUID? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ProviderGlyphView(kind: providerKind, size: 18, color: Theme.secondaryText)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.body.weight(recommended ? .semibold : .medium))
                            .lineLimit(1)
                        if recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accentForeground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
                    // One subtitle line, not three — the description when the
                    // catalog has one, the raw ID otherwise. The full ID is
                    // always in the tooltip.
                    if let description = model.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    } else {
                        Text(model.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    HStack(spacing: 9) {
                        if let context = model.contextLabel {
                            Label(context, systemImage: "arrow.left.and.right")
                        }
                        if let resource = model.quantizationLevel != nil ? model.resourceLabel : model.sizeLabel {
                            Label(resource, systemImage: "cube")
                        }
                        if model.supportsReasoning {
                            Label("Think", systemImage: "brain")
                                .foregroundStyle(Theme.reasoningAccent)
                        }
                        if model.supportsVision {
                            Label("Vision", systemImage: "eye")
                        }
                        if model.supportsTools {
                            Label("Tools", systemImage: "wrench.and.screwdriver")
                        }
                        if let tier = model.priceTier {
                            Label(tier, systemImage: tier == "Free" ? "gift" : "dollarsign.circle")
                                .foregroundStyle(tier == "Free" ? Theme.success : Theme.tertiaryText)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 6)
                if let providerID {
                    let isFavorite = appModel.providers.isFavorite(providerID: providerID, modelID: model.id)
                    if isFavorite || isHovering {
                        Button {
                            appModel.providers.toggleFavorite(providerID: providerID, modelID: model.id)
                        } label: {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.system(size: 11))
                                .foregroundStyle(isFavorite ? Theme.accent : Theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help(isFavorite ? "Remove from favorites" : "Add to favorites")
                        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                    }
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                selected ? Theme.accentSoft.opacity(0.82) : (isHovering ? Theme.surfaceMid : Color.clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(model.id)
        .accessibilityLabel(model.id)
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
                    .buttonStyle(.glass)
                    .tint(Theme.accent)
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
    @State private var isEditingLimit = false
    @State private var editText = ""

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
                let remainingPercent = Int((1 - fraction) * 100)
                // Leads with what you're about to spend, Claude-Code-style —
                // "how much room is left" is the number that actually
                // matters before you hit Send, not the raw token counts.
                Text("\(remainingPercent)% left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(fraction > 0.8 ? Theme.warning : Theme.text)
                ProgressView(value: fraction)
                    .tint(fraction > 0.8 ? Theme.warning : Theme.accent)
                HStack {
                    Text("~\(appModel.formattedTokenCount(used)) used")
                    Spacer()
                    Text("\(appModel.formattedTokenCount(window)) total")
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            } else {
                Text("This provider did not publish a context limit. The endpoint will enforce its own window.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }

            contextLimitEditor

            if let conversation = appModel.activeConversation, conversation.realMessages.count >= 6 {
                Divider()
                Button {
                    appModel.compactConversation(conversation)
                } label: {
                    Label(
                        conversation.lastCompactionIndex != nil ? "Compact again" : "Compact this conversation",
                        systemImage: "arrow.down.right.and.arrow.up.left"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(conversation.isGenerating)
                Text("Summarizes older messages so they use less context on future turns. Pinned messages and the most recent exchanges are always kept verbatim, never summarized. Nothing is deleted from the transcript — auto-triggers around 85% full too.")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// Auto-detection only works when a catalog publishes a context length,
    /// which most don't — and even when it does, it can be wrong for a
    /// custom or self-hosted endpoint. This is the one place to correct it.
    @ViewBuilder
    private var contextLimitEditor: some View {
        if isEditingLimit {
            HStack(spacing: 6) {
                TextField("e.g. 128000", text: $editText)
                    .textFieldStyle(.plain)
                    .flatFieldStyle()
                    .frame(width: 110)
                Button("Set") {
                    appModel.setContextWindowOverride(Int(editText.filter(\.isNumber)))
                    isEditingLimit = false
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(Int(editText.filter(\.isNumber)) == nil)
                Button("Cancel") { isEditingLimit = false }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .font(.caption)
        } else {
            HStack(spacing: 8) {
                Button(appModel.contextWindow == nil ? "Set context limit" : "Correct this") {
                    editText = appModel.contextWindow.map(String.init) ?? ""
                    isEditingLimit = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                if appModel.contextWindowIsOverridden {
                    Text("· manually set")
                        .foregroundStyle(Theme.tertiaryText)
                    Button("Reset to auto") {
                        appModel.setContextWindowOverride(nil)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
            }
            .font(.caption)
        }
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
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Theme.success : Theme.tertiaryText)
        .help(copied ? "Copied" : "Copy response")
        .accessibilityLabel(copied ? "Copied" : "Copy response")
        .animation(.easeOut(duration: 0.12), value: copied)
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
