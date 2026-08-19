import SwiftUI
import AppKit

extension View {
    /// Liquid Glass is reserved for functional layers: the composer, compact
    /// controls, and the sidebar’s utility header. Older supported macOS
    /// versions receive a native material fallback.
    @ViewBuilder
    func nativeMaterial(cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
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

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                content
            }
        } else {
            content
        }
    }
}
