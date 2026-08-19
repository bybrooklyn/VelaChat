import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.hasOnboarded {
                mainInterface
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: appModel.hasOnboarded)
        .task { appModel.start() }
    }

    private var mainInterface: some View {
        @Bindable var appModel = appModel
        return NavigationSplitView(columnVisibility: $appModel.sidebarVisibility) {
            SidebarView()
                // The system toolbar (and its sidebar toggle) is gone — the
                // app's own toggle lives in the sidebar header instead, so
                // no toolbar band sits across the top of the window.
                .toolbar(removing: .sidebarToggle)
                // `ideal` is only a starting hint, not a live binding — there's
                // no public API for a NavigationSplitView column width binding,
                // so persistence works by reading back whatever width the
                // sidebar last reported to `velachat.sidebar-width` (see
                // SidebarView's own GeometryReader) and using that as next
                // launch's starting point instead of always resetting to 274.
                .navigationSplitViewColumnWidth(
                    min: appModel.isSidebarRail ? AppModel.sidebarRailWidth : 220,
                    ideal: appModel.isSidebarRail
                        ? AppModel.sidebarRailWidth
                        : (UserDefaults.standard.double(forKey: "velachat.sidebar-width").rounded() > 0
                            ? UserDefaults.standard.double(forKey: "velachat.sidebar-width")
                            : 274),
                    max: appModel.isSidebarRail ? AppModel.sidebarRailWidth : 420
                )
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // NavigationSplitView drives the window title from the detail
                // pane; blanking it here is what actually keeps AppKit from
                // redrawing "VelaChat" on top of the chat pane's own header.
                .navigationTitle("")
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.background)
        // Accent swatches used to visibly do nothing — Theme's statics
        // re-read UserDefaults but nothing forced a re-render. A full
        // rebuild on this rare, explicit action is the honest fix (known
        // cost: scroll position resets).
        .id(appModel.accentPreset)
        .sheet(isPresented: $appModel.isCommandPaletteShown) {
            CommandPaletteView(isPresented: $appModel.isCommandPaletteShown)
        }
    }

    /// A quiet crossfade between chat and Settings, instead of the panes
    /// swapping in one frame.
    @ViewBuilder
    private var detail: some View {
        ZStack {
            switch appModel.section {
            case .chat: ChatView().transition(.opacity)
            case .settings: SettingsView().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: appModel.section)
    }
}
