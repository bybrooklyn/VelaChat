import Foundation
import Observation

/// Keeps the memory index in step with the conversation history.
///
/// New messages are indexed as they finish; old conversations backfill
/// slowly in the background. Both paths are deliberately unhurried —
/// indexing must never compete with a live reply, and an index that is a
/// few seconds behind is invisible, while a stuttering transcript is not.
@MainActor
@Observable
public final class MemoryIndexer {
    /// Progress for the Settings screen, so a long backfill is visible
    /// rather than mysterious background CPU.
    public private(set) var isBackfilling = false
    public private(set) var backfilled = 0
    public private(set) var backfillTotal = 0
    public private(set) var indexedMessages = 0

    private let store: MemoryStore
    private var backfillTask: Task<Void, Never>?

    public init(store: MemoryStore = .shared) {
        self.store = store
    }

    /// Indexes one finished exchange. Called when a reply completes, not
    /// per token.
    public func indexFinished(conversation: Conversation, assistantID: UUID) {
        let messages = conversation.messages
            .filter { !$0.isSynthetic && !$0.content.isEmpty }
            .suffix(2)
            .map { (id: $0.id, role: $0.role, text: $0.contentForRequest, createdAt: $0.createdAt) }
        let conversationID = conversation.id
        Task { [store] in
            for message in messages {
                await store.index(
                    messageID: message.id,
                    conversationID: conversationID,
                    role: message.role,
                    text: message.text,
                    createdAt: message.createdAt
                )
            }
            let total = await store.indexedMessageCount()
            await MainActor.run { self.indexedMessages = total }
        }
    }

    /// Walks existing history newest-first, so recent conversations become
    /// searchable within seconds and older ones fill in behind them.
    /// Resumable: anything already indexed is skipped, so an interrupted
    /// pass costs nothing on the next launch.
    public func startBackfill(conversations: [Conversation]) {
        guard backfillTask == nil else { return }
        let work = conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .flatMap { conversation in
                conversation.messages
                    .filter { !$0.isSynthetic && !$0.content.isEmpty }
                    .map { (conversationID: conversation.id, id: $0.id, role: $0.role, text: $0.contentForRequest, createdAt: $0.createdAt) }
            }
        guard !work.isEmpty else { return }
        isBackfilling = true
        backfilled = 0
        backfillTotal = work.count
        backfillTask = Task { [store] in
            for message in work {
                if Task.isCancelled { break }
                if await store.isIndexed(messageID: message.id) {
                    await MainActor.run { self.backfilled += 1 }
                    continue
                }
                await store.index(
                    messageID: message.id,
                    conversationID: message.conversationID,
                    role: message.role,
                    text: message.text,
                    createdAt: message.createdAt
                )
                await MainActor.run { self.backfilled += 1 }
                // Yield generously: this is background work behind a live
                // interface, and embedding a message is not free.
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            let total = await store.indexedMessageCount()
            await MainActor.run {
                self.indexedMessages = total
                self.isBackfilling = false
                self.backfillTask = nil
            }
        }
    }

    public func cancelBackfill() {
        backfillTask?.cancel()
        backfillTask = nil
        isBackfilling = false
    }

    public func forget(conversationID: UUID) {
        Task { [store] in
            await store.forgetConversation(conversationID)
            let total = await store.indexedMessageCount()
            await MainActor.run { self.indexedMessages = total }
        }
    }

    public func refreshCount() {
        Task { [store] in
            let total = await store.indexedMessageCount()
            await MainActor.run { self.indexedMessages = total }
        }
    }
}

/// One thing that informed a reply, kept alongside the message so the
/// user can see what was recalled and correct it.
public struct MemoryRecall: Identifiable, Equatable, Sendable {

    public init(origin: Origin, text: String) {
        self.origin = origin
        self.text = text
    }
    public enum Origin: Equatable, Sendable {
        case fact(UUID)
        case conversation(id: UUID, messageID: UUID)
    }
    public var id: String {
        switch origin {
        case .fact(let factID): "fact:\(factID)"
        case .conversation(_, let messageID): "chat:\(messageID)"
        }
    }
    public let origin: Origin
    public let text: String

    public var isFact: Bool {
        if case .fact = origin { return true }
        return false
    }
}
