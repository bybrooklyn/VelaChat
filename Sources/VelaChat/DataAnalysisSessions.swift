import Foundation
import VelaCore

/// §9.2 — one analysis database per conversation, built from the data
/// files attached to it.
///
/// An actor rather than MainActor state: parsing a 200,000-row CSV and
/// inserting it row by row is real work, and it has no business happening
/// between two frames of the UI. The app hands over bytes; everything
/// after that happens here.
actor DataAnalysisSessions {

    /// What one attached file contributes: its identity (so a file is
    /// loaded once, not once per turn) and its name. The bytes are NOT
    /// carried here — a 20 MB spreadsheet would then be read off disk and
    /// held in memory on every send, long after it was loaded. They are
    /// fetched through `bytes` below, only for the files this session
    /// hasn't seen yet.
    struct Source: Sendable {
        var attachmentID: UUID
        var filename: String
    }

    /// Reads one attachment's bytes on demand. Injected by the app, since
    /// only it knows where an attachment's data actually lives.
    typealias ByteProvider = @Sendable (UUID) async -> Data?

    private struct Session {
        var database: AnalysisDatabase
        var loaded: Set<UUID> = []
        var schemaText = ""
        /// Files that could not be loaded, with the reason. Surfaced to the
        /// model in the schema block: a file the user attached and the
        /// model never hears about again is the worst of both worlds.
        var problems: [String] = []
        /// Temporary copies written for SQLite sources, removed with the
        /// session.
        var temporaryFiles: [URL] = []
    }

    private var sessions: [UUID: Session] = [:]

    /// Loads whatever is new and returns the schema block for the prompt.
    /// Idempotent: called on every send, and re-attaching the same file
    /// costs a set lookup.
    func schemaText(for conversationID: UUID, sources: [Source], bytes: ByteProvider) async -> String {
        guard !sources.isEmpty else { return "" }
        await load(sources, into: conversationID, bytes: bytes)
        guard let session = sessions[conversationID] else { return "" }
        var text = session.schemaText
        if !session.problems.isEmpty {
            text += (text.isEmpty ? "" : "\n\n") + session.problems.joined(separator: "\n")
        }
        return text
    }

    /// Runs one model query. The result is returned in the shape the
    /// transcript card needs; the model-facing text is built by the caller
    /// from the same values, so the card and the model never disagree.
    func query(
        conversationID: UUID,
        sources: [Source],
        bytes: ByteProvider,
        sql: String,
        chartJSON: String?
    ) async -> DataQueryOutcome {
        await load(sources, into: conversationID, bytes: bytes)
        guard let session = sessions[conversationID] else {
            return DataQueryOutcome(sql: sql, error: "no data is attached to this conversation.")
        }
        do {
            let result = try await session.database.query(sql)
            var outcome = DataQueryOutcome(
                sql: sql,
                columns: result.columns,
                rows: result.rows,
                truncated: result.truncated
            )
            if let chartJSON,
               let object = (try? JSONSerialization.jsonObject(with: Data(chartJSON.utf8))) as? [String: Any],
               !object.isEmpty {
                do {
                    outcome.chart = try DataAnalysis.chartSpec(from: object, resultColumns: result.columns)
                } catch {
                    // The query still succeeded — a bad chart spec must not
                    // discard rows the model asked for. It's reported as a
                    // note so the next call can fix the spec.
                    outcome.chartProblem = "\(error)"
                }
            }
            return outcome
        } catch {
            return DataQueryOutcome(sql: sql, error: "\(error)")
        }
    }

    func discard(conversationID: UUID) async {
        guard let session = sessions.removeValue(forKey: conversationID) else { return }
        await session.database.close()
        for url in session.temporaryFiles { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Loading

    private func load(_ sources: [Source], into conversationID: UUID, bytes: ByteProvider) async {
        var session: Session
        if let existing = sessions[conversationID] {
            session = existing
        } else {
            guard let database = try? AnalysisDatabase() else { return }
            session = Session(database: database)
        }
        let pending = sources.filter { !session.loaded.contains($0.attachmentID) }
        guard !pending.isEmpty || session.schemaText.isEmpty else {
            sessions[conversationID] = session
            return
        }

        for source in pending {
            session.loaded.insert(source.attachmentID)
            guard let data = await bytes(source.attachmentID), !data.isEmpty else {
                session.problems.append("\(source.filename) could not be read.")
                continue
            }
            do {
                if DataSourceLoader.Format.detect(filename: source.filename) == .sqlite {
                    // ATTACH needs a path, and an attachment is bytes. The
                    // copy is temporary, read-only to SQLite, and removed
                    // with the session — the user's own file is never
                    // opened, let alone written.
                    let url = try writeTemporaryCopy(of: source, data: data)
                    session.temporaryFiles.append(url)
                    let alias = SQLIdentifier.sanitize(
                        (source.filename as NSString).deletingPathExtension,
                        fallback: "source"
                    )
                    try await session.database.attachSQLiteFile(at: url.path, alias: alias)
                } else {
                    let tables = try DataSourceLoader.load(filename: source.filename, data: data)
                    try await session.database.load(tables)
                }
            } catch {
                session.problems.append("\(source.filename) could not be loaded: \(error).")
            }
        }

        if let summaries = try? await session.database.schema() {
            session.schemaText = DataAnalysis.schemaText(summaries)
        }
        sessions[conversationID] = session
    }

    private func writeTemporaryCopy(of source: Source, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("velachat-analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(source.attachmentID.uuidString).sqlite")
        try data.write(to: url)
        return url
    }
}

/// One `query_data` call's outcome, shared by the model-facing text and
/// the transcript card so the two can never describe different results.
struct DataQueryOutcome: Sendable, Identifiable {
    let id = UUID()
    var sql: String
    var columns: [String] = []
    var rows: [[DataValue]] = []
    var truncated = false
    var chart: DataAnalysis.ChartSpec?
    /// A chart spec that named a column the result doesn't have. The rows
    /// are still good; only the drawing was refused.
    var chartProblem: String?
    var error: String?

    /// What goes back to the model.
    var toolResultText: String {
        if let error {
            return "Error: \(error)"
        }
        var text = DataAnalysis.resultText(columns: columns, rows: rows, truncated: truncated)
        if let chartProblem {
            text += "\nThe chart was not drawn: \(chartProblem)"
        } else if chart != nil {
            text += "\nThe chart is rendered under the table in the transcript."
        }
        return text
    }
}
