import SwiftUI

@available(iOS 16.1, tvOS 16.1, *)
extension CodeText: View {
    public var body: some View {
        Text(attributedText)
            .fontDesign(.monospaced)
            .padding(.vertical, style.verticalPadding)
            .padding(.horizontal, style.horizontalPadding)
            .background {
                if let cardStyle = style as? CardCodeTextStyle {
                    CodeTextCardView(
                        style: cardStyle,
                        color: highlightResult?.backgroundColor
                    )
                }
            }
            .onAppear {
                guard highlightResult == nil else {
                    return
                }
                highlightTask = Task {
                    await highlightText()
                }
            }
            .onDisappear {
                highlightTask?.cancel()
            }
            .onChange(of: mode) { newMode in
                highlightTask?.cancel()
                highlightTask = Task {
                    await highlightText(mode: newMode)
                }
            }
            .onChange(of: colors) { newColors in
                highlightTask?.cancel()
                highlightTask = Task {
                    await highlightText(colors: newColors)
                }
            }
            .onChange(of: colorScheme) { newColorScheme in
                highlightTask?.cancel()
                highlightTask = Task {
                    await highlightText(colorScheme: newColorScheme)
                }
            }
    }
}

// Preview code removed from the vendored copy — #Preview requires Xcode's
// PreviewsMacros plugin, unavailable under Command Line Tools-only builds.
