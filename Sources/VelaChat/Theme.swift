import SwiftUI
import AppKit

/// A curated accent hue, not a full theme — background/text/material stay
/// exactly as designed (see the note on `Theme.background` below for why a
/// real light appearance isn't offered here). Persisted; picked up on the
/// next natural view re-render rather than guaranteed instantly everywhere,
/// since `Theme.accent` reads it fresh each access rather than being wired
/// through a reactive binding every call site would need to adopt.
enum AccentPreset: String, CaseIterable, Identifiable, Codable {
    case teal, blue, purple, orange, pink, green

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .teal: "Teal"
        case .blue: "Blue"
        case .purple: "Purple"
        case .orange: "Orange"
        case .pink: "Pink"
        case .green: "Green"
        }
    }

    /// The one hand-picked number per preset — everything else (strong/soft/
    /// bubble variants) is derived from this mathematically, so adding a
    /// preset never means guessing a matching family of five more hex values.
    var baseHex: UInt32 {
        switch self {
        case .teal: 0x8DDECE
        case .blue: 0x7AA7F0
        case .purple: 0xB89CF0
        case .orange: 0xF0B26B
        case .pink: 0xF09CC7
        case .green: 0x9CD98A
        }
    }

    /// The original hand-tuned seafoam family. The derived variants below
    /// land close but visibly lighter and muddier than these — the whole
    /// app's feel was tuned against the hand-picked values, so the default
    /// preset uses the real ones and only the alternate hues pay the
    /// "derived" tax.
    var handTunedFamily: (strong: UInt32, soft: UInt32, bubble: UInt32, selection: UInt32, mark: UInt32)? {
        switch self {
        case .teal: (strong: 0x52B9A8, soft: 0x153A39, bubble: 0x245C5F, selection: 0x1B4140, mark: 0x173333)
        default: nil
        }
    }

    static var current: AccentPreset {
        get {
            UserDefaults.standard.string(forKey: DefaultsKey.accentPreset).flatMap(AccentPreset.init(rawValue:)) ?? .teal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKey.accentPreset)
        }
    }
}

/// How much room the transcript column gets — read by `ChatView` in place
/// of a fixed constant.
enum MessageWidthPreset: String, CaseIterable, Identifiable, Codable {
    case compact, comfortable, wide

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .wide: "Wide"
        }
    }
    var width: CGFloat {
        switch self {
        case .compact: 680
        case .comfortable: 880
        case .wide: 1_080
        }
    }
}

/// Vertical breathing room between messages and within each message's own
/// padding — read by `ChatView`/`MessageRow` in place of fixed constants.
enum DensityPreset: String, CaseIterable, Identifiable, Codable {
    case compact, comfortable, spacious

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .spacious: "Spacious"
        }
    }
    var messageSpacing: CGFloat {
        switch self {
        case .compact: 14
        case .comfortable: 24
        case .spacious: 34
        }
    }
    var bubblePadding: CGFloat {
        switch self {
        case .compact: 7
        case .comfortable: 10
        case .spacious: 13
        }
    }
}

enum Theme {
    // Vela's canvas is deliberately dark and slightly green-blue rather than
    // a stock black window. Liquid Glass reads best against a quiet backdrop.
    // Not offered in a light variant: most of this palette is hand-picked
    // hex, not the system's own dynamic colors, so a real light appearance
    // would mean redesigning the whole palette (not just flipping a switch)
    // — real risk of shipping illegible text-on-background pairings with no
    // way to visually verify it in this environment. `AccentPreset` above
    // is the safe subset of "themes" that's actually buildable here: it
    // only changes a hue, never a background a text color depends on.
    static let background = Color(hex: 0x0F1718)
    static let sidebarBackground = Color(hex: 0x142021)
    static var sidebarSelection: Color {
        AccentPreset.current.handTunedFamily.map { Color(hex: $0.selection) } ?? accent.blended(toward: background, amount: 0.72)
    }
    static let text = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    static let controlBackground = Color(hex: 0x182627)

    /// Three named surface levels instead of nine hand-picked opacities of
    /// `controlBackground`. Depth was being expressed as 0.3/0.35/0.4/
    /// 0.45/0.5/0.55/0.6/0.7/0.75 scattered across the views, which reads
    /// as noise rather than a system and makes any future appearance work
    /// (light mode) impossible to do consistently.
    ///
    /// - `surfaceLow`: large passive areas — cards, panels, disclosures.
    /// - `surfaceMid`: grouped content and hover states.
    /// - `surfaceHigh`: interactive controls — buttons, fields, chips.
    static let surfaceLow = controlBackground.opacity(0.4)
    static let surfaceMid = controlBackground.opacity(0.6)
    static let surfaceHigh = controlBackground.opacity(0.75)

    // The identity is nautical without turning the interface into a themed
    // dashboard: seafoam for action, horizon blue for model state, and coral
    // for a small amount of human warmth.
    static var accent: Color { Color(hex: AccentPreset.current.baseHex) }
    static var accentStrong: Color {
        AccentPreset.current.handTunedFamily.map { Color(hex: $0.strong) } ?? accent.darkened(by: 0.35)
    }
    static var accentSoft: Color {
        AccentPreset.current.handTunedFamily.map { Color(hex: $0.soft) } ?? accent.blended(toward: background, amount: 0.9)
    }
    static let modelAccent = Color(hex: 0x9CB7F7)
    static let reasoningAccent = Color(hex: 0xD8B0EC)
    static let coral = Color(hex: 0xF0A58D)
    static var markBackground: Color {
        AccentPreset.current.handTunedFamily.map { Color(hex: $0.mark) } ?? accent.blended(toward: background, amount: 0.82)
    }
    static var userBubble: Color {
        AccentPreset.current.handTunedFamily.map { Color(hex: $0.bubble) } ?? accent.blended(toward: background, amount: 0.52)
    }
    static let accentForeground = Color(hex: 0x071416)
    static let controlStroke = Color(hex: 0x2C4548)

    // Palette-tuned status colors — the raw NSColor.system* values are
    // full-saturation sRGB and read overexposed against this dark, muted
    // background; these sit in the same family as the rest of the theme.
    static let success = Color(hex: 0x7FCB8F)
    static let warning = Color(hex: 0xE0B36A)
    static let danger = Color(hex: 0xE08787)

    /// Shared layout constants — one source of truth instead of per-view
    /// magic numbers that drift (Settings was 760, Providers 720,
    /// Changelog/Statistics 640, all in one navigation stack).
    enum Layout {
        /// The readable column every Settings screen's content sits in.
        static let settingsColumn: CGFloat = 760
        /// The jump rail beside it. Reserved on every route, not just the
        /// root, so the content column never shifts sideways when you open
        /// a provider or Statistics.
        static let settingsRail: CGFloat = 164
        /// Rail + column: the whole Settings area, centred in the pane.
        static let settingsWidth: CGFloat = settingsRail + settingsColumn
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

    /// Blends this color a fraction of the way toward black — used to
    /// derive a "strong" variant of an accent preset instead of hand-picking
    /// a second hex per preset.
    func darkened(by amount: CGFloat) -> Color {
        guard let rgb = NSColor(self).usingColorSpace(.deviceRGB) else { return self }
        return Color(
            red: Double(rgb.redComponent * (1 - amount)),
            green: Double(rgb.greenComponent * (1 - amount)),
            blue: Double(rgb.blueComponent * (1 - amount))
        )
    }

    /// Blends this color a fraction of the way toward another — used to
    /// derive the soft/bubble/selection variants of an accent preset from
    /// its one base hex plus the app's fixed background.
    func blended(toward target: Color, amount: CGFloat) -> Color {
        guard let a = NSColor(self).usingColorSpace(.deviceRGB),
              let b = NSColor(target).usingColorSpace(.deviceRGB) else { return self }
        return Color(
            red: Double(a.redComponent + (b.redComponent - a.redComponent) * amount),
            green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * amount),
            blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * amount)
        )
    }
}
