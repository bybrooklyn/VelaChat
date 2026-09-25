import SwiftUI
import VelaCore

/// The sidebar's little usage gauge — sits beside New Chat/search, opens
/// a provider-tailored usage view. Hidden entirely for local providers
/// (Ollama/LM Studio/preview/on-device): they cost nothing, a gauge
/// would be noise.
struct UsageGaugeButton: View {
    @Environment(AppModel.self) private var appModel
    @State private var isPresented = false

    var body: some View {
        if let provider = appModel.selectedProvider, provider.kind.usageStyle != ProviderKind.UsageStyle.local {
            Button {
                // A click always wants current numbers, staleness window
                // or not.
                appModel.refreshQuota(for: provider, force: true)
                isPresented.toggle()
            } label: {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 34, height: 34)
                    // Flat, matching its row siblings — a standalone glass chip
                    // here rendered a stray halo (documented lesson).
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                    .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Usage for the current provider")
            .accessibilityLabel("Usage for the current provider")
            // Hovering starts the refresh so the numbers are already
            // current by the time the popover opens. Debounced by
            // staleness inside `refreshQuota`, so repeated hovers are free.
            .onHover { hovering in
                guard hovering else { return }
                appModel.refreshQuota(for: provider)
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                UsagePopover {
                    isPresented = false
                    SettingsNavigator.openUsageAndLimits(in: appModel)
                }
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
    @State private var todayUsage: UsageAggregate?
    @State private var isLoadingLocalUsage = false
    var onOpenUsageAndLimits: (() -> Void)?

    init(onOpenUsageAndLimits: (() -> Void)? = nil) {
        self.onOpenUsageAndLimits = onOpenUsageAndLimits
    }

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
                Divider()
                Button("Open Usage & Limits") {
                    onOpenUsageAndLimits?()
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text("No provider selected.")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(14)
        .frame(width: 300)
        .task(id: appModel.selectedProvider?.id) {
            if let provider = appModel.selectedProvider {
                appModel.refreshQuota(for: provider, force: true)
                isLoadingLocalUsage = true
                let report = try? await UsageLedger.shared.query(
                    UsageQuery(period: .today, providerID: provider.id)
                )
                todayUsage = report?.aggregate
                isLoadingLocalUsage = false
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
        if isLoadingLocalUsage {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Loading today's local usage…")
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
        } else if let usage = todayUsage {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.callout)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(todayUsageLabel(usage))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    if let cost = usage.cost.amountUSD {
                        let partial = usage.cost.coverage.indeterminateRequests > 0
                            || usage.cost.coverage.unreportedRequests > 0
                        Text(String(format: "\(partial ? "≥ " : "")$%.4f observed", cost))
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
        }
        Text("Counted from the durable local request ledger. Open Usage & Limits for trends and breakdowns.")
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
                } else if let used = quota.creditUsed {
                    // OpenRouter key credits: absolute spend always, cap
                    // only when the key has one set.
                    if let limit = quota.creditLimit {
                        Text(String(format: "$%.2f of $%.2f credits used", used, limit))
                    } else {
                        Text(String(format: "$%.2f credits used (no key cap set)", used))
                    }
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
        .background(Theme.surfaceMid, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
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

    private func todayUsageLabel(_ usage: UsageAggregate) -> String {
        let tokens: Int? = usage.inputTokens.value == nil && usage.outputTokens.value == nil
            ? nil
            : (usage.inputTokens.value ?? 0) + (usage.outputTokens.value ?? 0)
        let tokenLabel = tokens.map { appModel.formattedTokenCount($0) + " tokens" } ?? "usage unreported"
        return "\(usage.requestCount) request\(usage.requestCount == 1 ? "" : "s") · \(tokenLabel)"
    }
}
