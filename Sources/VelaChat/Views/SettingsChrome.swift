import SwiftUI

/// The shared chrome every Settings screen is built from.
///
/// Before this existed the four Settings routes each invented their own
/// layout: the root used hand-rolled glass cards in a `ScrollView`, while
/// the provider editor, Statistics, and What's New used `Form` with
/// `.formStyle(.grouped)`. That is two different visual languages one back
/// button apart — grouped `Form` paints its own background at its own
/// width, which showed up as a large, slightly-lighter rectangle with a
/// hard seam floating off-centre in the pane. Everything routes through
/// `SettingsPage` + `SettingsPanel` now, so width, gutters, corner radius,
/// row rhythm, and label alignment are decided in exactly one place.

// MARK: - Page

/// One scrolling column, centred, at the app's single settings width.
struct SettingsPage<Content: View>: View {
    var horizontalPadding: CGFloat = 24
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.panelSpacing) {
                content()
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 20)
            .frame(maxWidth: SettingsMetrics.columnWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.automatic)
    }
}

enum SettingsMetrics {
    /// The readable column every settings screen shares. Narrower than the
    /// pane on purpose — long label/value rows stretched to a 1400pt window
    /// leave the value so far from its label the pairing stops reading.
    static let columnWidth = Theme.Layout.settingsColumn
    static let railWidth = Theme.Layout.settingsRail
    static let panelSpacing: CGFloat = 14
    /// Vertical rhythm inside a panel. One value, so a panel of toggles and
    /// a panel of label/value rows breathe identically.
    static let rowSpacing: CGFloat = 12
}

// MARK: - Panel

/// A titled card. `symbol` is drawn as a small tinted icon tile beside the
/// title — the same glyph the jump rail uses for that section, so the rail
/// and the card it scrolls to are recognisably the same thing.
struct SettingsPanel<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    var footer: Text? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            if let title {
                HStack(spacing: 9) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24, height: 24)
                            .background(
                                Theme.accent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                }
            }
            content()
                .toggleStyle(SettingsToggleStyle())
                // Note: macOS 26 ignores .tint() on switch tracks — the ON
                // state is conveyed by knob position, not colour. Verified
                // by pixel-sampling a tinted and an untinted switch: both
                // render the same rgb(76,84,85) track. Left as-is rather
                // than churning values that have no effect.
                .tint(Theme.accentStrong)
                .controlSize(.small)
                .labeledContentStyle(SettingsLabeledContentStyle())
                // Outside a `Form`, `.roundedBorder` is the default and its
                // focus ring is drawn by AppKit in system blue regardless of
                // `.tint()` (see Materials.swift). Every field in Settings
                // gets the app's own flat treatment instead.
                .textFieldStyle(.plain)
            if let footer {
                footer
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Liquid glass under a faint tint — large surfaces, so the small-
        // chip halo failure mode doesn't apply; theme colors unchanged.
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .glassChip(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous), emphasis: 0.5)
    }
}

// MARK: - Rows

/// Label left, value right, baseline-aligned — the alignment a grouped
/// `Form` gives for free and which the hand-rolled cards had been going
/// without, so "Message width" sat hard against its own popup while
/// "Density" sat somewhere else entirely.
struct SettingsLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .foregroundStyle(Theme.text)
            Spacer(minLength: 12)
            configuration.content
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 22)
    }
}

/// Switch on the trailing edge, label on the leading edge — the shape a
/// grouped `Form` gives a `Toggle` for free. Outside a Form, plain
/// `.toggleStyle(.switch)` packs the switch hard against the end of the
/// label text, so a column of toggles had its switches at six different x
/// positions.
struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .foregroundStyle(Theme.text)
            Spacer(minLength: 12)
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(minHeight: 22)
    }
}

/// A plain read-only label/value line. Exists so screens that only report
/// numbers (Statistics) don't each reinvent the same `HStack`.
struct SettingsValueRow<Value: View>: View {
    let title: String
    var tint: Color? = nil
    @ViewBuilder var value: () -> Value

    var body: some View {
        LabeledContent {
            value()
                .font(.body.weight(.medium))
                .foregroundStyle(tint ?? Theme.text)
        } label: {
            Text(title)
        }
    }
}

extension SettingsValueRow where Value == Text {
    init(_ title: String, _ text: String, tint: Color? = nil) {
        self.init(title: title, tint: tint) { Text(text) }
    }
}

/// Every "opens a sub-screen" row in Settings — Statistics, What's New, and
/// each provider — is the same shape: icon, title, trailing chevron, same
/// hover and press feedback. They used to be a mix of `NavigationLink`s and
/// plain `Label` buttons, which meant three different-looking affordances
/// for one identical action.
struct SettingsDisclosureRow: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 10)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .buttonStyle(SettingsRowButtonStyle())
    }
}

/// Hover + press feedback for a full-width Settings row. Without it the
/// provider rows (and the disclosure rows above) were the only clickable
/// things in the app with no pointer feedback at all — they read as static
/// text until you happened to click one.
struct SettingsRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                Theme.surfaceHigh.opacity(configuration.isPressed ? 0.9 : (isHovering ? 0.55 : 0)),
                in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The jump rail's rows had no hover state at all, which made a column of
/// eleven plain grey words look like a legend rather than a control.
struct JumpRailButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Theme.surfaceHigh.opacity(isHovering ? 0.45 : 0),
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - Buttons

/// Actions that erase something. `Button(role: .destructive)` alone does
/// nothing visible here: with `.buttonStyle(.plain)` (or inside these
/// cards) the role never reaches a style that draws it, so "Reset VelaChat
/// completely" rendered in the same friendly accent teal as "Add a
/// Snippet". Danger has to be visible before the confirmation sheet, not
/// only in it.
struct SettingsDestructiveButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.danger)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                Theme.danger.opacity(configuration.isPressed ? 0.26 : (isHovering ? 0.18 : 0.10)),
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                    .stroke(Theme.danger.opacity(0.35), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The one filled, committing action in a card — Save. `.glassProminent`
/// tinted with the accent rendered as a dark grey capsule against these
/// cards, which read as *disabled* sitting next to an enabled "Test
/// Connection". A flat accent fill matches the sidebar's New Chat button,
/// which is the app's existing primary-action look.
struct SettingsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.accentForeground)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(
                Theme.accentStrong.opacity(configuration.isPressed ? 0.8 : (isHovering ? 0.92 : 1)),
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The neutral "adds something" action inside a card — Add a Snippet, Add a
/// Skill Folder, Add a Server, Import from JSON. These were bare
/// `.buttonStyle(.plain)` labels tinted accent, so they had no hit area
/// beyond their glyphs and no press feedback.
struct SettingsAddButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.22 : (isHovering ? 0.14 : 0.08)),
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                    .stroke(Theme.accent.opacity(0.28), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// An empty-state line inside a card, so "nothing here yet" reads the same
/// in Skills, Snippets, MCP Servers, and Memory instead of four slightly
/// different grey labels.
struct SettingsEmptyState: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.surfaceMid.opacity(0.5),
            in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
        )
    }
}
