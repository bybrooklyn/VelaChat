import Foundation
import SQLite3

/// The persistence layer behind VelaChat's memory: durable facts about
/// the user, plus a searchable index over everything they've ever said.
///
/// SQLite rather than the JSON-in-UserDefaults the rest of the history
/// uses, because this has to stay fast at thousands of conversations and
/// answer two different questions — "what text matches these words"
/// (FTS5) and "what text means something similar" (embedding vectors).
/// Vectors are stored as raw little-endian Float32 blobs; at 512
/// dimensions that's 2 KB per chunk, and a brute-force cosine scan over
/// tens of thousands of chunks is still milliseconds.
///
/// Every failure here is non-fatal by design: memory is an enhancement,
/// and a broken index must degrade to "no results", never to a crash or
/// a blocked reply.
actor MemoryStore {
    static let shared = MemoryStore()

    /// `confirmed` is what `save_memory` and direct user edits create
    /// today — someone actually said or approved this. `inferred` is for
    /// a future background extractor that guesses facts from conversation
    /// without asking; those must still surface in recall, just ranked
    /// below anything a person actually confirmed. See `recall`'s scoring.
    enum FactTier: String, Sendable {
        case confirmed
        case inferred
    }

    struct Fact: Identifiable, Sendable, Equatable {
        var id: UUID
        var content: String
        var topic: String?
        var createdAt: Date
        var updatedAt: Date
        /// How often this fact has actually been recalled into a reply —
        /// the signal for what's worth keeping when memory grows.
        var useCount: Int
        /// Where it came from, so the user can always ask "why do you
        /// think that?" and get a real answer.
        var sourceConversationID: UUID?
        var tier: FactTier
    }

    /// One rolling summary per conversation. The generated text itself
    /// comes from outside this file; this is only the storage contract.
    struct Rollup: Sendable, Equatable {
        var conversationID: UUID
        var content: String
        var createdAt: Date
        var updatedAt: Date
    }

    struct Chunk: Sendable {
        var id: Int64
        var conversationID: UUID
        var messageID: UUID
        var role: String
        var text: String
        var createdAt: Date
    }

    /// A retrieval hit, with the score that produced it so the UI can
    /// explain itself rather than presenting recall as magic.
    struct Hit: Sendable {
        enum Source: Sendable { case fact(UUID), chunk(conversationID: UUID, messageID: UUID) }
        var source: Source
        var text: String
        var score: Double
    }

    private var database: OpaquePointer?
    private let embeddingDimension = 512
    /// Injectable so tests get their own database instead of writing into
    /// the user's real memory.
    private let overrideURL: URL?

    private var databaseURL: URL {
        if let overrideURL { return overrideURL }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelaChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("memory.sqlite")
    }

    init(databaseURL: URL? = nil) {
        overrideURL = databaseURL
    }

    // MARK: - Lifecycle

    func open() {
        guard database == nil else { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            return
        }
        database = handle
        // WAL keeps reads from blocking the indexer, which runs in the
        // background while the user is chatting.
        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")
        migrate()
    }

    /// Every statement here must be safe to run again on a database that
    /// already has real user data in it — this runs on every launch, not
    /// just the first. New columns/tables are created additively
    /// (`IF NOT EXISTS` / guarded `ALTER TABLE ... ADD COLUMN`); the one
    /// place a table's shape actually changes (`chunks`, for passages) is
    /// a copy-into-a-new-table rebuild that never drops data, verified in
    /// `migrateChunksSchemaIfNeeded`.
    private func migrate() {
        execute("""
        CREATE TABLE IF NOT EXISTS facts (
            id TEXT PRIMARY KEY,
            content TEXT NOT NULL,
            topic TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 0,
            source_conversation TEXT,
            embedding BLOB
        );
        """)
        // Confidence tier: 'confirmed' (save_memory / user edits, today's
        // only source) vs 'inferred' (a future background extractor).
        // Existing rows have no opinion on this, so they default to the
        // tier that reflects how every current row actually got created.
        if !columnExists(table: "facts", column: "tier") {
            execute("ALTER TABLE facts ADD COLUMN tier TEXT NOT NULL DEFAULT 'confirmed';")
        }

        let chunksNeedsFTSRebuild = migrateChunksSchemaIfNeeded()

        execute("CREATE INDEX IF NOT EXISTS chunks_conversation ON chunks(conversation_id);")
        // FTS5 for keyword recall. Kept in sync by triggers rather than by
        // remembering to write to two places at every call site. Rollup
        // summaries are mirrored into `chunks` too (see `upsertRollup`), so
        // this single index is also the "same FTS layer" rollups are found
        // through — `recall` needs no rollup-specific query.
        execute("CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(text, content='chunks', content_rowid='id');")
        execute("""
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
        END;
        """)
        execute("""
        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
            INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.id, old.text);
        END;
        """)
        execute("""
        CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
            INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.id, old.text);
            INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
        END;
        """)
        if chunksNeedsFTSRebuild {
            // The external-content table just got new rowids from the copy
            // in migrateChunksSchemaIfNeeded; the shadow index has to be
            // rebuilt from the content table rather than trusting triggers
            // that were only just (re)created.
            execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild');")
        }

        execute("""
        CREATE TABLE IF NOT EXISTS rollups (
            conversation_id TEXT PRIMARY KEY,
            content TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
    }

    /// Legacy databases predate passages: one `chunks` row per message,
    /// enforced by `UNIQUE(message_id)` alone. SQLite cannot ALTER a
    /// UNIQUE constraint in place, so this rebuilds the table under a new
    /// constraint — `UNIQUE(message_id, passage_index)` — via
    /// rename-copy-drop rather than touching data in place. Returns
    /// whether a rebuild happened, so callers know the FTS shadow index
    /// needs rebuilding too.
    ///
    /// Safe to re-run, including after being interrupted mid-migration
    /// (crash, force-quit): `chunks_legacy` surviving from a previous
    /// attempt is resumed rather than starting over — the source rows are
    /// still sitting there untouched — and the copy itself uses
    /// `INSERT OR IGNORE` so repeating it is a no-op rather than a
    /// constraint violation.
    private func migrateChunksSchemaIfNeeded() -> Bool {
        let newSchema = """
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            passage_index INTEGER NOT NULL DEFAULT 0,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at REAL NOT NULL,
            embedding BLOB,
            UNIQUE(message_id, passage_index)
        );
        """
        execute(newSchema)

        let resumingInterruptedMigration = tableExists("chunks_legacy")
        let alreadyNewSchema = columnExists(table: "chunks", column: "passage_index")
        // Covers both "chunks_fts never got created yet" (brand new
        // database) and "got dropped mid-migration but the process died
        // before it was rebuilt" — either way, self-heal rather than leave
        // the index silently empty until something happens to rewrite it.
        let ftsMissing = !tableExists("chunks_fts")
        guard resumingInterruptedMigration || !alreadyNewSchema || ftsMissing else { return false }

        if resumingInterruptedMigration || !alreadyNewSchema {
            if !resumingInterruptedMigration {
                execute("ALTER TABLE chunks RENAME TO chunks_legacy;")
                execute(newSchema)
            }
            execute("""
                INSERT OR IGNORE INTO chunks (conversation_id, message_id, passage_index, role, text, created_at, embedding)
                SELECT conversation_id, message_id, 0, role, text, created_at, embedding FROM chunks_legacy;
                """)
            execute("DROP TABLE chunks_legacy;")
        }
        // Dropping the old table also drops the triggers that were bound
        // to it (SQLite behavior, verified). The FTS shadow table is not
        // trigger-bound, so it survives pointing at rowids that no longer
        // mean anything and has to go too; it's fully derivable from
        // `chunks` again via the rebuild the caller performs.
        execute("DROP TABLE IF EXISTS chunks_fts;")
        return true
    }

    // MARK: - Facts

    func saveFact(content: String, topic: String?, sourceConversationID: UUID?, tier: FactTier = .confirmed) -> UUID? {
        open()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID()
        let now = Date().timeIntervalSince1970
        let embedding = MemoryEmbedder.shared.vector(for: trimmed)
        guard let statement = prepare("""
            INSERT INTO facts (id, content, topic, created_at, updated_at, use_count, source_conversation, embedding, tier)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?);
            """) else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, id.uuidString)
        bindText(statement, 2, trimmed)
        bindText(statement, 3, topic)
        sqlite3_bind_double(statement, 4, now)
        sqlite3_bind_double(statement, 5, now)
        bindText(statement, 6, sourceConversationID?.uuidString)
        bindBlob(statement, 7, embedding.map(Self.encode))
        bindText(statement, 8, tier.rawValue)
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return id
    }

    /// Convenience for a future background extractor: same write path as
    /// `saveFact`, just tagged so `recall` ranks it below anything the
    /// user actually confirmed.
    @discardableResult
    func saveInferredFact(content: String, topic: String?, sourceConversationID: UUID?) -> UUID? {
        saveFact(content: content, topic: topic, sourceConversationID: sourceConversationID, tier: .inferred)
    }

    /// Insert-or-replace by caller-supplied id, so the fact list the user
    /// edits in Settings and the searchable copy here can't drift apart.
    /// Always writes `confirmed`: this is the save_memory / Settings-edit
    /// path, and editing a fact by hand is itself a confirmation even if
    /// the row started out some other way.
    func upsertFact(id: UUID, content: String, topic: String?) {
        open()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let embedding = MemoryEmbedder.shared.vector(for: trimmed)
        guard let statement = prepare("""
            INSERT INTO facts (id, content, topic, created_at, updated_at, use_count, source_conversation, embedding, tier)
            VALUES (?, ?, ?, ?, ?, 0, NULL, ?, 'confirmed')
            ON CONFLICT(id) DO UPDATE SET content = excluded.content, topic = excluded.topic,
                updated_at = excluded.updated_at, embedding = excluded.embedding, tier = 'confirmed';
            """) else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, id.uuidString)
        bindText(statement, 2, trimmed)
        bindText(statement, 3, topic)
        sqlite3_bind_double(statement, 4, now)
        sqlite3_bind_double(statement, 5, now)
        bindBlob(statement, 6, embedding.map(Self.encode))
        sqlite3_step(statement)
    }

    func updateFact(id: UUID, content: String?, topic: String?) {
        open()
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let embedding = MemoryEmbedder.shared.vector(for: content)
            guard let statement = prepare("UPDATE facts SET content = ?, updated_at = ?, embedding = ? WHERE id = ?;") else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, content)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            bindBlob(statement, 3, embedding.map(Self.encode))
            bindText(statement, 4, id.uuidString)
            sqlite3_step(statement)
        }
        if let topic {
            guard let statement = prepare("UPDATE facts SET topic = ?, updated_at = ? WHERE id = ?;") else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, topic)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            bindText(statement, 3, id.uuidString)
            sqlite3_step(statement)
        }
    }

    func deleteFact(id: UUID) {
        open()
        guard let statement = prepare("DELETE FROM facts WHERE id = ?;") else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, id.uuidString)
        sqlite3_step(statement)
    }

    func allFacts() -> [Fact] {
        open()
        guard let statement = prepare("SELECT id, content, topic, created_at, updated_at, use_count, source_conversation, tier FROM facts ORDER BY updated_at DESC;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var facts: [Fact] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0) ?? "") else { continue }
            facts.append(Fact(
                id: id,
                content: text(statement, 1) ?? "",
                topic: text(statement, 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                useCount: Int(sqlite3_column_int64(statement, 5)),
                sourceConversationID: text(statement, 6).flatMap(UUID.init(uuidString:)),
                tier: text(statement, 7).flatMap(FactTier.init(rawValue:)) ?? .confirmed
            ))
        }
        return facts
    }

    func noteFactUsed(_ ids: [UUID]) {
        open()
        for id in ids {
            guard let statement = prepare("UPDATE facts SET use_count = use_count + 1 WHERE id = ?;") else { continue }
            bindText(statement, 1, id.uuidString)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    // MARK: - Conversation index

    /// Rollup rows are mirrored into `chunks` under this role so they ride
    /// the same FTS index as real messages; `indexedMessageCount` excludes
    /// them so "messages indexed" in Settings doesn't count summaries as
    /// messages the user never actually sent.
    private static let rollupRole = "rollup"

    /// Indexes one message, as one or more passages (see `passages`).
    /// Idempotent per (message, passage): re-running the backfill can't
    /// create duplicates, because `UNIQUE(message_id, passage_index)` and
    /// `INSERT OR IGNORE` do that work rather than a caller having to.
    func index(messageID: UUID, conversationID: UUID, role: String, text messageText: String, createdAt: Date) {
        open()
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very short messages ("ok", "thanks") are noise in a semantic
        // index and would crowd out real matches.
        guard trimmed.count >= 40 else { return }
        for (passageIndex, passage) in Self.passages(for: trimmed).enumerated() {
            let embedding = MemoryEmbedder.shared.vector(for: passage)
            guard let statement = prepare("""
                INSERT OR IGNORE INTO chunks (conversation_id, message_id, passage_index, role, text, created_at, embedding)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """) else { continue }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, conversationID.uuidString)
            bindText(statement, 2, messageID.uuidString)
            sqlite3_bind_int(statement, 3, Int32(passageIndex))
            bindText(statement, 4, role)
            bindText(statement, 5, String(passage.prefix(4_000)))
            sqlite3_bind_double(statement, 6, createdAt.timeIntervalSince1970)
            bindBlob(statement, 7, embedding.map(Self.encode))
            sqlite3_step(statement)
        }
    }

    func isIndexed(messageID: UUID) -> Bool {
        open()
        guard let statement = prepare("SELECT 1 FROM chunks WHERE message_id = ? LIMIT 1;") else { return false }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, messageID.uuidString)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Drops one message (all its passages) from the index — the "don't
    /// use this again" action, which has to actually stop it coming back.
    func forgetMessage(_ messageID: UUID) {
        open()
        guard let statement = prepare("DELETE FROM chunks WHERE message_id = ?;") else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, messageID.uuidString)
        sqlite3_step(statement)
    }

    func forgetConversation(_ conversationID: UUID) {
        open()
        if let statement = prepare("DELETE FROM chunks WHERE conversation_id = ?;") {
            bindText(statement, 1, conversationID.uuidString)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        // A rollup is a summary of exactly this conversation; forgetting
        // the conversation without forgetting its summary would leave a
        // ghost of it searchable forever.
        if let statement = prepare("DELETE FROM rollups WHERE conversation_id = ?;") {
            bindText(statement, 1, conversationID.uuidString)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    /// Distinct messages, not chunk rows — one message can now be several
    /// passages, and a rollup isn't a message the user sent at all.
    func indexedMessageCount() -> Int {
        open()
        guard let statement = prepare("SELECT COUNT(DISTINCT message_id) FROM chunks WHERE role != ?;") else { return 0 }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, Self.rollupRole)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Splits long text into passages at paragraph boundaries, so one
    /// sprawling assistant reply doesn't become a single chunk whose
    /// embedding is dominated by whatever it opens with (the same problem
    /// `MemoryEmbedder`'s 2000-char cap exists to limit, one level up).
    /// Short text is returned as a single passage — most messages never
    /// hit this at all.
    static func passages(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxPassageChars else { return [trimmed] }

        let paragraphs = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return [trimmed] }

        var result: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if current.isEmpty {
                current = paragraph
            } else if current.count + 2 + paragraph.count <= maxPassageChars {
                current += "\n\n" + paragraph
            } else {
                result.append(current)
                current = paragraph
            }
            // A single paragraph longer than the cap becomes its own
            // over-length passage rather than being torn mid-sentence —
            // the embedder's own cap already handles trimming that safely.
            if current.count > maxPassageChars {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [trimmed] : result
    }

    /// Roughly matches `MemoryEmbedder`'s 2000-char cap: a passage under
    /// that size gets a vector shaped by its whole content, not by
    /// content beyond the cap that would otherwise be silently ignored.
    private static let maxPassageChars = 1800

    // MARK: - Rollups

    /// Insert-or-replace by conversation, and mirrored into `chunks` as a
    /// single synthetic-message row (role `rollup`, message id = the
    /// conversation's own id — a rollup is 1:1 with its conversation, so
    /// that id can't collide with any real, independently-random message
    /// UUID). That mirror is what makes rollups show up in `recall`
    /// through the exact same FTS query as real messages, with no
    /// rollup-specific retrieval path.
    @discardableResult
    func upsertRollup(conversationID: UUID, content: String) -> Bool {
        open()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let now = Date().timeIntervalSince1970
        guard let statement = prepare("""
            INSERT INTO rollups (conversation_id, content, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(conversation_id) DO UPDATE SET content = excluded.content, updated_at = excluded.updated_at;
            """) else { return false }
        bindText(statement, 1, conversationID.uuidString)
        bindText(statement, 2, trimmed)
        sqlite3_bind_double(statement, 3, now)
        sqlite3_bind_double(statement, 4, now)
        let ok = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        guard ok else { return false }

        let embedding = MemoryEmbedder.shared.vector(for: trimmed)
        guard let chunkStatement = prepare("""
            INSERT INTO chunks (conversation_id, message_id, passage_index, role, text, created_at, embedding)
            VALUES (?, ?, 0, ?, ?, ?, ?)
            ON CONFLICT(message_id, passage_index) DO UPDATE SET
                text = excluded.text, embedding = excluded.embedding, created_at = excluded.created_at;
            """) else { return true }
        defer { sqlite3_finalize(chunkStatement) }
        bindText(chunkStatement, 1, conversationID.uuidString)
        bindText(chunkStatement, 2, conversationID.uuidString)
        bindText(chunkStatement, 3, Self.rollupRole)
        bindText(chunkStatement, 4, String(trimmed.prefix(4_000)))
        sqlite3_bind_double(chunkStatement, 5, now)
        bindBlob(chunkStatement, 6, embedding.map(Self.encode))
        sqlite3_step(chunkStatement)
        return true
    }

    func rollup(for conversationID: UUID) -> Rollup? {
        open()
        guard let statement = prepare("SELECT content, created_at, updated_at FROM rollups WHERE conversation_id = ?;") else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, conversationID.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Rollup(
            conversationID: conversationID,
            content: text(statement, 0) ?? "",
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        )
    }

    /// Removes both the summary itself and its mirrored, searchable copy —
    /// unlike `forgetConversation`/`forgetMessage`, which only ever touch
    /// the searchable copy, this is a real delete of the rollup.
    func deleteRollup(for conversationID: UUID) {
        open()
        if let statement = prepare("DELETE FROM rollups WHERE conversation_id = ?;") {
            bindText(statement, 1, conversationID.uuidString)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        if let statement = prepare("DELETE FROM chunks WHERE message_id = ? AND role = ?;") {
            bindText(statement, 1, conversationID.uuidString)
            bindText(statement, 2, Self.rollupRole)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    // MARK: - Retrieval

    /// Recall is keyword-first, with embeddings only re-ranking what
    /// keywords already found.
    ///
    /// That is a measured decision, not a preference. Apple's on-device
    /// sentence embedding cannot separate signal from noise well enough to
    /// retrieve on its own: the query "zzzqqq unrelated gibberish xyzzy"
    /// scored an unrelated note about pizza dough at 0.279, HIGHER than
    /// the correct hit for a real question (0.274). No absolute threshold
    /// works when the same number means "right answer" for one query and
    /// "pure noise" for another, and no relative threshold works either,
    /// because nonsense still produces a confident-looking top hit.
    ///
    /// So FTS5 decides what counts as a candidate — it cannot invent a
    /// match — and embeddings only reorder those candidates, where the set
    /// is already topically constrained. Real semantic recall needs a real
    /// embedding model; that is what the opt-in pplx-embed/MLX upgrade is
    /// for, and until it lands this stays honest about what it can do.
    ///
    /// `context` is recent conversation text (e.g. the last couple of
    /// turns) that widens candidacy without pretending it's what the user
    /// actually asked. A follow-up like "what about the second one?"
    /// carries no topic of its own — every one of its words is either a
    /// stopword or too generic to search on — so without context there is
    /// nothing for FTS5 to find a candidate with. Context terms are
    /// discounted (`contextTermDiscount`) rather than treated as equal to
    /// the query's own words, so a message that only the context happens
    /// to mention still ranks below one the query itself actually matched.
    func recall(query: String, context: String = "", factLimit: Int = 6, chunkLimit: Int = 4, excluding conversationID: UUID? = nil) -> [Hit] {
        open()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let queryTerms = Self.searchTerms(trimmed)
        var candidates = keywordChunks(terms: queryTerms, limit: chunkLimit * 3, excluding: conversationID)
        candidates += keywordFacts(terms: queryTerms, limit: factLimit * 2)

        let contextTerms = Self.searchTerms(context).filter { !queryTerms.contains($0) }
        if !contextTerms.isEmpty {
            var contextHits = keywordChunks(terms: contextTerms, limit: chunkLimit * 2, excluding: conversationID)
            contextHits += keywordFacts(terms: contextTerms, limit: factLimit)
            candidates += contextHits.map { hit in
                var discounted = hit
                discounted.score *= Self.contextTermDiscount
                return discounted
            }
        }

        guard !candidates.isEmpty else { return [] }

        // Re-rank: keyword strength blended with semantic similarity, so a
        // candidate that also *means* the right thing rises above one that
        // merely shares a word.
        if let queryVector = MemoryEmbedder.shared.vector(for: trimmed) {
            candidates = candidates.map { hit in
                guard let vector = embedding(for: hit.source) else { return hit }
                var reranked = hit
                reranked.score = hit.score * 0.6 + max(0, Self.cosine(queryVector, vector)) * 0.4
                return reranked
            }
        }

        var best: [String: Hit] = [:]
        for hit in candidates {
            let key: String
            switch hit.source {
            case .fact(let id): key = "f:\(id)"
            case .chunk(_, let messageID): key = "c:\(messageID)"
            }
            if let existing = best[key], existing.score >= hit.score { continue }
            best[key] = hit
        }
        return Array(best.values.sorted { $0.score > $1.score }.prefix(factLimit + chunkLimit))
    }

    /// How much a candidate found only through conversation context (not
    /// the query itself) gets discounted before competing with candidates
    /// the query's own words actually matched.
    private static let contextTermDiscount = 0.5
    /// Same idea for facts the extractor guessed rather than the user
    /// confirmed: retrievable, but never ranked above an equally-strong
    /// confirmed match.
    private static let inferredFactDiscount = 0.6

    private func embedding(for source: Hit.Source) -> [Float]? {
        let sql: String
        let key: String
        switch source {
        case .fact(let id):
            sql = "SELECT embedding FROM facts WHERE id = ?;"
            key = id.uuidString
        case .chunk(_, let messageID):
            sql = "SELECT embedding FROM chunks WHERE message_id = ?;"
            key = messageID.uuidString
        }
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return blob(statement, 0).map(Self.decode)
    }

    /// Facts matched lexically. The set is small and user-curated, so a
    /// scan beats maintaining a second FTS table for it.
    private func keywordFacts(terms: [String], limit: Int) -> [Hit] {
        guard !terms.isEmpty else { return [] }
        guard let statement = prepare("SELECT id, content, topic, tier FROM facts;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0) ?? ""),
                  let content = text(statement, 1) else { continue }
            let haystack = (content + " " + (text(statement, 2) ?? "")).lowercased()
            let matches = terms.filter { haystack.contains($0) }.count
            guard matches > 0 else { continue }
            var score = min(0.9, 0.4 + 0.1 * Double(matches))
            // An inferred fact hasn't been confirmed by anyone; an equally
            // strong keyword match still ranks below a confirmed fact that
            // matched the same way.
            if text(statement, 3) == FactTier.inferred.rawValue {
                score *= Self.inferredFactDiscount
            }
            hits.append(Hit(source: .fact(id), text: content, score: score))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    private func keywordChunks(terms rawTerms: [String], limit: Int, excluding conversationID: UUID?) -> [Hit] {
        let terms = rawTerms.map { "\"\($0)\"" }
        guard !terms.isEmpty else { return [] }
        guard let statement = prepare("""
            SELECT c.conversation_id, c.message_id, c.text, bm25(chunks_fts)
            FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid
            WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT ?;
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, terms.joined(separator: " OR "))
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let conversation = UUID(uuidString: text(statement, 0) ?? ""),
                  let message = UUID(uuidString: text(statement, 1) ?? ""),
                  let body = text(statement, 2) else { continue }
            if let conversationID, conversation == conversationID { continue }
            // bm25 is lower-is-better; map it into the 0…1 space the cosine
            // scores use so the two can be blended.
            let rank = sqlite3_column_double(statement, 3)
            hits.append(Hit(
                source: .chunk(conversationID: conversation, messageID: message),
                text: body,
                score: max(0.3, min(0.9, 1.0 / (1.0 + abs(rank))))
            ))
        }
        return hits
    }

    /// Words worth searching on: long enough to carry meaning, minus the
    /// question-words and filler that would match every message ever
    /// written ("can you look for budgets and stuff, do real research"
    /// is mostly this list).
    ///
    /// Capped at 8 terms, but by *value* rather than position: a query
    /// with more than 8 real candidates used to keep whichever 8 happened
    /// to come first, which for that budgets example threw away the
    /// actual subject and kept "look"/"stuff" instead. Word length is a
    /// cheap, corpus-free stand-in for rarity — this is a pure static
    /// function with no access to term frequencies across the store — and
    /// longer words are reliably more specific than short ones in
    /// practice ("budgets" carries the query; "just" and "real" don't).
    static func searchTerms(_ query: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "what", "where", "when", "which",
            "was", "are", "you", "your", "about", "from", "how", "did", "does", "should",
            "would", "could", "have", "has", "its", "our", "their", "them", "they", "were",
            "can", "will", "shall", "may", "might", "must", "not", "but",
            "get", "got", "just", "like", "really", "actually", "basically",
            "kind", "sort", "stuff", "things", "thing", "want", "wanted", "wants",
            "need", "needs", "needed", "look", "looking", "looked",
            "into", "over", "under", "then", "than", "there", "here",
            "being", "been", "doing", "done", "make", "made", "going",
            "let", "lets", "okay", "yeah", "yes", "some", "any", "also",
            "much", "many", "more", "most", "other", "such", "only", "own",
            "same", "too", "very", "who", "whom", "whose", "why", "all",
            "each", "few", "these", "those", "again", "once", "out", "off",
            "down", "now", "one", "two", "ever", "every",
        ]
        let candidates = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
            .reduce(into: [String]()) { result, term in
                // De-dupe while keeping first occurrence, so "budget...
                // budget" doesn't cost two of the eight slots.
                if !result.contains(term) { result.append(term) }
            }
        guard candidates.count > 8 else { return candidates }
        return candidates
            .enumerated()
            .sorted { a, b in
                if a.element.count != b.element.count { return a.element.count > b.element.count }
                return a.offset < b.offset
            }
            .prefix(8)
            .map(\.element)
    }


    // MARK: - Vector helpers

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, normA: Double = 0, normB: Double = 0
        for index in a.indices {
            dot += Double(a[index]) * Double(b[index])
            normA += Double(a[index]) * Double(a[index])
            normB += Double(b[index]) * Double(b[index])
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    // MARK: - SQLite plumbing

    private func execute(_ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    /// Table/column names here are always internal literals, never
    /// user input, so string interpolation into PRAGMA is safe.
    private func tableExists(_ name: String) -> Bool {
        guard let statement = prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;") else { return false }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, name)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func columnExists(table: String, column: String) -> Bool {
        guard let statement = prepare("PRAGMA table_info(\(table));") else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { return true }
        }
        return false
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        // SQLITE_TRANSIENT: SQLite must copy the bytes, since the Swift
        // string can be deallocated before the statement runs.
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindBlob(_ statement: OpaquePointer?, _ index: Int32, _ value: Data?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func blob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        let length = Int(sqlite3_column_bytes(statement, index))
        guard let pointer = sqlite3_column_blob(statement, index), length > 0 else { return nil }
        return Data(bytes: pointer, count: length)
    }
}
