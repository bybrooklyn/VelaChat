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

    /// Keyword candidacy is what makes recall trustworthy: a query with
    /// no meaningful terms in common with anything stored must return
    /// nothing, however "similar" an embedding might claim two unrelated
    /// sentences are.
    func testUnrelatedQueryDoesNotDragInNoise() async {
        let store = makeStore()
        let conversation = UUID()
        await store.index(
            messageID: UUID(), conversationID: conversation, role: "user",
            text: "Pizza dough needs to rest for at least an hour before shaping, otherwise it tears.",
            createdAt: Date()
        )
        await store.index(
            messageID: UUID(), conversationID: conversation, role: "assistant",
            text: "The staging deployment key for project-atlas lives in the ops vault, not in the repo.",
            createdAt: Date()
        )
        let hits = await store.recall(query: "where is the deployment key", excluding: UUID())
        XCTAssertTrue(hits.contains { $0.text.contains("project-atlas") })
        XCTAssertFalse(hits.contains { $0.text.contains("Pizza") })
        await store.forgetConversation(conversation)
    }

    /// "Don't use this again" has to actually stop it coming back.
    func testForgetMessageRemovesItFromRecall() async {
        let store = makeStore()
        let conversation = UUID()
        let messageID = UUID()
        await store.index(
            messageID: messageID, conversationID: conversation, role: "user",
            text: "My preferred deployment target is the staging cluster called project-atlas.",
            createdAt: Date()
        )
        var hits = await store.recall(query: "project-atlas deployment", excluding: UUID())
        XCTAssertFalse(hits.isEmpty)
        await store.forgetMessage(messageID)
        hits = await store.recall(query: "project-atlas deployment", excluding: UUID())
        XCTAssertTrue(hits.isEmpty)
    }

    func testRecallOnEmptyQueryReturnsNothing() async {
        let store = makeStore()
        let hits = await store.recall(query: "   ")
        XCTAssertTrue(hits.isEmpty)
    }

    /// The case that motivated ranking terms by value instead of position:
    /// truncating to the first 8 tokens used to keep filler ("look",
    /// "stuff") and throw away the actual subject.
    func testSearchTermsSelectsHighValueTermsNotJustFirstEight() {
        let terms = MemoryStore.searchTerms("can you look for budgets and stuff, do real research")
        XCTAssertTrue(terms.contains("budgets"), "the actual subject must survive")
        XCTAssertTrue(terms.contains("research"))
        XCTAssertFalse(terms.contains("look"), "filler should be filtered, not just deprioritized")
        XCTAssertFalse(terms.contains("stuff"))
    }

    /// With more than 8 real candidates, the longest (most specific) ones
    /// should win the 8 slots rather than whichever came first.
    func testSearchTermsCapsAtEightByLength() {
        let terms = MemoryStore.searchTerms(
            "quarterly infrastructure budget reconciliation spreadsheet deployment pipeline observability dashboard rollout schedule"
        )
        XCTAssertEqual(terms.count, 8)
        XCTAssertTrue(terms.contains("reconciliation"))
        XCTAssertTrue(terms.contains("infrastructure"))
        XCTAssertTrue(terms.contains("observability"))
    }

    func testSearchTermsDeduplicates() {
        let terms = MemoryStore.searchTerms("budget budget budget report")
        XCTAssertEqual(terms.filter { $0 == "budget" }.count, 1)
    }

    /// The whole point of the `context` parameter: a follow-up whose own
    /// words carry no topic ("second one" is generic) still has to find
    /// what a direct query about the same subject would find, as long as
    /// the subject is present in the recent conversation passed as context.
    func testContextEnablesFollowUpRecall() async {
        let store = makeStore()
        let subject = "The quarterly budget report for project atlas needs review before Friday."
        await store.index(
            messageID: UUID(), conversationID: UUID(), role: "user",
            text: subject, createdAt: Date()
        )

        let direct = await store.recall(query: "quarterly budget report project atlas")
        XCTAssertFalse(direct.isEmpty, "a direct query should find it")
        XCTAssertTrue(direct.contains { $0.text.contains("atlas") })

        let followUp = await store.recall(query: "what about the second one?", context: subject)
        XCTAssertFalse(followUp.isEmpty, "context should rescue a follow-up with no topic of its own")
        XCTAssertTrue(followUp.contains { $0.text.contains("atlas") })

        // Without context, the same follow-up finds nothing — proving the
        // context is doing the work, not some other signal.
        let withoutContext = await store.recall(query: "what about the second one?")
        XCTAssertTrue(withoutContext.isEmpty)
    }

    /// A candidate the query itself matched must still outrank one found
    /// only through context, even if both surface the same underlying
    /// text — context is a guess, not a statement of what was asked.
    func testContextTermsRankBelowQueryTerms() async {
        let store = makeStore()
        await store.index(
            messageID: UUID(), conversationID: UUID(), role: "user",
            text: "The deployment key for project atlas lives in the ops vault.",
            createdAt: Date()
        )
        await store.index(
            messageID: UUID(), conversationID: UUID(), role: "user",
            text: "Unrelated note about the office coffee machine being broken again.",
            createdAt: Date()
        )
        let hits = await store.recall(query: "deployment key", context: "coffee machine office broken")
        XCTAssertFalse(hits.isEmpty)
        // The query-matched hit about the deployment key must sort first.
        XCTAssertTrue(hits.first?.text.contains("atlas") ?? false)
    }

    // MARK: - Passage splitting

    func testShortTextIsOnePassage() {
        let text = "This is a short message that does not need splitting."
        XCTAssertEqual(MemoryStore.passages(for: text), [text])
    }

    func testEmptyTextProducesNoPassages() {
        XCTAssertEqual(MemoryStore.passages(for: "   "), [])
    }

    /// Long text must split at paragraph boundaries rather than staying
    /// one giant chunk whose embedding would be dominated by its opening.
    func testLongTextSplitsAtParagraphBoundaries() {
        let paragraph = String(repeating: "word ", count: 200) // ~1000 chars
        let text = [paragraph, paragraph, paragraph].joined(separator: "\n\n")
        let passages = MemoryStore.passages(for: text)
        XCTAssertGreaterThan(passages.count, 1, "a message this long must not stay one passage")
        for passage in passages {
            XCTAssertLessThanOrEqual(passage.count, 2000, "each passage should stay near the embedder's cap")
        }
    }

    /// Splitting must not lose or reorder content — every passage
    /// concatenated back together should reproduce the paragraphs.
    func testPassageSplittingPreservesContent() {
        let paragraphs = (1...10).map { "Paragraph number \($0) with some real content in it to give it length." }
        let text = paragraphs.joined(separator: "\n\n")
        let passages = MemoryStore.passages(for: text)
        let recombined = passages.joined(separator: "\n\n")
        for paragraph in paragraphs {
            XCTAssertTrue(recombined.contains(paragraph))
        }
    }

    /// Indexing a long message must produce multiple searchable chunks,
    /// not one — this is the actual behavior passage splitting exists for.
    func testIndexingLongMessageCreatesMultiplePassages() async {
        let store = makeStore()
        let messageID = UUID()
        let conversationID = UUID()
        let earlyParagraph = String(repeating: "filler content about nothing in particular. ", count: 40)
        let lateParagraph = "The unique deployment token for project nightingale lives in the ops vault."
        let text = earlyParagraph + "\n\n" + String(repeating: "more filler text goes here too. ", count: 40) + "\n\n" + lateParagraph
        await store.index(messageID: messageID, conversationID: conversationID, role: "assistant", text: text, createdAt: Date())

        // A passage buried well past the embedder's 2000-char opening
        // cap must still be keyword-findable — that's only possible if it
        // became its own chunk row rather than being absorbed into one
        // giant chunk for the whole message.
        let hits = await store.recall(query: "nightingale deployment token", excluding: UUID())
        XCTAssertTrue(hits.contains { $0.text.contains("nightingale") })
        await store.forgetConversation(conversationID)
    }

    // MARK: - Fact tiers

    func testInferredFactsRankBelowConfirmedFacts() async {
        let store = makeStore()
        _ = await store.saveInferredFact(content: "Brooklyn might prefer teal accents.", topic: nil, sourceConversationID: nil)
        _ = await store.saveFact(content: "Brooklyn confirmed they prefer teal accents.", topic: nil, sourceConversationID: nil)

        let hits = await store.recall(query: "teal accents preference")
        XCTAssertGreaterThanOrEqual(hits.count, 2)
        guard let confirmedIndex = hits.firstIndex(where: { $0.text.contains("confirmed") }),
              let inferredIndex = hits.firstIndex(where: { $0.text.contains("might") }) else {
            return XCTFail("expected to recall both facts")
        }
        XCTAssertLessThan(confirmedIndex, inferredIndex, "confirmed fact must rank above the inferred one")
    }

    func testInferredFactsAreStillRetrievable() async {
        let store = makeStore()
        _ = await store.saveInferredFact(content: "Brooklyn seems to work mostly in Swift.", topic: nil, sourceConversationID: nil)
        let hits = await store.recall(query: "what language does Brooklyn work in")
        XCTAssertTrue(hits.contains { $0.text.contains("Swift") })
    }

    // MARK: - Rollups

    func testRollupLifecycle() async {
        let store = makeStore()
        let conversationID = UUID()
        XCTAssertNil(await store.rollup(for: conversationID))

        let ok = await store.upsertRollup(conversationID: conversationID, content: "Discussed the project atlas budget timeline.")
        XCTAssertTrue(ok)
        let saved = await store.rollup(for: conversationID)
        XCTAssertEqual(saved?.content, "Discussed the project atlas budget timeline.")

        await store.upsertRollup(conversationID: conversationID, content: "Updated summary about project atlas launch plans.")
        let updated = await store.rollup(for: conversationID)
        XCTAssertEqual(updated?.content, "Updated summary about project atlas launch plans.")

        await store.deleteRollup(for: conversationID)
        XCTAssertNil(await store.rollup(for: conversationID))
    }

    /// The whole point: `recall` must surface a rollup through its normal
    /// keyword path, with no rollup-specific retrieval call.
    func testRecallFindsRollupsThroughTheSameFTSIndex() async {
        let store = makeStore()
        let conversationID = UUID()
        await store.upsertRollup(conversationID: conversationID, content: "Summary: migrated the deployment pipeline to project nightingale.")

        let hits = await store.recall(query: "nightingale deployment pipeline summary")
        XCTAssertTrue(hits.contains { $0.text.contains("nightingale") })
    }

    func testForgetConversationAlsoRemovesItsRollup() async {
        let store = makeStore()
        let conversationID = UUID()
        await store.upsertRollup(conversationID: conversationID, content: "Summary about project nightingale rollout plans.")
        await store.forgetConversation(conversationID)

        XCTAssertNil(await store.rollup(for: conversationID))
        let hits = await store.recall(query: "nightingale rollout plans")
        XCTAssertFalse(hits.contains { $0.text.contains("nightingale") })
    }

    func testIndexedMessageCountExcludesRollups() async {
        let store = makeStore()
        let conversationID = UUID()
        await store.index(
            messageID: UUID(), conversationID: conversationID, role: "user",
            text: "A real message long enough to actually get indexed by the store.",
            createdAt: Date()
        )
        let beforeRollup = await store.indexedMessageCount()
        await store.upsertRollup(conversationID: conversationID, content: "Summary of the conversation above.")
        let afterRollup = await store.indexedMessageCount()
        XCTAssertEqual(beforeRollup, afterRollup, "a rollup is not a message the user sent")
    }
}
