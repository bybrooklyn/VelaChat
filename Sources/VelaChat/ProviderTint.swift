import SwiftUI
import VelaCore

extension ProviderKind {
    /// Brand color, used for the logo tile and any accenting.
    ///
    /// Stays app-side because `Color` is SwiftUI: `ProviderKind` itself is a
    /// plain `Sendable` enum in VelaCore, and giving it a SwiftUI-typed
    /// property there would pull the whole UI framework into the library for
    /// one presentation detail.
    var tint: Color {
        switch self {
        case .appleIntelligence: Color(hex: 0xE8E4F0)
        case .openAI, .codex, .chatGPT: Color(hex: 0x10A37F)
        case .anthropic, .claudeCode: Color(hex: 0xD97757)
        case .google: Color(hex: 0x4285F4)
        case .deepSeek: Color(hex: 0x4D6BFE)
        case .openRouter: Color(hex: 0x6467F2)
        case .groq: Color(hex: 0xF55036)
        case .mistral: Color(hex: 0xFA520F)
        case .xai: Color(hex: 0xE8E8E8)
        case .perplexity: Color(hex: 0x20B8CD)
        case .ollama: Color(hex: 0xC8C8C8)
        case .lmStudio: Color(hex: 0x7B5BF5)
        case .blockrun: Color(hex: 0x2ED47A)
        case .compatible: Color(hex: 0x5B9BD5)
        }
    }
}
