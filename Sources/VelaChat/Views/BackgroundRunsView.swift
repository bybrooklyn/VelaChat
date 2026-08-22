import SwiftUI
import VelaCore

/// The background-runs surface — ONE view, deliberately mounted twice (the
/// sidebar's in-window indicator popover and the menu-bar app): they cannot
/// drift apart because there are not two implementations to drift. It
/// renders only while something is actually running and disappears entirely
/// when idle; callers gate on `runs.isEmpty`, so the idle state isn't even
/// an empty list on screen.
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
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(runs.count == 1 ? "1 conversation running" : "\(runs.count) conversations running")
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

/// The in-window mount: a compact live indicator in the sidebar's action
/// row that exists ONLY while something runs — tapping opens the shared
/// background-runs view as a popover. Idle, it vanishes and the row looks
/// exactly as it did before, which is the whole point of the surface.
struct BackgroundRunsIndicator: View {
    @Environment(AppModel.self) private var appModel
    @State private var showsPopover = false

    private var runCount: Int {
        appModel.conversations.filter(\.isGenerating).count
    }

    var body: some View {
        if runCount > 0 {
            Button {
                showsPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .symbolEffectPulse()
                    Text("\(runCount)")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.accentForeground)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.accentStrong, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Conversations running in the background")
            .accessibilityLabel("\(runCount) conversations running in the background")
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                BackgroundRunsView()
                    .padding(12)
                    .frame(width: 300)
            }
            .transition(.scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
        }
    }
}
