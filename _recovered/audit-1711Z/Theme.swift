import SwiftUI
import AppKit

enum Theme {
    // Vela’s canvas is deliberately dark and slightly green-blue rather than
    // a stock black window. Liquid Glass reads best against a quiet backdrop.
    static let background = Color(hex: 0x0F1718)
    static let sidebarBackground = Color(hex: 0x142021)
    static let sidebarSelection = Color(hex: 0x1B4140)
    static let surface = Color(hex: 0x1A292A)
    static let surfaceRaised = Color(hex: 0x203132)
    static let text = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    static let controlBackground = Color(hex: 0x182627)
    static let selectedBackground = Color(hex: 0x245B59)

    // The identity is nautical without turning the interface into a themed
    // dashboard: seafoam for action, horizon blue for model state, and coral
    // for a small amount of human warmth.
    static let accent = Color(hex: 0x8DDECE)
    static let accentStrong = Color(hex: 0x52B9A8)
    static let accentSoft = Color(hex: 0x153A39)
    static let modelAccent = Color(hex: 0x9CB7F7)
    static let reasoningAccent = Color(hex: 0xD8B0EC)
    static let coral = Color(hex: 0xF0A58D)
    static let markBackground = Color(hex: 0x173333)
    static let userBubble = Color(hex: 0x245C5F)
    static let accentForeground = Color(hex: 0x071416)
    static let controlStroke = Color(hex: 0x2C4548)

    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    static func title(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .semibold)
    }

    /// A single shared corner-radius scale so rounding reads as one system
    /// instead of ad hoc per-view values.
    enum Radius {
        static let compact: CGFloat = 8    // palette/menu rows
        static let row: CGFloat = 9        // sidebar navigation & conversation rows
        static let card: CGFloat = 12      // footer, small cards
        static let bubble: CGFloat = 14    // message bubbles
        static let composer: CGFloat = 26  // composer glass panel — heavy, near-pill rounding
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension View {
    func nativePageBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }

    func adaptiveText() -> some View {
        foregroundStyle(Theme.text)
    }
}
