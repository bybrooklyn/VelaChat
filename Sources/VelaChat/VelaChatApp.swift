import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// ⌃⌥Space avoids the common ⌘Space (Spotlight) / ⌥Space (some IME
    /// switchers) conflicts. Changeable by the user in Settings regardless.
    static let summonVelaChat = Self("summonVelaChat", default: .init(.space, modifiers: [.control, .option]))
}

@main
struct VelaChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    init() {
        appDelegate.appModel = appModel
    }

    @State private var windowChrome = WindowChrome()
    @State private var artifactPresenter = ArtifactPresenter()

    static let mainWindowID = "vela.main"

    var body: some Scene {
        WindowGroup("VelaChat", id: Self.mainWindowID) {
            RootView()
                .environment(appModel)
                .environment(windowChrome)
                .environment(artifactPresenter)
                .tint(Theme.accent)
                .frame(minWidth: 960, minHeight: 620)
                .preferredColorScheme(.dark)
                .background(WindowConfigurator(chrome: windowChrome))
        }
        .defaultSize(width: 1_180, height: 780)
        // Without this the app can come up having created only the MenuBarExtra
        // scene, leaving a running process with no window at all — the
        // intermittent "app launches to nothing" this project kept hitting.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    _ = appModel.newConversation()
                    appModel.section = .chat
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("VelaChat") {
                Button("Stop Generating") {
                    appModel.stopGeneration()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!appModel.isGenerating)

                Button("Command Palette…") {
                    appModel.isCommandPaletteShown = true
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
            // Settings is an in-app destination now, not a separate window,
            // so ⌘, navigates the main window instead of opening a second
            // copy of the same screen in its own panel.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appModel.section = .settings
                    AppWindowRouter.raiseMainWindow()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }

        MenuBarExtra {
            QuickComposerView()
                .environment(appModel)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        } label: {
            // A subtle pulse while anything is generating in the
            // background — the one signal that closing the window didn't
            // mean losing track of an in-flight reply.
            Image(systemName: "sailboat.fill")
                .symbolEffect(.pulse, isActive: appModel.isAnyGenerating)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Live window chrome state, shared so views can react to fullscreen —
/// e.g. showing an exit-fullscreen control where traffic lights would
/// otherwise be. Layout correctness no longer depends on this: content
/// respects the real safe area instead of a guessed inset (see
/// `sidebarMaterial`, `chatTopBar`, and Settings' `header`).
@MainActor
@Observable
final class WindowChrome {
    var isFullScreen = false
}

/// Makes the titlebar transparent so the sidebar's material reads as one
/// continuous surface with the window chrome, like Finder/Mail/Notes, instead
/// of a flat opaque titlebar sitting on top of a separate sidebar. The title
/// *text* is blanked the SwiftUI-native way, via `.navigationTitle("")` on
/// `RootView`'s detail pane — not by touching `NSWindow.titleVisibility`
/// directly. An earlier version of this also hid `titleVisibility` and
/// re-asserted it on every `didUpdateNotification`, fighting
/// `NavigationSplitView`'s own toolbar/titlebar-merge logic on every layout
/// pass — that produced an empty reserved titlebar strip covering the
/// sidebar's brand row and made the traffic lights unreliable. Leaving
/// `titleVisibility` at its default `.visible` (with nothing to show) avoids
/// that fight entirely.
private struct WindowConfigurator: NSViewRepresentable {
    let chrome: WindowChrome

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            context.coordinator.observe(window: window, chrome: chrome)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var tokens: [NSObjectProtocol] = []

        @MainActor
        func observe(window: NSWindow, chrome: WindowChrome) {
            chrome.isFullScreen = window.styleMask.contains(.fullScreen)
            let center = NotificationCenter.default
            tokens.append(center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { chrome.isFullScreen = true }
            })
            tokens.append(center.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { chrome.isFullScreen = false }
            })
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Registering this in `App.init()` runs before SwiftUI has built the
        // WindowGroup's scene and reliably prevented the main window from
        // ever opening. Registering post-launch avoids that entirely.
        KeyboardShortcuts.onKeyUp(for: .summonVelaChat) {
            AppWindowRouter.raiseMainWindow()
        }
        // A prior "belt and braces" fallback here called `newWindowForTab` if
        // no window appeared within 1.5s. That call creates a raw AppKit
        // window that bypasses every SwiftUI scene modifier — none of
        // `WindowConfigurator`'s titlebar setup, no environment objects —
        // which produced a second, malformed window with a solid black
        // titlebar and no traffic lights whenever it fired. It's exactly the
        // kind of window that looked like "the app is broken." Removed:
        // `.defaultLaunchBehavior(.presented)` on the WindowGroup is the real,
        // SwiftUI-native fix for the original no-window-at-launch bug.
    }

    /// A summon-anywhere hotkey is worthless if closing the window quits the
    /// whole app — the menu-bar item and the `KeyboardShortcuts` listener it
    /// depends on would go down with it. The app now stays resident in the
    /// menu bar, exactly like every other summon-anywhere utility, until you
    /// actually quit it (⌘Q or the menu-bar item).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appModel, appModel.conversations.contains(where: { $0.isGenerating }) else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "A reply is still being generated"
        alert.informativeText = "Quitting now will stop it and the response may be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
