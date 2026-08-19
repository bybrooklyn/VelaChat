import SwiftUI

/// The sidebar's little usage gauge — sits beside New Chat/search, opens
/// a provider-tailored usage view. Hidden entirely for local providers
/// (Ollama/LM Studio/preview/on-device): they cost nothing, a gauge
/// would be noise.
struct UsageGaugeButton: View {
    @Environment(AppModel.self) private var appModel
    @State private var isPresented = false

    var body: some View {
        if appModel.selectedProvider?.kind.usageStyle != ProviderKind.UsageStyle.local {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 34, height: 34)
                    // Flat, matching its row siblings — a standalone glass chip
                    // here rendered a stray halo (documented lesson).
                    .background(Theme.controlBackground.opacity(0.75), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                            .stroke(Theme.controlStroke.opacity(0.6), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("Usage for the current provider")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                UsagePopover()
            }
        }
    }
}

/// One view, three shapes:
/// - subscription (Codex, ChatGPT): ONLY the provider's real plan
///   windows — plan name, percent gauges, reset countdowns, and an
///   honest "as of" age. Local token counts live in Statistics, not
///   here, so the popover never shows two disagreeing accountings.
/// - metered (API-key providers): locally counted meters plus whatever
///   live rate-limit headers the provider sent.
/// - local: no popover at all (the button is hidden).
struct UsagePopover: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let provider = appModel.selectedProvider {
                HStack(spacing: 8) {
                    ProviderLogoView(kind: provider.kind, endpoint: provider.endpoint, size: 22)
                    Text(provider.name)
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                switch provider.kind.usageStyle {
                case .subscription:
                    subscriptionBody(provider)
                case .metered:
                    meteredBody(provider)
                case .local:
                    EmptyView()
                }
            } else {
                Text("No provider selected.")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(14)
        .frame(width: 300)
        .task {
            if let provider = appModel.selectedProvider, provider.kind == .chatGPT {
                await appModel.refreshChatGPTQuota(provider.id)
            }
        }
    }

    // MARK: - Subscription (plan windows only)

    @ViewBuilder
    private func subscriptionBody(_ provider: ProviderProfile) -> some View {
        if let quota = appModel.quotaByProvider[provider.id] {
            VStack(alignment: .leading, spacing: 10) {
                if let plan = quota.planName {
                    Text("\(plan) plan")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                if let window = quota.primaryWindow {
                    windowRow(window)
                }
                if let window = quota.secondaryWindow {
                    windowRow(window)
                }
                if quota.primaryWindow == nil, quota.secondaryWindow == nil {
                    Text("The provider hasn't reported plan windows yet.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Text("Live from the provider · as of \(quota.capturedAt, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
        } else {
            Text("Plan usage comes from the provider's own response data — send a message and it appears here.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - Metered (local meters + live headers)

    @ViewBuilder
    private func meteredBody(_ provider: ProviderProfile) -> some View {
        if let quota = appModel.quotaByProvider[provider.id] {
            liveQuotaSection(quota)
        }
        meterRow("Last 5 hours", appModel.usage.rollingFiveHours(providerID: provider.id))
        meterRow("Today", appModel.usage.today(providerID: provider.id))
        meterRow("This week", appModel.usage.thisWeek(providerID: provider.id))
        meterRow("This month", appModel.usage.thisMonth(providerID: provider.id))
        Text("Counted locally on this Mac. Dollar amounts use provider-published pricing only.")
            .font(.caption2)
            .foregroundStyle(Theme.tertiaryText)
    }

    @ViewBuilder
    private func liveQuotaSection(_ quota: QuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = quota.usedFraction {
                Gauge(value: fraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(fraction > 0.8 ? Theme.warning : Theme.accent)
            }
            HStack(spacing: 8) {
                if let remaining = quota.requestsRemaining, let limit = quota.requestsLimit {
                    Text("\(remaining)/\(limit) requests left")
                } else if let remaining = quota.tokensRemaining {
                    Text("\(remaining) tokens left")
                }
                Spacer(minLength: 0)
                if let resetAt = quota.resetAt {
                    Text("resets \(resetAt, style: .relative)")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
            Text("Rate limits from the provider · as of \(quota.capturedAt, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(10)
        .background(Theme.controlBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
    }

    private func windowRow(_ window: QuotaSnapshot.Window) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Text("\(Int(window.usedPercent))% used")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Gauge(value: min(max(window.usedPercent / 100, 0), 1)) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(window.usedPercent > 80 ? Theme.warning : Theme.accent)
            if let resetAt = window.resetAt {
                Text("resets \(resetAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    private func meterRow(_ title: String, _ window: UsageWindow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(window.requests == 0
                     ? "—"
                     : "\(window.requests) request\(window.requests == 1 ? "" : "s") · \(window.totalTokens) tokens")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                if let cost = window.costLabel {
                    Text(cost)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }
}
