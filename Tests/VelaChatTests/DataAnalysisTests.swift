import XCTest
import SQLite3
@testable import VelaCore

/// §9.2 — the loaders, the read-only enforcement, and the chart contract.
///
/// The acceptance bar the plan names: attach a CSV, run an aggregate
/// SELECT, and have a `DELETE`/`ATTACH` attempt refused at the engine.
/// Everything decidable is tested here without a view or a database file
/// on the path — the same seam discipline as the bridge and the emitters.
final class DataAnalysisTests: XCTestCase {

    // MARK: - Delimited text

    func testCSVParsesQuotedFieldsAndTypesColumns() throws {
        let csv = """
        Region,Revenue,Notes
        North,1250,"Strong, steady"
        South,980.5,"Line one
        line two"
        East,,missing
        """
        let tables = try DataSourceLoader.load(filename: "sales report.csv", data: Data(csv.utf8))
        XCTAssertEqual(tables.count, 1)
        let table = tables[0]
        XCTAssertEqual(table.name, "sales_report")
        XCTAssertEqual(table.columns.map(\.name), ["Region", "Revenue", "Notes"])
        XCTAssertEqual(table.columns.map(\.affinity), [.text, .real, .text])
        XCTAssertEqual(table.rows.count, 3)
        XCTAssertEqual(table.rows[0][2], .text("Strong, steady"))
        XCTAssertEqual(table.rows[1][2], .text("Line one\nline two"))
        // An empty cell is NULL, never 0 — a missing measurement and a
        // measured zero are different facts.
        XCTAssertEqual(table.rows[2][1], .null)
    }

    func testCRLFFileDoesNotSwallowItsLineBreaks() throws {
        // "\r\n" is a single Character in Swift, so a parser matching on a
        // bare "\r" silently folds every row into one field.
        let table = try DataSourceLoader.load(filename: "crlf.csv", data: Data("a,b\r\n1,2\r\n3,4\r\n".utf8))[0]
        XCTAssertEqual(table.columns.map(\.name), ["a", "b"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.columns.map(\.affinity), [.integer, .integer])
    }

    func testSemicolonDelimiterIsSniffed() throws {
        let table = try DataSourceLoader.load(filename: "euro.csv", data: Data("name;count\nab;3\ncd;4\n".utf8))[0]
        XCTAssertEqual(table.columns.map(\.name), ["name", "count"])
        XCTAssertEqual(table.rows.count, 2)
    }

    func testAllNumericFirstRowIsDataNotAHeader() throws {
        let table = try DataSourceLoader.load(filename: "nums.csv", data: Data("1,2\n3,4\n".utf8))[0]
        XCTAssertEqual(table.columns.map(\.name), ["column_1", "column_2"])
        XCTAssertEqual(table.rows.count, 2)
    }

    func testHeadersBecomeUsableIdentifiers() throws {
        let table = try DataSourceLoader.load(filename: "awkward.csv", data: Data("Total ($),2026,,Total ($)\nx,1,2,3\n".utf8))[0]
        XCTAssertEqual(table.columns.map(\.name), ["Total", "n_2026", "column_3", "Total_2"])
    }

    func testMixedColumnStaysTextRatherThanDroppingValues() {
        XCTAssertEqual(ColumnAffinity.infer(from: ["1", "2", "n/a"]), .text)
        XCTAssertEqual(ColumnAffinity.infer(from: ["1", "", "3"]), .integer)
        XCTAssertEqual(ColumnAffinity.infer(from: ["1", "2.5"]), .real)
        XCTAssertEqual(ColumnAffinity.infer(from: ["", ""]), .text)
    }

    // MARK: - JSON

    func testJSONFlattensOneLevelAndUnionsKeys() throws {
        let json = """
        [
          {"id": 1, "user": {"name": "Ada", "city": "Oslo"}, "score": 9.5, "tags": ["a","b"], "active": true},
          {"id": 2, "user": {"name": "Bo"}, "score": 7}
        ]
        """
        let table = try DataSourceLoader.load(filename: "people.json", data: Data(json.utf8))[0]
        XCTAssertTrue(table.columns.map(\.name).contains("user_name"))
        XCTAssertTrue(table.columns.map(\.name).contains("user_city"))
        XCTAssertEqual(table.rows.count, 2)

        let cityIndex = try XCTUnwrap(table.columns.firstIndex { $0.name == "user_city" })
        XCTAssertEqual(table.rows[1][cityIndex], .null)
        let tagsIndex = try XCTUnwrap(table.columns.firstIndex { $0.name == "tags" })
        XCTAssertEqual(table.rows[0][tagsIndex], .text("[\"a\",\"b\"]"))
        // A JSON bool is 0/1, not the string "true": SQL comparisons on it
        // have to work.
        let activeIndex = try XCTUnwrap(table.columns.firstIndex { $0.name == "active" })
        XCTAssertEqual(table.rows[0][activeIndex], .integer(1))
        let scoreIndex = try XCTUnwrap(table.columns.firstIndex { $0.name == "score" })
        XCTAssertEqual(table.columns[scoreIndex].affinity, .real)
    }

    func testLineDelimitedAndWrappedJSONLoad() throws {
        let ndjson = try DataSourceLoader.load(filename: "events.jsonl", data: Data("{\"a\":1}\n{\"a\":2}\n".utf8))[0]
        XCTAssertEqual(ndjson.rows.count, 2)

        let wrapped = try DataSourceLoader.load(filename: "wrapped.json", data: Data("{\"rows\":[{\"a\":1},{\"a\":2}]}".utf8))[0]
        XCTAssertEqual(wrapped.name, "wrapped")
        XCTAssertEqual(wrapped.rows.count, 2)
    }

    // MARK: - xlsx

    func testXLSXRoundTripsThroughTheEmitter() throws {
        let workbook = XLSXDocument(sheets: [
            XLSXDocument.Sheet(name: "Q3", rows: [
                [.text("Region"), .text("Revenue"), .text("Share")],
                [.text("North"), .number(1250), .number(0.42)],
                [.text("South"), .number(980), .number(0.31)],
            ]),
            XLSXDocument.Sheet(name: "Notes", rows: [
                [.text("Note")],
                [.text("Q3 closed early")],
            ]),
        ])
        let data = try workbook.makeData()

        let sheets = try XLSXReader.read(data)
        XCTAssertEqual(sheets.count, 2)
        XCTAssertEqual(sheets[0].name, "Q3")
        XCTAssertEqual(sheets[0].rows.count, 3)
        XCTAssertEqual(sheets[0].rows[1][0], .text("North"))
        XCTAssertEqual(sheets[0].rows[1][1], .integer(1250))
        XCTAssertEqual(sheets[0].rows[2][2], .number(0.31))

        let tables = try DataSourceLoader.load(filename: "quarter.xlsx", data: data)
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables[0].name, "Q3")
        XCTAssertEqual(tables[0].columns.map(\.name), ["Region", "Revenue", "Share"])
        XCTAssertEqual(tables[0].columns.map(\.affinity), [.text, .integer, .real])
        XCTAssertEqual(tables[0].rows.count, 2)

        let single = try DataSourceLoader.load(
            filename: "one sheet.xlsx",
            data: try XLSXDocument(sheetName: "Only", rows: [[.text("a")], [.number(1)]]).makeData()
        )
        XCTAssertEqual(single[0].name, "one_sheet")
    }

    func testExcelSerialDatesIncludingTheLeapYearBug() {
        XCTAssertEqual(XLSXReader.isoDate(fromExcelSerial: 1), "1900-01-01")
        XCTAssertEqual(XLSXReader.isoDate(fromExcelSerial: 59), "1900-02-28")
        // 60 is Excel's phantom 29 February 1900; every serial past it is
        // shifted by that non-existent day.
        XCTAssertEqual(XLSXReader.isoDate(fromExcelSerial: 61), "1900-03-01")
        XCTAssertEqual(XLSXReader.isoDate(fromExcelSerial: 45_000), "2023-03-15")
        XCTAssertEqual(XLSXReader.isoDate(fromExcelSerial: 45_000.5), "2023-03-15 12:00:00")
    }

    func testColumnReferencesDecode() {
        XCTAssertEqual(XLSXReader.columnIndex(fromReference: "A1"), 0)
        XCTAssertEqual(XLSXReader.columnIndex(fromReference: "Z9"), 25)
        XCTAssertEqual(XLSXReader.columnIndex(fromReference: "AA10"), 26)
        XCTAssertEqual(XLSXReader.columnIndex(fromReference: "BC12"), 54)
        XCTAssertNil(XLSXReader.columnIndex(fromReference: "12"))
    }

    // MARK: - The database

    private func loadedDatabase() async throws -> AnalysisDatabase {
        let csv = "region,revenue\nNorth,1250\nSouth,980.5\nEast,\n"
        let tables = try DataSourceLoader.load(filename: "sales.csv", data: Data(csv.utf8))
        let database = try AnalysisDatabase()
        try await database.load(tables)
        return database
    }

    func testSchemaReportsColumnsRowCountsAndSamples() async throws {
        let database = try await loadedDatabase()
        let schema = try await database.schema()
        XCTAssertEqual(schema.count, 1)
        let table = try XCTUnwrap(schema.first)
        XCTAssertEqual(table.name, "sales")
        XCTAssertEqual(table.rowCount, 3)
        XCTAssertEqual(table.columns.map(\.name), ["region", "revenue"])
        XCTAssertEqual(table.columns.map(\.affinity), [.text, .real])
        XCTAssertEqual(table.sampleRows.count, Limits.dataSampleRows)

        let text = DataAnalysis.schemaText(schema)
        XCTAssertTrue(text.contains("TABLE sales"))
        XCTAssertTrue(text.contains("revenue REAL"))
    }

    func testAggregateQueryReturnsNamedColumns() async throws {
        let database = try await loadedDatabase()
        let result = try await database.query("SELECT SUM(revenue) AS total, COUNT(*) AS n FROM sales;")
        XCTAssertEqual(result.columns, ["total", "n"])
        XCTAssertEqual(result.rows[0][0], .number(2230.5))
        XCTAssertEqual(result.rows[0][1], .integer(3))
    }

    /// The §9.2 safety invariant: refusal happens in the engine, so it
    /// holds no matter what the tool description promised.
    func testWritesAreRefusedByTheAuthorizer() async throws {
        let database = try await loadedDatabase()
        let refused = [
            "DELETE FROM sales;",
            "UPDATE sales SET region = 'x';",
            "INSERT INTO sales VALUES ('x', 1);",
            "DROP TABLE sales;",
            "CREATE TABLE t (a INT);",
            "ATTACH DATABASE '/tmp/x.db' AS other;",
            "PRAGMA table_info(sales);",
            "SELECT load_extension('/tmp/evil.dylib');",
            "SELECT 1; DROP TABLE sales;",
        ]
        for sql in refused {
            do {
                _ = try await database.query(sql)
                XCTFail("\(sql) should have been refused")
            } catch {
                XCTAssertFalse("\(error)".isEmpty)
            }
        }
        // And nothing the refusals attempted actually happened.
        let count = try await database.query("SELECT COUNT(*) FROM sales;")
        XCTAssertEqual(count.rows[0][0], .integer(3))
    }

    func testRowCapTruncatesAndSaysSo() async throws {
        let database = try await loadedDatabase()
        let result = try await database.query(
            "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 1000) SELECT x FROM n;",
            rowLimit: 10
        )
        XCTAssertEqual(result.rows.count, 10)
        XCTAssertTrue(result.truncated)
    }

    func testSQLiteSourceAttachesReadOnly() async throws {
        let path = NSTemporaryDirectory() + "vela-analysis-test-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var fixture: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &fixture), SQLITE_OK)
        sqlite3_exec(fixture, "CREATE TABLE readings (sensor TEXT, value INTEGER);", nil, nil, nil)
        sqlite3_exec(fixture, "INSERT INTO readings VALUES ('a', 1), ('b', 2);", nil, nil, nil)
        sqlite3_close(fixture)

        let database = try AnalysisDatabase()
        try await database.attachSQLiteFile(at: path, alias: "src")
        let schema = try await database.schema()
        XCTAssertTrue(schema.contains { $0.name == "src.readings" })

        let rows = try await database.query("SELECT sensor, value FROM src.readings ORDER BY value;")
        XCTAssertEqual(rows.rows.count, 2)
        XCTAssertEqual(rows.rows[0][0], .text("a"))

        do {
            _ = try await database.query("DELETE FROM src.readings;")
            XCTFail("a write to the attached source file should have been refused")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    // MARK: - Chart contract

    func testChartSpecValidatesAgainstTheResultColumns() throws {
        let columns = ["region", "revenue", "quarter"]
        let spec = try DataAnalysis.chartSpec(
            from: [
                "type": "bar",
                "title": "Revenue by region",
                "x": ["field": "region", "label": "Region"],
                "y": ["field": "revenue"],
                "series": "quarter",
                "sort": "y_desc",
                "limit": 5,
            ],
            resultColumns: columns
        )
        XCTAssertEqual(spec.type, .bar)
        XCTAssertEqual(spec.xField, "region")
        XCTAssertEqual(spec.xLabel, "Region")
        XCTAssertEqual(spec.yField, "revenue")
        XCTAssertEqual(spec.series, "quarter")
        XCTAssertEqual(spec.sort, .yDescending)
        XCTAssertEqual(spec.limit, 5)

        // The shorthand a model reaches for when the object feels like
        // ceremony.
        let shorthand = try DataAnalysis.chartSpec(
            from: ["type": "line", "x": "quarter", "y": "revenue"],
            resultColumns: columns
        )
        XCTAssertEqual(shorthand.xField, "quarter")
    }

    func testChartSpecRefusesColumnsTheResultDoesNotHave() {
        let columns = ["region", "revenue"]
        XCTAssertThrowsError(try DataAnalysis.chartSpec(from: ["type": "bar", "x": "quarter", "y": "revenue"], resultColumns: columns)) { error in
            // The message names the available columns, so the next call can
            // fix the spec instead of guessing again.
            XCTAssertTrue("\(error)".contains("region"))
        }
        XCTAssertThrowsError(try DataAnalysis.chartSpec(from: ["type": "pie", "x": "region", "y": "revenue"], resultColumns: columns))
        XCTAssertThrowsError(try DataAnalysis.chartSpec(from: ["type": "bar", "y": "revenue"], resultColumns: columns))
        XCTAssertThrowsError(try DataAnalysis.chartSpec(from: ["type": "bar", "x": "region", "y": "revenue", "series": "nope"], resultColumns: columns))
        XCTAssertThrowsError(try DataAnalysis.chartSpec(from: ["type": "bar", "x": "region", "y": "revenue", "sort": "sideways"], resultColumns: columns))
    }

    // MARK: - Result text

    func testResultTextAlignsColumnsAndReportsTruncation() {
        let text = DataAnalysis.resultText(
            columns: ["region", "revenue"],
            rows: [[.text("North"), .integer(1250)], [.text("South"), .null]],
            truncated: false
        )
        XCTAssertTrue(text.contains("region"))
        XCTAssertTrue(text.contains("NULL"))
        XCTAssertTrue(text.contains("2 rows."))

        let capped = DataAnalysis.resultText(
            columns: ["x"],
            rows: (0..<5).map { [.integer(Int64($0))] },
            truncated: true,
            rowLimit: 5
        )
        XCTAssertTrue(capped.contains("5-row cap"))

        XCTAssertEqual(DataAnalysis.resultText(columns: ["a"], rows: [], truncated: false), "No rows matched.")
    }
}
