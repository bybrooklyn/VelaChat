import SwiftUI

private struct ProviderUsageRow: View {
    @Environment(AppModel.self) private var appModel
    let profile: ProviderProfile

    var body: some View {
        let today = appModel.usage.today(providerID: profile.id)
        let month = appModel.usage.thisMonth(providerID: profile.id)
        if month.requests > 0 {
            LabeledContent(profile.name) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("today \(today.requests) req · \(today.totalTokens) tok\(today.costLabel.map { " · \($0)" } ?? "")")
                    Text("month \(month.requests) req · \(month.totalTokens) tok\(month.costLabel.map { " · \($0)" } ?? "")")
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            }
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

    var body: some View {
        Form {
            Section("Lifetime") {
                LabeledContent("Conversations") { Text("\(conversations.count)") }
                LabeledContent("Messages") { Text("\(totalMessages)") }
                LabeledContent("Attachments sent") { Text("\(totalAttachments)") }
                LabeledContent("Pinned conversations") { Text("\(pinnedCount)") }
                if let oldestConversationDate {
                    LabeledContent("First conversation") {
                        Text(oldestConversationDate, style: .date)
                    }
                }
            }

            Section {
                LabeledContent("Input tokens") { Text(appModel.formattedTokenCount(totalInputTokens)) }
                LabeledContent("Output tokens") { Text(appModel.formattedTokenCount(totalOutputTokens)) }
                LabeledContent("Total") { Text(appModel.formattedTokenCount(totalInputTokens + totalOutputTokens)) }
                if totalCachedTokens > 0 {
                    LabeledContent("Served from cache") {
                        Text(appModel.formattedTokenCount(totalCachedTokens))
                            .foregroundStyle(Theme.success)
                    }
                }
            } header: {
                Text("Tokens")
            } footer: {
                Text("Only counts replies where the provider actually reported usage — not every provider does on every request, so this can undercount. \"Served from cache\" is real provider-reported cache-hit tokens (OpenAI, DeepSeek, and Anthropic all report this; VelaChat also sets Anthropic's cache_control explicitly since, unlike the other two, it isn't automatic there).")
            }

            Section {
                if modelUsage.isEmpty {
                    Text("No replies yet.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    ForEach(modelUsage, id: \.label) { entry in
                        LabeledContent(entry.label) {
                            Text("\(entry.count) repl\(entry.count == 1 ? "y" : "ies")")
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            } header: {
                Text("Model Usage")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Statistics")
        .frame(maxWidth: Theme.Layout.settingsWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
