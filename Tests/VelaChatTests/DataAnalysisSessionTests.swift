import XCTest
import SQLite3
@testable import VelaChat
@testable import VelaCore

/// §9.2 — the layer between the tool and the database: what gets loaded,
/// what gets re-read (nothing, once loaded), and what a `query_data` call
/// hands back to both the model and the transcript card.
final class DataAnalysisSessionTests: XCTestCase {

    /// Counts byte fetches per attachment, so "a loaded file is never
    /// re-read" is an assertion rather than an intention.
    private final class FetchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [UUID: Int] = [:]
        func note(_ id: UUID) {
            lock.lock(); counts[id, default: 0] += 1; lock.unlock()
        }
        func count(_ id: UUID) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[id] ?? 0
        }
    }

    private let csvID = UUID()
    private let sqliteID = UUID()
    private let brokenID = UUID()

    private var fixturePath = ""

    override func setUp() {
        super.setUp()
        fixturePath = NSTemporaryDirectory() + "vela-session-fixture-\(UUID().uuidString).sqlite"
        var fixture: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixturePath, &fixture), SQLITE_OK)
        sqlite3_exec(fixture, "CREATE TABLE readings (sensor TEXT, value INTEGER);", nil, nil, nil)
        sqlite3_exec(fixture, "INSERT INTO readings VALUES ('a', 1), ('b', 2), ('c', 9);", nil, nil, nil)
        sqlite3_close(fixture)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: fixturePath)
        super.tearDown()
    }

    private var sources: [DataAnalysisSessions.Source] {
        [
            .init(attachmentID: csvID, filename: "sales.csv"),
            .init(attachmentID: sqliteID, filename: "sensors.sqlite"),
            .init(attachmentID: brokenID, filename: "broken.xlsx"),
        ]
    }

    private func provider(counting fetches: FetchCounter) throws -> DataAnalysisSessions.ByteProvider {
        let csv = Data("region,revenue\nNorth,1250\nSouth,980\nEast,410\n".utf8)
        let sqlite = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let broken = Data("<html>not a spreadsheet</html>".utf8)
        let csvID = csvID, sqliteID = sqliteID, brokenID = brokenID
        return { id in
            fetches.note(id)
            switch id {
            case csvID: return csv
            case sqliteID: return sqlite
            case brokenID: return broken
            default: return nil
            }
        }
    }

    func testSchemaLoadsEverySourceOnceAndNamesWhatFailed() async throws {
        let fetches = FetchCounter()
        let bytes = try provider(counting: fetches)
        let sessions = DataAnalysisSessions()
        let conversationID = UUID()

        let schema = await sessions.schemaText(for: conversationID, sources: sources, bytes: bytes)
        XCTAssertTrue(schema.contains("TABLE sales"))
        XCTAssertTrue(schema.contains("revenue INTEGER"))
        // An attached SQLite file's tables are qualified by their alias, so
        // the model writes `sensors.readings` and it resolves.
        XCTAssertTrue(schema.contains("sensors.readings"))
        // A file that can't be read is named. Silently dropping it would
        // leave the user's attachment invisible to everyone.
        XCTAssertTrue(schema.contains("broken.xlsx could not be loaded"))
        XCTAssertEqual(fetches.count(csvID), 1)

        // A second turn loads nothing and re-reads nothing.
        let again = await sessions.schemaText(for: conversationID, sources: sources, bytes: bytes)
        XCTAssertEqual(again, schema)
        XCTAssertEqual(fetches.count(csvID), 1)
        XCTAssertEqual(fetches.count(sqliteID), 1)

        await sessions.discard(conversationID: conversationID)
    }

    func testQueryReturnsRowsChartAndModelText() async throws {
        let sessions = DataAnalysisSessions()
        let conversationID = UUID()
        let bytes = try provider(counting: FetchCounter())

        let outcome = await sessions.query(
            conversationID: conversationID,
            sources: sources,
            bytes: bytes,
            sql: "SELECT region, revenue FROM sales ORDER BY revenue DESC",
            chartJSON: #"{"type":"bar","x":{"field":"region"},"y":{"field":"revenue"},"sort":"y_desc"}"#
        )
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.columns, ["region", "revenue"])
        XCTAssertEqual(outcome.rows.count, 3)
        XCTAssertEqual(outcome.chart?.type, .bar)
        XCTAssertTrue(outcome.toolResultText.contains("3 rows."))
        XCTAssertTrue(outcome.toolResultText.contains("chart is rendered"))

        let attached = await sessions.query(
            conversationID: conversationID,
            sources: sources,
            bytes: bytes,
            sql: "SELECT COUNT(*) AS n, MAX(value) AS top FROM sensors.readings",
            chartJSON: nil
        )
        XCTAssertEqual(attached.rows.first?.first, .integer(3))
        XCTAssertEqual(attached.rows.first?.last, .integer(9))

        await sessions.discard(conversationID: conversationID)
    }

    func testInvalidChartSpecKeepsTheRows() async throws {
        let sessions = DataAnalysisSessions()
        let conversationID = UUID()
        let bytes = try provider(counting: FetchCounter())

        let outcome = await sessions.query(
            conversationID: conversationID,
            sources: sources,
            bytes: bytes,
            sql: "SELECT region, revenue FROM sales",
            chartJSON: #"{"type":"bar","x":{"field":"quarter"},"y":{"field":"revenue"}}"#
        )
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.rows.count, 3)
        XCTAssertNil(outcome.chart)
        XCTAssertTrue(outcome.chartProblem?.contains("region") ?? false)
        XCTAssertTrue(outcome.toolResultText.contains("chart was not drawn"))

        await sessions.discard(conversationID: conversationID)
    }

    func testWriteAttemptReachesTheModelAsAnError() async throws {
        let sessions = DataAnalysisSessions()
        let conversationID = UUID()
        let bytes = try provider(counting: FetchCounter())

        let outcome = await sessions.query(
            conversationID: conversationID,
            sources: sources,
            bytes: bytes,
            sql: "DELETE FROM sales",
            chartJSON: nil
        )
        XCTAssertNotNil(outcome.error)
        XCTAssertTrue(outcome.toolResultText.hasPrefix("Error:"))

        await sessions.discard(conversationID: conversationID)
    }
}
