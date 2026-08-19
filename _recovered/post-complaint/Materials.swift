import SwiftUI
import AppKit

extension View {
    /// Liquid Glass is reserved for functional layers: the composer, compact
    /// controls, and the sidebar's utility header.
    func nativeMaterial(cornerRadius: CGFloat = 10) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// Tinted capsule chrome — composer pills, floating badges.
    func glassCapsule(tint: Color, isPressed: Bool = false, interactive: Bool = true) -> some View {
        glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: .capsule)
    }

    /// Tinted circular chrome — send/context/back/floating-chip buttons.
    func glassCircle(tint: Color, isPressed: Bool = false, interactive: Bool = true) -> some View {
        glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: .circle)
    }

    /// Neutral (untinted) floating chrome chips — exit-fullscreen, pinned
    /// messages, the conversation menu pill.
    func glassChip<S: Shape>(in shape: S) -> some View {
        glassEffect(.regular, in: shape)
    }

    /// A real vibrant `NSVisualEffectView` sidebar material (the same kind
    /// Finder/Mail/Notes use) tinted with the app's own background color,
    /// rather than a flat fill — the sidebar should pick up window/desktop
    /// vibrancy instead of sitting on a solid hex color.
    func sidebarMaterial(tint: Color) -> some View {
        background {
            ZStack {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                tint.opacity(0.55)
            }
            // Only the material extends up behind the traffic lights — the
            // content on top of it stays laid out within the real safe area,
            // so it self-corrects at any window size instead of needing a
            // hand-guessed compensating padding.
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}

private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct VelaGlassContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            content
        }
    }
}
