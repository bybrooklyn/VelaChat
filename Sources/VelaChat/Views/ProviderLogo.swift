import SwiftUI

/// Real brand marks, drawn as vectors, on a brand-colored tile — the way
/// every other AI client presents providers. SF Symbols read as generic
/// system iconography and made every provider look interchangeable.
struct ProviderLogo: View {
    let kind: ProviderKind
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tileFill)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .overlay {
                glyph
                    .frame(width: size * 0.62, height: size * 0.62)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(kind.rawValue)
    }

    /// Dark tiles for brands whose mark is white-on-black; brand color
    /// otherwise. Keeps every tile legible against the app's dark canvas.
    private var tileFill: LinearGradient {
        let base: Color
        switch kind {
        case .openAI, .codex: base = Color(hex: 0x0D0D0D)
        case .xai: base = Color(hex: 0x0D0D0D)
        case .ollama: base = Color(hex: 0x101010)
        case .perplexity: base = Color(hex: 0x0F3B44)
        default: base = kind.tint
        }
        return LinearGradient(
            colors: [base.opacity(0.98), base.opacity(0.80)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var glyphColor: Color { .white }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .appleIntelligence:
            Image(systemName: "apple.logo")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(glyphColor)
        case .openAI, .codex, .chatGPT: OpenAIKnot().fill(glyphColor)
        case .anthropic: AnthropicBurst().fill(glyphColor)
        case .google: GeminiSpark().fill(glyphColor)
        case .deepSeek: DeepSeekWhale().fill(glyphColor)
        case .openRouter: OpenRouterMark().fill(glyphColor)
        case .groq: GroqBolt().fill(glyphColor)
        case .mistral: MistralBars()
        case .xai: XAIMark().fill(glyphColor)
        case .perplexity: PerplexityMark().stroke(glyphColor, style: .init(lineWidth: 1.6, lineCap: .round))
        case .ollama: OllamaLlama().fill(glyphColor)
        case .lmStudio: LMStudioMark().fill(glyphColor)
        case .blockrun: BlockRunMark().fill(glyphColor)
        case .compatible: ServerMark().fill(glyphColor)
        }
    }
}

// MARK: - Marks

/// OpenAI's six-fold rotationally symmetric knot, built from six copies of a
/// single tapered petal rotated at 60° intervals.
private struct OpenAIKnot: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<6 {
            let angle = Angle.degrees(Double(index) * 60)
            var petal = Path()
            petal.move(to: CGPoint(x: c.x, y: c.y - r * 0.16))
            petal.addCurve(
                to: CGPoint(x: c.x + r * 0.86, y: c.y - r * 0.44),
                control1: CGPoint(x: c.x + r * 0.34, y: c.y - r * 0.16),
                control2: CGPoint(x: c.x + r * 0.70, y: c.y - r * 0.28)
            )
            petal.addCurve(
                to: CGPoint(x: c.x + r * 0.52, y: c.y - r * 0.86),
                control1: CGPoint(x: c.x + r * 1.00, y: c.y - r * 0.62),
                control2: CGPoint(x: c.x + r * 0.82, y: c.y - r * 0.86)
            )
            petal.addCurve(
                to: CGPoint(x: c.x, y: c.y - r * 0.42),
                control1: CGPoint(x: c.x + r * 0.28, y: c.y - r * 0.86),
                control2: CGPoint(x: c.x + r * 0.06, y: c.y - r * 0.66)
            )
            petal.closeSubpath()
            path.addPath(petal.applying(
                CGAffineTransform(translationX: c.x, y: c.y)
                    .rotated(by: angle.radians)
                    .translatedBy(x: -c.x, y: -c.y)
            ))
        }
        return path
    }
}

/// Claude's radiating burst: tapered spokes around a common center.
private struct AnthropicBurst: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            var spoke = Path()
            spoke.move(to: CGPoint(x: c.x - r * 0.10, y: c.y))
            spoke.addLine(to: CGPoint(x: c.x - r * 0.045, y: c.y - r))
            spoke.addLine(to: CGPoint(x: c.x + r * 0.045, y: c.y - r))
            spoke.addLine(to: CGPoint(x: c.x + r * 0.10, y: c.y))
            spoke.closeSubpath()
            path.addPath(spoke.applying(
                CGAffineTransform(translationX: c.x, y: c.y)
                    .rotated(by: angle)
                    .translatedBy(x: -c.x, y: -c.y)
            ))
        }
        return path
    }
}

/// Gemini's four-point star — straight-line points with concave sides.
private struct GeminiSpark: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
        path.closeSubpath()
        return path
    }
}

/// DeepSeek's whale, simplified to its recognizable diving silhouette.
private struct DeepSeekWhale: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + w * 0.03, y: rect.minY + h * 0.58))
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.62, y: rect.minY + h * 0.30),
            control1: CGPoint(x: rect.minX + w * 0.16, y: rect.minY + h * 0.30),
            control2: CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.22)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.97, y: rect.minY + h * 0.20),
            control1: CGPoint(x: rect.minX + w * 0.78, y: rect.minY + h * 0.36),
            control2: CGPoint(x: rect.minX + w * 0.88, y: rect.minY + h * 0.28)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.66, y: rect.minY + h * 0.66),
            control1: CGPoint(x: rect.minX + w * 0.94, y: rect.minY + h * 0.46),
            control2: CGPoint(x: rect.minX + w * 0.84, y: rect.minY + h * 0.60)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.03, y: rect.minY + h * 0.58),
            control1: CGPoint(x: rect.minX + w * 0.42, y: rect.minY + h * 0.76),
            control2: CGPoint(x: rect.minX + w * 0.18, y: rect.minY + h * 0.74)
        )
        path.closeSubpath()
        // Tail fluke.
        path.move(to: CGPoint(x: rect.minX + w * 0.06, y: rect.minY + h * 0.62))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.00, y: rect.minY + h * 0.92))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.34, y: rect.minY + h * 0.72))
        path.closeSubpath()
        return path
    }
}

/// OpenRouter's routing mark: one input fanning out to several outputs.
private struct OpenRouterMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        let bar = h * 0.11
        // Trunk.
        path.addRoundedRect(
            in: CGRect(x: rect.minX, y: rect.midY - bar / 2, width: w * 0.46, height: bar),
            cornerSize: CGSize(width: bar / 2, height: bar / 2)
        )
        // Three branches.
        for offset in [-0.34, 0.0, 0.34] as [CGFloat] {
            var branch = Path()
            branch.move(to: CGPoint(x: rect.minX + w * 0.40, y: rect.midY))
            branch.addLine(to: CGPoint(x: rect.maxX - w * 0.12, y: rect.midY + h * offset))
            path.addPath(branch.strokedPath(.init(lineWidth: bar, lineCap: .round, lineJoin: .round)))
            path.addEllipse(in: CGRect(
                x: rect.maxX - w * 0.20,
                y: rect.midY + h * offset - bar,
                width: bar * 2,
                height: bar * 2
            ))
        }
        return path
    }
}

private struct GroqBolt: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + w * 0.58, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.16, y: rect.minY + h * 0.56))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.46, y: rect.minY + h * 0.56))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.84, y: rect.minY + h * 0.42))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.52, y: rect.minY + h * 0.42))
        path.closeSubpath()
        return path
    }
}

/// Mistral's stacked bars, in its yellow→red gradient.
private struct MistralBars: View {
    private let colors = [
        Color(hex: 0xFFD800),
        Color(hex: 0xFFAF00),
        Color(hex: 0xFF8205),
        Color(hex: 0xFA500F),
        Color(hex: 0xE10500),
    ]

    var body: some View {
        GeometryReader { geo in
            let barHeight = geo.size.height / 5
            VStack(spacing: 0) {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    Rectangle()
                        .fill(color)
                        .frame(height: barHeight)
                        .padding(.leading, index == 0 ? geo.size.width * 0.2 : 0)
                }
            }
        }
    }
}

private struct XAIMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let t = w * 0.17
        var path = Path()
        var stroke = Path()
        stroke.move(to: CGPoint(x: rect.minX + w * 0.08, y: rect.minY + h * 0.06))
        stroke.addLine(to: CGPoint(x: rect.maxX - w * 0.08, y: rect.maxY - h * 0.06))
        stroke.move(to: CGPoint(x: rect.maxX - w * 0.08, y: rect.minY + h * 0.06))
        stroke.addLine(to: CGPoint(x: rect.minX + w * 0.08, y: rect.maxY - h * 0.06))
        path.addPath(stroke.strokedPath(.init(lineWidth: t, lineCap: .butt)))
        return path
    }
}

/// Perplexity's concentric split-ring mark.
private struct PerplexityMark: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addLine(to: CGPoint(x: c.x, y: c.y + r))
        path.addArc(center: CGPoint(x: c.x - r * 0.5, y: c.y - r * 0.18), radius: r * 0.62,
                    startAngle: .degrees(-40), endAngle: .degrees(220), clockwise: false)
        path.move(to: CGPoint(x: c.x, y: c.y - r * 0.2))
        path.addArc(center: CGPoint(x: c.x + r * 0.5, y: c.y - r * 0.18), radius: r * 0.62,
                    startAngle: .degrees(220), endAngle: .degrees(-40), clockwise: true)
        return path
    }
}

/// Ollama's llama, reduced to head, ears and neck.
private struct OllamaLlama: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        // Ears.
        path.addEllipse(in: CGRect(x: rect.minX + w * 0.16, y: rect.minY, width: w * 0.18, height: h * 0.34))
        path.addEllipse(in: CGRect(x: rect.minX + w * 0.66, y: rect.minY, width: w * 0.18, height: h * 0.34))
        // Head + neck.
        path.move(to: CGPoint(x: rect.minX + w * 0.24, y: rect.minY + h * 0.46))
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.76, y: rect.minY + h * 0.46),
            control1: CGPoint(x: rect.minX + w * 0.28, y: rect.minY + h * 0.22),
            control2: CGPoint(x: rect.minX + w * 0.72, y: rect.minY + h * 0.22)
        )
        path.addLine(to: CGPoint(x: rect.minX + w * 0.70, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.30, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct LMStudioMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: rect.minX, y: rect.minY + h * 0.10, width: w, height: h * 0.66),
            cornerSize: CGSize(width: w * 0.12, height: w * 0.12)
        )
        path.addRoundedRect(
            in: CGRect(x: rect.minX + w * 0.24, y: rect.maxY - h * 0.14, width: w * 0.52, height: h * 0.12),
            cornerSize: CGSize(width: w * 0.05, height: w * 0.05)
        )
        return path
    }
}

private struct ServerMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        for row in 0..<3 {
            let y = rect.minY + CGFloat(row) * h * 0.36
            path.addRoundedRect(
                in: CGRect(x: rect.minX, y: y, width: w, height: h * 0.26),
                cornerSize: CGSize(width: w * 0.08, height: w * 0.08)
            )
        }
        return path
    }
}

/// A simple 2x2 block grid — literal to the "block" in blockrun.ai, and
/// visually distinct from `ServerMark`'s three stacked horizontal bars.
private struct BlockRunMark: Shape {
    func path(in rect: CGRect) -> Path {
        let gap = rect.width * 0.16
        let side = (rect.width - gap) / 2
        var path = Path()
        for row in 0..<2 {
            for col in 0..<2 {
                let x = rect.minX + CGFloat(col) * (side + gap)
                let y = rect.minY + CGFloat(row) * (side + gap)
                path.addRoundedRect(
                    in: CGRect(x: x, y: y, width: side, height: side),
                    cornerSize: CGSize(width: side * 0.28, height: side * 0.28)
                )
            }
        }
        return path
    }
}

private struct SparkleMark: Shape {
    func path(in rect: CGRect) -> Path {
        GeminiSpark().path(in: rect)
    }
}
