import SwiftUI

// Vendored patch: the `@Entry` macro requires Xcode's SwiftUIMacros plugin,
// which isn't available under Command Line Tools-only toolchains. Use the
// classic EnvironmentKey pattern instead — functionally identical.
private struct HighlightEnvironmentKey: EnvironmentKey {
    static let defaultValue = Highlight()
}

extension EnvironmentValues {
    var highlight: Highlight {
        get { self[HighlightEnvironmentKey.self] }
        set { self[HighlightEnvironmentKey.self] = newValue }
    }
}
