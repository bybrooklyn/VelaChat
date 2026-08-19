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
        execute("""
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at REAL NOT NULL,
            embedding BLOB,
            UNIQUE(message_id)
        );
        """)
        execute("CREATE INDEX IF NOT EXISTS chunks_conversation ON chunks(conversation_id);")
        // FTS5 for keyword recall. Kept in sync by triggers rather than by
        // remembering to write to two places at every call site.
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
    }

    // MARK: - Facts

    func saveFact(content: String, topic: String?, sourceConversationID: UUID?) -> UUID? {
        open()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID()
        let now = Date().timeIntervalSince1970
        let embedding = MemoryEmbedder.shared.vector(for: trimmed)
        guard let statement = prepare("""
            INSERT INTO facts (id, content, topic, created_at, updated_at, use_count, source_conversation, embedding)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?);
            """) else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, id.uuidString)
        bindText(statement, 2, trimmed)
        bindText(statement, 3, topic)
        sqlite3_bind_double(statement, 4, now)
        sqlite3_bind_double(statement, 5, now)
        bindText(statement, 6, sourceConversationID?.uuidString)
        bindBlob(statement, 7, embedding.map(Self.encode))
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return id
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
        guard let statement = prepare("SELECT id, content, topic, created_at, updated_at, use_count, source_conversation FROM facts ORDER BY updated_at DESC;") else { return [] }
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
                sourceConversationID: text(statement, 6).flatMap(UUID.init(uuidString:))
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

    /// Indexes one message. Idempotent per message ID, so re-running the
    /// backfill can't create duplicates.
    func index(messageID: UUID, conversationID: UUID, role: String, text messageText: String, createdAt: Date) {
        open()
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very short messages ("ok", "thanks") are noise in a semantic
        // index and would crowd out real matches.
        guard trimmed.count >= 40 else { return }
        let embedding = MemoryEmbedder.shared.vector(for: trimmed)
        guard let statement = prepare("""
            INSERT OR IGNORE INTO chunks (conversation_id, message_id, role, text, created_at, embedding)
            VALUES (?, ?, ?, ?, ?, ?);
            """) else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, conversationID.uuidString)
        bindText(statement, 2, messageID.uuidString)
        bindText(statement, 3, role)
        bindText(statement, 4, String(trimmed.prefix(4_000)))
        sqlite3_bind_double(statement, 5, createdAt.timeIntervalSince1970)
        bindBlob(statement, 6, embedding.map(Self.encode))
        sqlite3_step(statement)
    }

    func isIndexed(messageID: UUID) -> Bool {
        open()
        guard let statement = prepare("SELECT 1 FROM chunks WHERE message_id = ? LIMIT 1;") else { return false }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, messageID.uuidString)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func forgetConversation(_ conversationID: UUID) {
        open()
        guard let statement = prepare("DELETE FROM chunks WHERE conversation_id = ?;") else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, conversationID.uuidString)
        sqlite3_step(statement)
    }

    func indexedMessageCount() -> Int {
        open()
        guard let statement = prepare("SELECT COUNT(*) FROM chunks;") else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
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
    func recall(query: String, factLimit: Int = 6, chunkLimit: Int = 4, excluding conversationID: UUID? = nil) -> [Hit] {
        open()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates = keywordChunks(trimmed, limit: chunkLimit * 3, excluding: conversationID)
        candidates += keywordFacts(trimmed, limit: factLimit * 2)
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
    private func keywordFacts(_ query: String, limit: Int) -> [Hit] {
        let terms = Self.searchTerms(query)
        guard !terms.isEmpty else { return [] }
        guard let statement = prepare("SELECT id, content, topic FROM facts;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0) ?? ""),
                  let content = text(statement, 1) else { continue }
            let haystack = (content + " " + (text(statement, 2) ?? "")).lowercased()
            let matches = terms.filter { haystack.contains($0) }.count
            guard matches > 0 else { continue }
            hits.append(Hit(source: .fact(id), text: content, score: min(0.9, 0.4 + 0.1 * Double(matches))))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    private func keywordChunks(_ query: String, limit: Int, excluding conversationID: UUID?) -> [Hit] {
        let terms = Self.searchTerms(query).map { "\"\($0)\"" }
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
    /// question-words that would match every message ever written.
    static func searchTerms(_ query: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "what", "where", "when", "which",
            "was", "are", "you", "your", "about", "from", "how", "did", "does", "should",
            "would", "could", "have", "has", "its", "our", "their", "them", "they", "were",
        ]
        return Array(
            query
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }
                .prefix(8)
        )
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
