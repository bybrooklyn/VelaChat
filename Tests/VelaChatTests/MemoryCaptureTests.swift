import XCTest
@testable import VelaChat

/// What memory is allowed to write, how it is phrased, and what happens
/// when the same fact is saved twice.
///
/// These pin the three rules that stop memory from filling up with noise:
/// only durable facts get in, they all read the same way, and a
/// restatement updates the fact it restates instead of twinning it.
final class MemoryCaptureTests: XCTestCase {
    /// Never the user's real database — each test gets a throwaway file.
    private func makeStore() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-capture-test-\(UUID().uuidString).sqlite")
        return MemoryStore(databaseURL: url)
    }

    // MARK: - Phrasing

    /// Every stored fact should read as a third-person statement about the
    /// user, whichever voice it arrived in.
    func testNormalizationRewritesToUserSubject() {
        let cases: [(String, String)] = [
            ("I prefer concise answers", "User prefers concise answers"),
            ("prefers concise answers", "User prefers concise answers"),
            ("The user works mainly in Swift", "User works mainly in Swift"),
            ("my main language is Swift", "User's main language is Swift"),
            ("i'm based in Oslo", "User is based in Oslo"),
            ("Based in Oslo", "User is based in Oslo"),
            ("They prefer dark mode", "User prefers dark mode"),
            ("i have two cats", "User has two cats"),
            ("I do not use tabs", "User does not use tabs"),
            ("I watch football", "User watches football"),
            ("their preferred editor is Zed", "User's preferred editor is Zed"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(MemoryPhrasing.normalize(input), expected, "normalizing \"\(input)\"")
        }
    }

    /// Idempotence is what makes it safe to normalize on every write,
    /// including the migration's re-save of already-migrated facts.
    func testNormalizationIsIdempotent() {
        for text in ["User prefers concise answers", "User works mainly in Swift", "User's main language is Swift"] {
            XCTAssertEqual(MemoryPhrasing.normalize(text), text)
            XCTAssertEqual(MemoryPhrasing.normalize(MemoryPhrasing.normalize(text)), text)
        }
    }

    /// A note the model wrapped around the fact is not part of the fact,
    /// and would otherwise poison the dedupe token comparison.
    func testNormalizationStripsPreamblesAndQuotes() {
        XCTAssertEqual(MemoryPhrasing.normalize("Remember that I like tea"), "User likes tea")
        XCTAssertEqual(MemoryPhrasing.normalize("\"I study linguistics\""), "User studies linguistics")
        XCTAssertEqual(MemoryPhrasing.normalize("Note: prefers dark mode"), "User prefers dark mode")
    }

    /// A statement that already has its own subject must be left alone —
    /// prefixing it would produce "User Brooklyn prefers…".
    func testNormalizationLeavesAnExplicitSubjectAlone() {
        XCTAssertEqual(
            MemoryPhrasing.normalize("Brooklyn prefers teal accents."),
            "Brooklyn prefers teal accents."
        )
    }

    /// The pairs the dedupe threshold was chosen against: restatements
    /// merge, genuinely different facts must not.
    func testSimilaritySeparatesDifferentFactsFromRestatements() {
        XCTAssertLessThan(MemoryPhrasing.similarity("User has two cats", "User has two dogs"), 0.7)
        XCTAssertLessThan(MemoryPhrasing.similarity("User works in Swift", "User works in Rust"), 0.7)
        XCTAssertGreaterThanOrEqual(MemoryPhrasing.similarity("User works in Swift", "User works mainly in Swift"), 0.7)
        XCTAssertGreaterThanOrEqual(
            MemoryPhrasing.similarity("User prefers concise answers", "User strongly prefers concise answers"),
            0.7
        )
    }

    // MARK: - Capture rules

    /// The observed failure: a save on nearly every turn, most of it true
    /// today and worthless next month.
    func testRejectsTaskState() {
        let rejected = [
            "User is debugging the recall query today",
            "User asked me to rename the file",
            "User is working on the migration right now",
            "User wants me to summarise this conversation",
        ]
        for text in rejected {
            guard case .taskState = MemoryCapture.rejection(for: text) else {
                return XCTFail("\"\(text)\" should be rejected as task state")
            }
        }
    }

    /// The model saving its own output back as a fact about the user is a
    /// self-reinforcing loop.
    func testRejectsAssistantOutput() {
        for text in ["I suggested using FTS5 for the retrieval layer", "As I mentioned, the vault holds the key"] {
            guard case .assistantOutput = MemoryCapture.rejection(for: text) else {
                return XCTFail("\"\(text)\" should be rejected as the assistant's own output")
            }
        }
    }

    func testRejectsQuestionsAndFragments() {
        guard case .question = MemoryCapture.rejection(for: "Does the user prefer dark mode?") else {
            return XCTFail("a question is not a fact")
        }
        guard case .tooShort = MemoryCapture.rejection(for: "Swift") else {
            return XCTFail("a bare word is not a fact")
        }
        guard case .empty = MemoryCapture.rejection(for: "   ") else {
            return XCTFail("empty content must be rejected")
        }
    }

    /// A memory is one sentence. A paragraph is a conversation summary
    /// wearing a fact's clothes, and truncating it would store half a
    /// fact — worse than storing none.
    func testRejectsOverlongContent() {
        let long = String(repeating: "User prefers extremely detailed answers. ", count: 20)
        guard case .tooLong = MemoryCapture.rejection(for: long) else {
            return XCTFail("a fact this long must be refused, not truncated")
        }
    }

    /// Memory is forever, so it must not capture a credential.
    func testRejectsSecrets() {
        let text = "User's Anthropic key is sk-ant-abcdefghijklmnopqrstuvwxyz012345"
        guard case .secret = MemoryCapture.rejection(for: text) else {
            return XCTFail("a credential must never be saved")
        }
    }

    func testAcceptsDurableFacts() {
        for text in [
            "User prefers concise answers",
            "Prefers Swift over Objective-C for new work",
            "I work in the Europe/Oslo timezone",
        ] {
            XCTAssertNil(MemoryCapture.rejection(for: text), "\"\(text)\" is a durable fact")
        }
    }

    /// The rules have to hold at the write path, not only in the tool's
    /// description — a description is a request.
    func testCaptureRejectionWritesNothing() async {
        let store = makeStore()
        let outcome = await store.capture(
            content: "User is debugging the recall query today",
            topic: "Work",
            sourceConversationID: nil
        )
        guard case .rejected = outcome else {
            return XCTFail("task state must be refused at the write path")
        }
        let facts = await store.allFacts()
        XCTAssertTrue(facts.isEmpty, "a rejected capture must not leave a row behind")
    }

    func testCaptureNormalizesBeforeStoring() async {
        let store = makeStore()
        let outcome = await store.capture(content: "i prefer concise answers", topic: "Preferences", sourceConversationID: nil)
        guard case .saved(let stored) = outcome else {
            return XCTFail("a durable fact should be saved")
        }
        XCTAssertEqual(stored, "User prefers concise answers")
        let facts = await store.allFacts()
        XCTAssertEqual(facts.map(\.content), ["User prefers concise answers"])
    }

    // MARK: - Dedupe

    /// A restatement updates the fact it restates. Without this the store
    /// fills with twins that each take a slot in the prompt budget and
    /// disagree with each other as soon as one is edited.
    func testNearIdenticalFactUpdatesInPlace() async {
        let store = makeStore()
        let first = await store.write(content: "User prefers concise answers", topic: "Preferences", sourceConversationID: nil)
        XCTAssertEqual(first?.didMerge, false)

        let second = await store.write(content: "I strongly prefer concise answers", topic: "Preferences", sourceConversationID: nil)
        XCTAssertEqual(second?.didMerge, true, "a restatement must merge, not add a row")
        XCTAssertEqual(second?.id, first?.id, "merging means updating the existing fact")

        let facts = await store.allFacts()
        XCTAssertEqual(facts.count, 1, "no twin")
        XCTAssertEqual(facts.first?.content, "User strongly prefers concise answers")
    }

    /// The other half of the same rule: a merge that shouldn't happen
    /// destroys a true fact, so facts that merely look alike stay apart.
    func testDifferentFactsAreNotMerged() async {
        let store = makeStore()
        await store.write(content: "User has two cats", topic: "Home", sourceConversationID: nil)
        await store.write(content: "User has two dogs", topic: "Home", sourceConversationID: nil)
        let facts = await store.allFacts()
        XCTAssertEqual(facts.count, 2, "cats and dogs are different facts")
    }

    /// `save_memory` reports the merge rather than silently swallowing it,
    /// so the model can tell the difference between "stored" and "you
    /// already told me this".
    func testCaptureReportsAMerge() async {
        let store = makeStore()
        _ = await store.capture(content: "User prefers concise answers", topic: "Preferences", sourceConversationID: nil)
        let outcome = await store.capture(content: "User prefers very concise answers", topic: "Preferences", sourceConversationID: nil)
        guard case .merged = outcome else {
            return XCTFail("a near-identical save should report a merge")
        }
    }

    // MARK: - Recall gate

    /// The regression the widened query exists to fix.
    ///
    /// Facts used to be matched by scanning rows and testing
    /// `content.contains(term)`. A substring test cannot stem, so the
    /// question "what are their preferences?" — whose only searchable term
    /// is "preferences" — never matched the fact "User prefers concise
    /// answers", and the fact was permanently unreachable through the one
    /// gate that decides what is a candidate at all.
    func testRecallFindsAFactThroughStemming() async {
        let store = makeStore()
        await store.write(content: "User prefers concise answers", topic: "Preferences", sourceConversationID: nil)

        let terms = MemoryStore.searchTerms("what are their preferences?")
        XCTAssertEqual(terms, ["preferences"], "everything else in the question is a stopword")
        // The old substring test, spelled out: this is what used to decide.
        XCTAssertFalse("User prefers concise answers".lowercased().contains("preferences"))

        let hits = await store.recall(query: "what are their preferences?")
        XCTAssertTrue(hits.contains { $0.text.contains("concise") }, "stemming must reach the fact")
    }

    /// Same gate, different way of being invisible: the term filter used
    /// to require more than two characters, which made every two-letter
    /// name ("Go", "AI", "UI") unsearchable no matter what was stored.
    func testRecallFindsATwoLetterSubject() async {
        let store = makeStore()
        await store.write(content: "User writes Go for backend services", topic: "Work", sourceConversationID: nil)
        XCTAssertEqual(MemoryStore.searchTerms("Go"), ["go"])
        let hits = await store.recall(query: "Go")
        XCTAssertTrue(hits.contains { $0.text.contains("Go") })
    }

    /// Widening the gate must not weaken the safety argument: FTS5 still
    /// cannot return text that shares no vocabulary with the query.
    func testWidenedQueryStillCannotInventAMatch() async {
        let store = makeStore()
        await store.write(content: "User prefers concise answers", topic: "Preferences", sourceConversationID: nil)
        let hits = await store.recall(query: "zzzqqq unrelated gibberish xyzzy")
        XCTAssertTrue(hits.isEmpty)
    }

    func testMatchExpressionOrsAndPrefixesEveryTerm() {
        XCTAssertEqual(
            MemoryStore.matchExpression(for: ["budget", "atlas"]),
            "\"budget\"* OR \"atlas\"*"
        )
    }

    // MARK: - Legacy migration

    private func makeDefaults() -> UserDefaults {
        let suite = "vela-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func seedLegacy(_ items: [MemoryItem], into defaults: UserDefaults) {
        let data = try! JSONEncoder().encode(items)
        defaults.set(data, forKey: DefaultsKey.memories)
    }

    /// Facts had two homes — an array in `UserDefaults` and a mirror in
    /// the store — and the cut to one home is only safe if every fact is
    /// verified present before the old copy is removed.
    func testMigrationMovesEveryFactThenDeletesTheLegacyArray() async {
        let store = makeStore()
        let defaults = makeDefaults()
        let items = [
            MemoryItem(content: "I prefer concise answers", topic: "Preferences"),
            MemoryItem(content: "The user works mainly in Swift", topic: "Work"),
            MemoryItem(content: "Brooklyn prefers teal accents.", topic: nil),
        ]
        seedLegacy(items, into: defaults)

        let didComplete = await LegacyMemoryMigration.run(store: store, defaults: defaults)
        XCTAssertTrue(didComplete)

        let stored = await store.allFacts()
        XCTAssertEqual(stored.count, items.count, "every legacy fact must land")
        // Identity survives the move, so a fact keeps its id — and its
        // phrasing is normalized on the way in like any other write.
        for item in items {
            XCTAssertTrue(stored.contains { $0.id == item.id }, "fact \(item.id) is missing")
        }
        XCTAssertTrue(stored.contains { $0.content == "User prefers concise answers" })
        XCTAssertTrue(stored.contains { $0.content == "User works mainly in Swift" })

        XCTAssertNil(defaults.data(forKey: DefaultsKey.memories), "the legacy array is gone")
        XCTAssertNotNil(defaults.object(forKey: DefaultsKey.memoriesMigrationV1))
    }

    /// The one outcome that is unacceptable is a half-migration followed
    /// by a delete. A store that cannot be written to (here: a database
    /// path that cannot be opened) must leave the legacy array completely
    /// intact and the flag unset, so the next launch retries from a source
    /// that still has everything.
    func testMigrationLeavesLegacyArrayIntactWhenVerificationFails() async {
        let unwritable = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-missing-dir-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        let store = MemoryStore(databaseURL: unwritable)
        let defaults = makeDefaults()
        let items = [MemoryItem(content: "I prefer concise answers", topic: "Preferences")]
        seedLegacy(items, into: defaults)

        let didComplete = await LegacyMemoryMigration.run(store: store, defaults: defaults)
        XCTAssertFalse(didComplete, "nothing landed, so the migration did not complete")
        XCTAssertNotNil(defaults.data(forKey: DefaultsKey.memories), "the legacy array must survive")
        XCTAssertNil(defaults.object(forKey: DefaultsKey.memoriesMigrationV1), "and it must be retried")
    }

    /// Runs at every launch, so it has to be a no-op after the first one —
    /// including on a store the user has since edited.
    func testMigrationDoesNotRunTwice() async {
        let store = makeStore()
        let defaults = makeDefaults()
        seedLegacy([MemoryItem(content: "I prefer concise answers", topic: "Preferences")], into: defaults)

        await LegacyMemoryMigration.run(store: store, defaults: defaults)
        await store.deleteEverything()
        let secondRun = await LegacyMemoryMigration.run(store: store, defaults: defaults)

        XCTAssertTrue(secondRun)
        let stored = await store.allFacts()
        XCTAssertTrue(stored.isEmpty, "a completed migration must not resurrect deleted facts")
    }

    /// Nothing to migrate is a completed migration, not a failure — a
    /// fresh install must not retry this forever.
    func testMigrationWithNoLegacyDataCompletes() async {
        let store = makeStore()
        let defaults = makeDefaults()
        let didComplete = await LegacyMemoryMigration.run(store: store, defaults: defaults)
        XCTAssertTrue(didComplete)
        XCTAssertNotNil(defaults.object(forKey: DefaultsKey.memoriesMigrationV1))
    }
}
