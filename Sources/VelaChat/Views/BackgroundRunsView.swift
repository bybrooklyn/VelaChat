import SwiftUI
import VelaCore

/// The background-runs surface used by the menu-bar app. It renders only
/// while something is actually running and disappears entirely when idle;
/// callers gate on `runs.isEmpty`, so the idle state isn't even an empty list
/// on screen.
///
/// A run here means any conversation generating in the background —
/// including triggered/scheduled runs once those spawn conversations
/// (§9.8), which surface through this same list rather than a bespoke path.
struct BackgroundRunsView: View {
    @Environment(AppModel.self) private var appModel

    private var runs: [Conversation] {
        appModel.conversations.filter(\.isGenerating)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("Running conversations")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
                Button("Stop All") {
                    appModel.stopAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .help("Stop every running conversation")
                .accessibilityLabel("Stop all running conversations")
            }

            ForEach(runs) { conversation in
                runRow(conversation)
            }
        }
    }

    private func runRow(_ conversation: Conversation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            ShimmerText(text: conversation.title, font: .subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                appModel.selectConversation(conversation)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .help("Open this conversation")
            .accessibilityLabel("Open \(conversation.title)")
            Button {
                appModel.stopGeneration(for: conversation)
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.danger)
            .help("Stop this run")
            .accessibilityLabel("Stop \(conversation.title)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.surfaceMid.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}
