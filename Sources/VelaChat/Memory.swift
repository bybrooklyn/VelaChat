import Foundation

/// A durable fact that persists across every conversation, not just the one
/// it was learned in. Global rather than per-conversation, on purpose: the
/// whole point is that it follows you everywhere. Written and maintained by
/// the model itself through the memory tools (`save_memory` /
/// `search_memory` / `edit_memory`) — Settings is the user's control
/// surface to see, edit, and delete everything stored. On-device only.
struct MemoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var content: String
    var createdAt: Date
    /// Project/topic grouping — supplied by the model when saving, editable
    /// by the user in Settings. `nil` groups under "General" (and on every
    /// memory saved before this field existed).
    var topic: String?

    init(id: UUID = UUID(), content: String, createdAt: Date = Date(), topic: String? = nil) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.topic = topic
    }

    var displayTopic: String {
        let trimmed = topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "General" : trimmed
    }
}
