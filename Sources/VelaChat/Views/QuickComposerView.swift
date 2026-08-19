import SwiftUI
import AppKit

/// The menu-bar popover: a single-line composer that sends to the current
/// active conversation without needing to switch to the main window first.
struct QuickComposerView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VelaMark(size: 20)
                Text("Quick message")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if let provider = appModel.selectedProvider {
                    Text(provider.name)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }

            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(8)
                .background(Theme.controlBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
                .focused($focused)
                .onSubmit(send)

            HStack {
                Button("Open VelaChat") {
                    openMainWindow()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .font(.caption)

                Spacer()

                Button("Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentStrong)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appModel.isGenerating)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            focused = true
            // The menu-bar extra's content is the one SwiftUI view guaranteed
            // to exist for the whole app lifetime, so it's the bridge point
            // for handing `openWindow` to `AppWindowRouter` — a plain enum
            // with no `@Environment` access of its own, called from the
            // global-hotkey handler and here, both outside the normal view
            // hierarchy.
            AppWindowRouter.openMainWindow = { openWindow(id: VelaChatApp.mainWindowID) }
        }
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appModel.send(text)
        text = ""
        openMainWindow()
    }

    private func openMainWindow() {
        AppWindowRouter.raiseMainWindow()
    }
}

/// Raises VelaChat's single main window from contexts outside the normal
/// SwiftUI view hierarchy (the global hotkey handler, the menu-bar popover).
enum AppWindowRouter {
    /// The app's real document window, identified structurally rather than by
    /// title. Matching on `title == "VelaChat"` broke the moment the title was
    /// blanked to keep AppKit from drawing it over the chat header, and it was
    /// never reliable anyway — the menu-bar extra and panels have titles too.
    static var mainWindow: NSWindow? {
        NSApp.windows.first { window in
            window.styleMask.contains(.titled)
                && !window.isKind(of: NSPanel.self)
                && window.contentView != nil
                && window.frame.height > 200
        }
    }

    /// Set once by `QuickComposerView` on appear — the fallback for when the
    /// WindowGroup's single window was actually closed (not just
    /// backgrounded), which `mainWindow` alone has no way to bring back.
    static var openMainWindow: (() -> Void)?

    static func raiseMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}
