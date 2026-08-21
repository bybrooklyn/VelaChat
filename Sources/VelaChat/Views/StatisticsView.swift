import SwiftUI
import VelaCore

private struct ProviderUsageRow: View {
    @Environment(AppModel.self) private var appModel
    let profile: ProviderProfile

    var body: some View {
        let fiveHours = appModel.usage.rollingFiveHours(providerID: profile.id)
        let today = appModel.usage.today(providerID: profile.id)
        let week = appModel.usage.thisWeek(providerID: profile.id)
        let month = appModel.usage.thisMonth(providerID: profile.id)
        if month.requests > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProviderLogoView(kind: profile.kind, endpoint: profile.endpoint, size: 18)
                    Text(profile.name)
                        .font(.body.weight(.medium))
                    Spacer(minLength: 0)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    windowLine("Last 5 hours", fiveHours)
                    windowLine("Today", today)
                    windowLine("This week", week)
                    windowLine("This month", month)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func windowLine(_ title: String, _ window: UsageWindow) -> some View {
        GridRow {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
            Text(window.requests == 0
                 ? "—"
                 : "\(window.requests) req · \(window.totalTokens) tok\(window.costLabel.map { " · \($0)" } ?? "")")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .gridColumnAlignment(.trailing)
        }
    }
}

/// Every number here is aggregated from data VelaChat already stores —
/// nothing estimated or fabricated. Token counts are real provider-reported
/// usage (`ChatMessage.usage`, persisted since this feature shipped — older
/// messages saved before that won't have a number and are excluded from the
/// token totals, not counted as zero).
struct StatisticsView: View {
    @Environment(AppModel.self) private var appModel

    private var conversations: [Conversation] { appModel.conversations }

    private var totalMessages: Int {
        conversations.reduce(0) { $0 + $1.realMessages.count }
    }

    private var totalInputTokens: Int {
        conversations.reduce(0) { total, conversation in
            total + conversation.messages.compactMap(\.usage?.promptTokens).reduce(0, +)
        }
    }

    private var totalOutputTokens: Int {
        conversations.reduce(0) { total, conversation in
            total + conversation.messages.compactMap(\.usage?.completionTokens).reduce(0, +)
        }
    }

    private var totalCachedTokens: Int {
        conversations.reduce(0) { total, conversation in
            total + conversation.messages.compactMap(\.usage?.cachedTokens).reduce(0, +)
        }
    }

    private var totalAttachments: Int {
        conversations.reduce(0) { total, conversation in
            total + conversation.messages.reduce(0) { $0 + $1.attachments.count }
        }
    }

    /// (label, message count), most-used first — real data from each
    /// message's stamped `providerName`/`modelID`, not a guess.
    private var modelUsage: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for conversation in conversations {
            for message in conversation.realMessages where message.role == "assistant" {
                let label = [message.providerName, message.modelID].compactMap { $0 }.joined(separator: " · ")
                guard !label.isEmpty else { continue }
                counts[label, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { (label: $0.key, count: $0.value) }
    }

    private var oldestConversationDate: Date? {
        conversations.map(\.createdAt).min()
    }

    private var pinnedCount: Int {
        conversations.filter(\.isPinned).count
    }

    /// Built from `SettingsPanel`, not `Form(.grouped)`: a grouped Form
    /// paints its own background at its own width, which rendered as a
    /// large lighter rectangle with a hard seam sitting off-centre in the
    /// pane — visibly a different app from the Settings screen one back
    /// button away. See SettingsChrome.swift.
    var body: some View {
        SettingsPage {
            SettingsPanel(title: "Lifetime", symbol: "chart.bar.xaxis") {
                SettingsValueRow("Conversations", "\(conversations.count)")
                SettingsValueRow("Messages", "\(totalMessages)")
                SettingsValueRow("Attachments sent", "\(totalAttachments)")
                SettingsValueRow("Pinned conversations", "\(pinnedCount)")
                if let oldestConversationDate {
                    SettingsValueRow(title: "First conversation") {
                        Text(oldestConversationDate, style: .date)
                    }
                }
            }

            SettingsPanel(
                title: "Tokens",
                symbol: "number",
                footer: Text("Only counts replies where the provider actually reported usage — not every provider does on every request, so this can undercount. \"Served from cache\" is real provider-reported cache-hit tokens (OpenAI, DeepSeek, and Anthropic all report this; VelaChat also sets Anthropic's cache_control explicitly since, unlike the other two, it isn't automatic there).")
            ) {
                SettingsValueRow("Input tokens", appModel.formattedTokenCount(totalInputTokens))
                SettingsValueRow("Output tokens", appModel.formattedTokenCount(totalOutputTokens))
                SettingsValueRow("Total", appModel.formattedTokenCount(totalInputTokens + totalOutputTokens))
                if totalCachedTokens > 0 {
                    SettingsValueRow(
                        "Served from cache",
                        appModel.formattedTokenCount(totalCachedTokens),
                        tint: Theme.success
                    )
                }
            }

            SettingsPanel(
                title: "Time to First Token",
                symbol: "timer",
                footer: Text("Measured from pressing send to the first word appearing — what you actually waited for, not just network time. Session-scoped, and only shown once there are at least three replies to average.")
            ) {
                let measured = appModel.providers.profiles.compactMap { profile -> (String, TimeInterval, TimeInterval, Int)? in
                    let model = profile.model.isEmpty ? appModel.providers.effectiveModel(for: profile) : profile.model
                    guard let stats = appModel.ttftStats(providerID: profile.id, model: model) else { return nil }
                    return ("\(profile.name) · \(model)", stats.median, stats.p90, stats.count)
                }
                if measured.isEmpty {
                    SettingsEmptyState(
                        text: "Not enough replies yet this session to report a meaningful figure.",
                        symbol: "timer"
                    )
                } else {
                    ForEach(measured, id: \.0) { label, median, p90, count in
                        SettingsValueRow(title: label) {
                            Text(String(format: "%.1fs median · %.1fs p90 · %d replies", median, p90, count))
                                .font(.caption)
                        }
                    }
                }
            }

            SettingsPanel(
                title: "Per-Provider Usage",
                symbol: "server.rack",
                footer: Text("Counted locally on this Mac from provider-reported token usage. Subscription plan windows (Codex) live in the sidebar gauge; these are the raw local counts.")
            ) {
                let profiles = appModel.providers.profiles.filter { $0.kind.usageStyle != .local }
                if profiles.allSatisfy({ appModel.usage.thisMonth(providerID: $0.id).requests == 0 }) {
                    SettingsEmptyState(text: "No counted requests yet this month.", symbol: "server.rack")
                } else {
                    ForEach(profiles) { profile in
                        ProviderUsageRow(profile: profile)
                    }
                }
            }

            SettingsPanel(title: "Model Usage", symbol: "cpu") {
                if modelUsage.isEmpty {
                    SettingsEmptyState(text: "No replies yet.", symbol: "cpu")
                } else {
                    ForEach(modelUsage, id: \.label) { entry in
                        SettingsValueRow(
                            entry.label,
                            "\(entry.count) repl\(entry.count == 1 ? "y" : "ies")"
                        )
                    }
                }
            }
        }
    }
}
