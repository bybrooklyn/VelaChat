import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        NavigationSplitView {
            SidebarView()
                // `ideal` is only a starting hint, not a live binding — there's
                // no public API for a NavigationSplitView column width binding,
                // so persistence works by reading back whatever width the
                // sidebar last reported to `velachat.sidebar-width` (see
                // SidebarView's own GeometryReader) and using that as next
                // launch's starting point instead of always resetting to 274.
                .navigationSplitViewColumnWidth(
                    min: 220,
                    ideal: UserDefaults.standard.double(forKey: "velachat.sidebar-width").rounded() > 0
                        ? UserDefaults.standard.double(forKey: "velachat.sidebar-width")
                        : 274,
                    max: 420
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
        .task { appModel.start() }
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
