import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        NavigationSplitView {
            SidebarView()
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

    @ViewBuilder
    private var detail: some View {
        switch appModel.section {
        case .chat: ChatView()
        case .settings: SettingsView()
        }
    }
}
