import Foundation
import VelaCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device Foundation Models: free, private, offline. Used two
/// ways — as the instant "utility brain" for titles/compaction/handoff
/// (with the provider path as fallback), and as a full chat provider
/// (`ProviderKind.appleIntelligence`). API verified against the macOS 26
/// SDK's own swiftinterface, not guessed.
@MainActor
enum AppleIntelligence {
    struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Human-readable availability — the ad-hoc-signed SwiftPM bundle may
    /// legitimately be ineligible at runtime; every caller degrades.
    static var unavailabilityReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings."
            case .modelNotReady: return "The on-device model is still downloading."
            @unknown default: return "Apple Intelligence is unavailable."
            }
        }
        #else
        return "This build doesn't include Apple Intelligence support."
        #endif
    }

    static var isAvailable: Bool { unavailabilityReason == nil }

    /// Conservative word budget for the on-device context window — utility
    /// callers with bigger transcripts stay on the provider path.
    static let contextBudgetWords = 3_000

    /// One-shot completion for the utility brain (titles, summaries).
    static func complete(prompt: String, instructions: String? = nil) async throws -> String {
        #if canImport(FoundationModels)
        guard isAvailable else { throw Unavailable(reason: unavailabilityReason ?? "Unavailable.") }
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
        #else
        throw Unavailable(reason: "This build doesn't include Apple Intelligence support.")
        #endif
    }

    /// Streaming chat for the provider path. System messages become session
    /// instructions; prior turns fold into one prompt (the framework's
    /// multi-turn Transcript type exists, but folded prompts are the
    /// simplest correct shape for our replay format). Snapshots are
    /// cumulative — converted to deltas by prefix diff.
    static func streamChat(messages: [ChatMessage], onDelta: @escaping @Sendable (String) -> Void) async throws {
        #if canImport(FoundationModels)
        guard isAvailable else { throw Unavailable(reason: unavailabilityReason ?? "Unavailable.") }
        let instructions = messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n\n")
        var promptLines: [String] = []
        for message in messages where message.role != "system" {
            let speaker = message.role == "assistant" ? "Assistant" : "User"
            promptLines.append("\(speaker): \(message.contentForRequest)")
        }
        promptLines.append("Assistant:")
        let session = LanguageModelSession(instructions: instructions.isEmpty ? nil : instructions)
        var previous = ""
        for try await snapshot in session.streamResponse(to: promptLines.joined(separator: "\n\n")) {
            let full = snapshot.content
            if full.hasPrefix(previous) {
                let delta = String(full.dropFirst(previous.count))
                if !delta.isEmpty { onDelta(delta) }
            } else {
                // The model revised earlier text — resend everything new.
                onDelta(full)
            }
            previous = full
        }
        #else
        throw Unavailable(reason: "This build doesn't include Apple Intelligence support.")
        #endif
    }
}
