import SwiftUI

/// The sidebar's little usage gauge — sits beside New Chat/search, opens
/// the current provider's meters: rolling 5h, today, week, month, plus a
/// live quota bar when the provider sent rate-limit headers this session.
struct UsageGaugeButton: View {
    @Environment(AppModel.self) private var appModel
    @State private var isPresented = false

    var body: some View {
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
                if let quota = appModel.quotaByProvider[provider.id] {
                    quotaSection(quota)
                }
                meterRow("Last 5 hours", appModel.usage.rollingFiveHours(providerID: provider.id))
                meterRow("Today", appModel.usage.today(providerID: provider.id))
                meterRow("This week", appModel.usage.thisWeek(providerID: provider.id))
                meterRow("This month", appModel.usage.thisMonth(providerID: provider.id))
                Text("Counted locally on this Mac. Dollar amounts use provider-published pricing only.")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Text("No provider selected.")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder
    private func quotaSection(_ quota: QuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
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
            Text("Live from the provider's rate-limit headers.")
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(10)
        .background(Theme.controlBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
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
