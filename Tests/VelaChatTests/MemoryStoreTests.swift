import XCTest
@testable import VelaChat

/// Memory is an enhancement, so the contract these pin is as much about
/// failing quietly as about recalling correctly.
final class MemoryStoreTests: XCTestCase {
    /// Never the user's real database — each test gets a throwaway file.
    private func makeStore() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-memory-test-\(UUID().uuidString).sqlite")
        return MemoryStore(databaseURL: url)
    }

    func testVectorEncodingRoundTrips() {
        let vector: [Float] = [0.5, -0.25, 0.125, 1.0]
        let decoded = MemoryStore.decode(MemoryStore.encode(vector))
        XCTAssertEqual(decoded, vector)
    }

    func testCosineSimilarityBounds() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0, 0]
        let c: [Float] = [0, 1, 0]
        let d: [Float] = [-1, 0, 0]
        XCTAssertEqual(MemoryStore.cosine(a, b), 1.0, accuracy: 0.0001)
        XCTAssertEqual(MemoryStore.cosine(a, c), 0.0, accuracy: 0.0001)
        XCTAssertEqual(MemoryStore.cosine(a, d), -1.0, accuracy: 0.0001)
    }

    /// Mismatched or empty vectors must score zero rather than crashing on
    /// an index out of range — a corrupted blob shouldn't take the app down.
    func testCosineHandlesBadInput() {
        XCTAssertEqual(MemoryStore.cosine([1, 0], [1, 0, 0]), 0)
        XCTAssertEqual(MemoryStore.cosine([], []), 0)
        XCTAssertEqual(MemoryStore.cosine([0, 0], [0, 0]), 0)
    }

    func testEmbedderProducesNormalisedVectors() {
        guard let vector = MemoryEmbedder.shared.vector(for: "The user prefers concise answers and works in Swift.") else {
            throw XCTSkip("No on-device embedding assets on this runner.")
        }
        XCTAssertEqual(vector.count, 512)
        let magnitude = vector.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        XCTAssertEqual(magnitude, 1.0, accuracy: 0.001, "vectors must be unit length for cosine ranking")
    }

    func testEmbedderIgnoresEmptyText() {
        XCTAssertNil(MemoryEmbedder.shared.vector(for: "   "))
    }

    func testSearchTermsDropNoiseWords() {
        let terms = MemoryStore.searchTerms("What did we decide about the retrieval layer?")
        XCTAssertTrue(terms.contains("retrieval"))
        XCTAssertTrue(terms.contains("decide"))
        // Question words match every message ever written.
        XCTAssertFalse(terms.contains("what"))
        XCTAssertFalse(terms.contains("the"))
        XCTAssertFalse(terms.contains("about"))
    }

    /// Nonsense must retrieve nothing. This is the case that killed
    /// embedding-first retrieval: on-device vectors scored an unrelated
    /// note higher for gibberish than the correct note scored for a real
    /// question, so keywords now decide what counts as a candidate.
    func testNonsenseQueryRecallsNothing() async {
        let store = makeStore()
        let conversation = UUID()
        await store.index(
            messageID: UUID(), conversationID: conversation, role: "user",
            text: "Pizza dough needs to rest for at least an hour before shaping, otherwise it tears.",
            createdAt: Date()
        )
        let hits = await store.recall(query: "zzzqqq unrelated gibberish xyzzy", excluding: UUID())
        XCTAssertTrue(hits.isEmpty)
        await store.forgetConversation(conversation)
    }

    func testFactLifecycle() async {
        let store = makeStore()
        let id = await store.saveFact(content: "Brooklyn prefers teal accents.", topic: "Preferences", sourceConversationID: nil)
        XCTAssertNotNil(id)
        var facts = await store.allFacts()
        XCTAssertTrue(facts.contains { $0.content.contains("teal") })

        if let id {
            await store.updateFact(id: id, content: "Brooklyn prefers teal accents in dark mode.", topic: nil)
            facts = await store.allFacts()
            XCTAssertTrue(facts.contains { $0.content.contains("dark mode") })
            await store.deleteFact(id: id)
            facts = await store.allFacts()
            XCTAssertFalse(facts.contains { $0.id == id })
        }
    }

    func testShortMessagesAreNotIndexed() async {
        let store = makeStore()
        let messageID = UUID()
        await store.index(messageID: messageID, conversationID: UUID(), role: "user", text: "ok thanks", createdAt: Date())
        let indexed = await store.isIndexed(messageID: messageID)
        XCTAssertFalse(indexed, "trivial messages would crowd out real matches")
    }

    func testIndexingIsIdempotent() async {
        let store = makeStore()
        let messageID = UUID()
        let conversationID = UUID()
        let body = "We agreed the retrieval layer should use hybrid search: embeddings plus FTS5 keyword matching."
        await store.index(messageID: messageID, conversationID: conversationID, role: "assistant", text: body, createdAt: Date())
        let first = await store.indexedMessageCount()
        await store.index(messageID: messageID, conversationID: conversationID, role: "assistant", text: body, createdAt: Date())
        let second = await store.indexedMessageCount()
        XCTAssertEqual(first, second, "re-running the backfill must not duplicate chunks")
        await store.forgetConversation(conversationID)
    }

    func testRecallFindsAnOldConversation() async throws {
        let store = makeStore()
        let oldConversation = UUID()
        let current = UUID()
        await store.index(
            messageID: UUID(), conversationID: oldConversation, role: "user",
            text: "My deployment key for the staging cluster lives in the ops vault under project-atlas.",
            createdAt: Date()
        )
        defer { Task { await store.forgetConversation(oldConversation) } }

        let hits = await store.recall(query: "where is the staging deployment key", excluding: current)
        XCTAssertFalse(hits.isEmpty, "keyword recall should find this")
        XCTAssertTrue(hits.contains { $0.text.contains("project-atlas") })

        // The conversation being excluded must never come back.
        let excluded = await store.recall(query: "staging deployment key", excluding: oldConversation)
        XCTAssertFalse(excluded.contains { $0.text.contains("project-atlas") })
    }

    func testRecallOnEmptyQueryReturnsNothing() async {
        let store = makeStore()
        let hits = await store.recall(query: "   ")
        XCTAssertTrue(hits.isEmpty)
    }
}
