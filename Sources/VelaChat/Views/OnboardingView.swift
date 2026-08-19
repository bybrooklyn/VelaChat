import SwiftUI
import KeyboardShortcuts

/// First launch (and the landing spot after a full reset): welcome, a
/// three-card basics tour, then instant start — the keyless blockrun.ai
/// free tier means the first message needs zero setup.
struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                switch step {
                case 0: welcome
                case 1: tour
                default: start
                }
            }
            .frame(maxWidth: 520)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(step)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? Theme.accent : Theme.controlStroke)
                        .frame(width: index == step ? 22 : 7, height: 7)
                }
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            VelaMark(size: 72)
            Text("Welcome to VelaChat")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("A fast, private, native chat app for every AI provider — local models included. Conversations never leave this Mac except to the provider you choose.")
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Continue") { step = 1 }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentStrong)
                .controlSize(.large)
                .padding(.top, 8)
        }
    }

    private var tour: some View {
        VStack(spacing: 16) {
            Text("Three things worth knowing")
                .font(.title2.weight(.semibold))
            tourCard(symbol: "keyboard", title: "Summon from anywhere") {
                AnyView(HStack {
                    Text("A global hotkey opens VelaChat over any app.")
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    KeyboardShortcuts.Recorder("", name: .summonVelaChat)
                })
            }
            tourCard(symbol: "text.cursor", title: "The / menu") {
                AnyView(Text("Type / in the composer for commands, saved snippets, and skills.")
                    .foregroundStyle(Theme.secondaryText))
            }
            tourCard(symbol: "globe", title: "Web search") {
                AnyView(Text("Toggle the globe in the composer and the model searches the live web, showing its work as quiet activity lines.")
                    .foregroundStyle(Theme.secondaryText))
            }
            Button("Continue") { step = 2 }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentStrong)
                .controlSize(.large)
                .padding(.top, 6)
        }
    }

    private func tourCard(symbol: String, title: String, @ViewBuilder content: () -> AnyView) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                content()
                    .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.controlBackground.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var start: some View {
        VStack(spacing: 18) {
            VelaMark(size: 52)
            Text("Ready when you are")
                .font(.title.weight(.semibold))
            Text("Start instantly on free models — no account, no key — or connect your own provider.")
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                if let blockrun = appModel.providers.profiles.first(where: { $0.kind == .blockrun }) {
                    appModel.providers.select(blockrun.id)
                }
                appModel.hasOnboarded = true
                appModel.section = .chat
            } label: {
                Label("Start chatting now", systemImage: "arrow.up.circle.fill")
                    .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentStrong)
            .controlSize(.large)
            Button("Connect your own provider") {
                appModel.hasOnboarded = true
                appModel.section = .settings
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
    }
}
