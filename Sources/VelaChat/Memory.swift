import Foundation

/// A durable fact that persists across every conversation, not just the one
/// it was learned in — included in every request's context the same way
/// custom instructions already are. Global rather than per-conversation, on
/// purpose: the whole point is that it follows you everywhere.
struct MemoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var content: String
    var createdAt: Date

    init(id: UUID = UUID(), content: String, createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
    }
}

/// The model proposes a memory instead of VelaChat guessing when something
/// is worth remembering — same fenced-block convention as
/// `AskUserQuestionPayload`, taught via `AppModel.memoryInstruction`, so it
/// works over plain chat completions without real function calling. You
/// see and confirm every proposal before anything is actually stored.
struct MemoryProposal: Decodable, Equatable {
    let content: String

    /// Unlike `AskUserQuestionPayload.parse`, the block can sit anywhere in
    /// a normal reply (the instruction explicitly asks for that) — so both
    /// the text before and after it are kept, not just a prefix.
    static func parse(from text: String) -> (prefix: String, proposal: MemoryProposal, suffix: String)? {
        guard let openRange = text.range(of: "```remember"),
              let closeRange = text.range(of: "```", range: openRange.upperBound..<text.endIndex) else {
            return nil
        }
        let jsonText = text[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let proposal = try? JSONDecoder().decode(MemoryProposal.self, from: data),
              !proposal.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let prefix = String(text[text.startIndex..<openRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(text[closeRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (prefix, proposal, suffix)
    }
}
