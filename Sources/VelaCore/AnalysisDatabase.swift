import Foundation
import SQLite3

/// §9.2 — one ephemeral in-memory SQLite database per analysis session.
/// Loaded sources become tables here, the model writes SQL against them,
/// and the whole thing is disposed when the session ends. These are query
/// scratch databases, not stores: nothing here is meant to survive, which
/// is exactly why `:memory:` is the right handle and `MemoryStore`'s
/// on-disk discipline is not.
///
/// The §9.2 safety invariant lives here, not in a prompt: the connection
/// runs under an `sqlite3_set_authorizer` callback that permits reads and
/// nothing else. A model that emits `DELETE`, `ATTACH`, `PRAGMA` or
/// `load_extension` is refused by the engine before the statement is even
/// prepared — the tool description says the tool is read-only, and this is
/// what makes that true.
public actor AnalysisDatabase {

    public struct QueryResult: Sendable, Equatable {
        public var columns: [String]
        public var rows: [[DataValue]]
        /// True when the row cap cut the result short, so the model can be
        /// told to aggregate rather than believing it saw everything.
        public var truncated: Bool

        public init(columns: [String], rows: [[DataValue]], truncated: Bool) {
            self.columns = columns
            self.rows = rows
            self.truncated = truncated
        }
    }

    /// What the model is handed when data is attached: structure and a few
    /// sample rows, never the pile itself.
    public struct TableSummary: Sendable, Equatable {
        public var name: String
        public var columns: [DataColumn]
        public var rowCount: Int
        public var sampleRows: [[DataValue]]

        public init(name: String, columns: [DataColumn], rowCount: Int, sampleRows: [[DataValue]]) {
            self.name = name
            self.columns = columns
            self.rowCount = rowCount
            self.sampleRows = sampleRows
        }
    }

    public struct DatabaseError: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    private var handle: OpaquePointer?
    /// Read by the progress handler on the SQLite thread while a query
    /// runs. Heap-allocated because a C callback needs a stable address,
    /// and owned here so its lifetime is the connection's.
    private let deadline = UnsafeMutablePointer<Double>.allocate(capacity: 1)

    public init() throws {
        deadline.initialize(to: .greatestFiniteMagnitude)
        var database: OpaquePointer?
        // SQLITE_OPEN_URI so a source file can be attached with ?mode=ro —
        // the user's own database must be unopenable for writing, not just
        // unwritten.
        guard sqlite3_open_v2(":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database else {
            deadline.deallocate()
            throw DatabaseError("could not open the in-memory analysis database")
        }
        handle = database
        sqlite3_progress_handler(database, 10_000, { context in
            guard let context else { return 0 }
            let deadline = context.assumingMemoryBound(to: Double.self).pointee
            // Non-zero interrupts the statement: a pathological query costs
            // the session a bounded wait, never the whole reply.
            return Date.timeIntervalSinceReferenceDate > deadline ? 1 : 0
        }, UnsafeMutableRawPointer(deadline))
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
        deadline.deallocate()
    }

    public func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    // MARK: - Loading

    /// Creates one table per loaded source and fills it in a single
    /// transaction — the same prepare/bind/step/reset discipline
    /// `MemoryStore` uses, which is the only SQLite idiom this codebase
    /// has and the right one to stay inside.
    public func load(_ tables: [DataTable]) throws {
        guard let handle else { throw DatabaseError("the analysis database is closed") }
        // Loading is the host's own work, done before any model SQL runs,
        // so the read-only authorizer is lifted around it — leaving it on
        // would deny the CREATE TABLE.
        try withHostAccess {
            try loadTables(tables, handle: handle)
        }
    }

    private func loadTables(_ tables: [DataTable], handle: OpaquePointer) throws {
        for table in tables {
            let columnDefinitions = table.columns
                .map { "\(quoted($0.name)) \($0.affinity.rawValue)" }
                .joined(separator: ", ")
            guard !table.columns.isEmpty else {
                throw DatabaseError("\(table.name) has no columns to load")
            }
            try execute("DROP TABLE IF EXISTS \(quoted(table.name));")
            try execute("CREATE TABLE \(quoted(table.name)) (\(columnDefinitions));")

            let placeholders = Array(repeating: "?", count: table.columns.count).joined(separator: ", ")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "INSERT INTO \(quoted(table.name)) VALUES (\(placeholders));",
                -1, &statement, nil
            ) == SQLITE_OK, let statement else {
                throw DatabaseError("could not prepare the insert for \(table.name): \(lastErrorMessage())")
            }
            defer { sqlite3_finalize(statement) }

            try execute("BEGIN TRANSACTION;")
            var inserted = 0
            for row in table.rows {
                for index in 0..<table.columns.count {
                    let value = index < row.count ? row[index] : .null
                    bind(value, to: statement, at: Int32(index + 1))
                }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    let message = lastErrorMessage()
                    try? execute("ROLLBACK;")
                    throw DatabaseError("could not load a row of \(table.name): \(message)")
                }
                sqlite3_reset(statement)
                inserted += 1
                if inserted >= Limits.dataMaxRowsLoaded { break }
            }
            try execute("COMMIT;")
        }
    }

    /// A SQLite source is attached, not copied: the user's own file stays
    /// on disk, opened read-only through a URI, and its tables are
    /// queryable as `alias.table`. The authorizer denies the model its own
    /// ATTACH, so this is the only route in and the host controls it.
    public func attachSQLiteFile(at path: String, alias: String) throws {
        guard let handle else { throw DatabaseError("the analysis database is closed") }
        try withHostAccess {
            try attach(path: path, alias: alias, handle: handle)
        }
    }

    private func attach(path: String, alias: String, handle: OpaquePointer) throws {
        var escapedPath = ""
        for character in path.unicodeScalars {
            // A URI filename needs percent-encoding for the characters that
            // are structural in a URI; everything else can go through as-is.
            if character == "?" || character == "#" || character == "%" {
                escapedPath += String(format: "%%%02X", character.value)
            } else {
                escapedPath.unicodeScalars.append(character)
            }
        }
        let uri = "file:\(escapedPath)?mode=ro"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "ATTACH DATABASE ? AS \(quoted(alias));", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DatabaseError("could not prepare the attach: \(lastErrorMessage())")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, uri, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError("could not open that SQLite file: \(lastErrorMessage())")
        }
    }

    // MARK: - Schema

    /// Every user table in the main database and in any attached source,
    /// with its columns, row count, and a few real rows. This is the
    /// data-analysis analogue of handing over structure instead of the
    /// whole pile.
    public func schema(sampleRows: Int = Limits.dataSampleRows) throws -> [TableSummary] {
        guard let handle else { throw DatabaseError("the analysis database is closed") }
        // Introspection is PRAGMA-shaped, and PRAGMA is exactly what the
        // read-only authorizer denies — so the whole walk runs as the host,
        // once, rather than fighting the guard table by table.
        return try withHostAccess {
            try tableSummaries(sampleRows: sampleRows, handle: handle)
        }
    }

    private func tableSummaries(sampleRows: Int, handle: OpaquePointer) throws -> [TableSummary] {
        var summaries: [TableSummary] = []
        for schemaName in try attachedSchemas() {
            let qualifier = schemaName == "main" ? "" : "\(quoted(schemaName))."
            let tableNames = try queryStrings(
                "SELECT name FROM \(quoted(schemaName)).sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name;"
            )
            for table in tableNames {
                var columns: [DataColumn] = []
                var infoStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "PRAGMA \(quoted(schemaName)).table_info(\(quoted(table)));", -1, &infoStatement, nil) == SQLITE_OK,
                      let infoStatement else { continue }
                while sqlite3_step(infoStatement) == SQLITE_ROW {
                    let name = text(infoStatement, 1) ?? ""
                    let declared = (text(infoStatement, 2) ?? "TEXT").uppercased()
                    let affinity: ColumnAffinity = declared.contains("INT")
                        ? .integer
                        : (declared.contains("REAL") || declared.contains("FLOA") || declared.contains("DOUB") || declared.contains("NUM") ? .real : .text)
                    columns.append(DataColumn(name: name, affinity: affinity))
                }
                sqlite3_finalize(infoStatement)
                guard !columns.isEmpty else { continue }

                let qualifiedName = qualifier + quoted(table)
                let count = try queryStrings("SELECT COUNT(*) FROM \(qualifiedName);").first.flatMap { Int($0) } ?? 0
                let samples = sampleRows > 0
                    ? try run("SELECT * FROM \(qualifiedName) LIMIT \(sampleRows);", rowLimit: sampleRows, timeout: Limits.dataQueryTimeout).rows
                    : []
                summaries.append(TableSummary(
                    name: schemaName == "main" ? table : "\(schemaName).\(table)",
                    columns: columns,
                    rowCount: count,
                    sampleRows: samples
                ))
            }
        }
        return summaries
    }

    // MARK: - Query

    /// The model's route in: one statement, read-only, capped, and bounded
    /// in time. Every path that reaches this installs the authorizer first
    /// — `run` below is the shared machinery and does not decide policy.
    @discardableResult
    public func query(
        _ sql: String,
        rowLimit: Int = Limits.dataQueryRows,
        timeout: TimeInterval = Limits.dataQueryTimeout
    ) throws -> QueryResult {
        installReadOnlyAuthorizer()
        return try run(sql, rowLimit: rowLimit, timeout: timeout)
    }

    private func run(_ sql: String, rowLimit: Int, timeout: TimeInterval) throws -> QueryResult {
        guard let handle else { throw DatabaseError("the analysis database is closed") }
        deadline.pointee = Date.timeIntervalSinceReferenceDate + timeout
        defer { deadline.pointee = .greatestFiniteMagnitude }

        var statement: OpaquePointer?
        // The tail pointer is only valid while the SQL buffer is, so what
        // survives the closure is the answer, not the pointer.
        var hasTrailingStatement = false
        let prepared = SQLiteText.withUTF8(sql) { pointer, length in
            var tail: UnsafePointer<CChar>?
            let status = sqlite3_prepare_v2(handle, pointer, length, &statement, &tail)
            if let tail {
                hasTrailingStatement = !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return status
        }
        guard prepared == SQLITE_OK, let statement else {
            throw DatabaseError(prepareErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        // One statement per call, enforced: anything after the first
        // semicolon is a second statement, which is how "SELECT 1; DROP
        // TABLE t" gets past a read-only *intention*. (Only the first would
        // ever run here — but a refusal the model can read beats silently
        // ignoring half of what it asked for.)
        if hasTrailingStatement {
            throw DatabaseError("run one statement per call — this query has more than one.")
        }

        let columnCount = Int(sqlite3_column_count(statement))
        var columns: [String] = []
        for index in 0..<columnCount {
            columns.append(sqlite3_column_name(statement, Int32(index)).map { String(cString: $0) } ?? "column_\(index + 1)")
        }

        var rows: [[DataValue]] = []
        var truncated = false
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                if step == SQLITE_INTERRUPT {
                    throw DatabaseError("that query was still running after \(Int(timeout)) seconds and was stopped. Narrow it — add a WHERE clause, or aggregate instead of scanning every row.")
                }
                throw DatabaseError(String(cString: sqlite3_errmsg(handle)))
            }
            if rows.count >= rowLimit {
                truncated = true
                break
            }
            var row: [DataValue] = []
            for index in 0..<columnCount {
                row.append(columnValue(statement, Int32(index)))
            }
            rows.append(row)
        }
        return QueryResult(columns: columns, rows: rows, truncated: truncated)
    }

    // MARK: - Read-only enforcement

    /// Runs the host's own work — loading, attaching, introspection — with
    /// the authorizer lifted, and puts it back afterwards no matter how the
    /// body exits. One place to reason about, rather than a lift-and-restore
    /// pair in every helper (which is how an inner restore ended up denying
    /// the PRAGMA of the *next* iteration).
    private func withHostAccess<T>(_ body: () throws -> T) rethrows -> T {
        if let handle { sqlite3_set_authorizer(handle, nil, nil) }
        defer { installReadOnlyAuthorizer() }
        return try body()
    }

    private func installReadOnlyAuthorizer() {
        guard let handle else { return }
        sqlite3_set_authorizer(handle, { _, action, argument1, argument2, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE:
                return SQLITE_OK
            case SQLITE_FUNCTION:
                // arg2 carries the function name for this action; SQLite's
                // own extension loader is the one function that turns a
                // read-only connection into an arbitrary-code one.
                let name = argument2.map { String(cString: $0).lowercased() } ?? ""
                return name == "load_extension" ? SQLITE_DENY : SQLITE_OK
            default:
                _ = argument1
                return SQLITE_DENY
            }
        }, nil)
    }

    // MARK: - SQLite plumbing

    private func execute(_ sql: String) throws {
        guard let handle else { throw DatabaseError("the analysis database is closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw DatabaseError(message)
        }
    }

    /// Callable only from inside `withHostAccess` — `database_list` is a
    /// PRAGMA, which the model-facing authorizer denies.
    private func attachedSchemas() throws -> [String] {
        guard let handle else { throw DatabaseError("the analysis database is closed") }
        var names: [String] = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA database_list;", -1, &statement, nil) == SQLITE_OK, let statement else {
            return ["main"]
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1), name != "temp" { names.append(name) }
        }
        return names.isEmpty ? ["main"] : names
    }

    private func queryStrings(_ sql: String) throws -> [String] {
        guard let handle else { throw DatabaseError("the analysis database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(text(statement, 0) ?? "")
        }
        return values
    }

    private func bind(_ value: DataValue, to statement: OpaquePointer, at index: Int32) {
        switch value {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer(let number):
            sqlite3_bind_int64(statement, index, number)
        case .number(let number):
            sqlite3_bind_double(statement, index, number)
        case .text(let text):
            // SQLITE_TRANSIENT: SQLite copies the bytes, since the Swift
            // string's storage does not outlive this call.
            sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func columnValue(_ statement: OpaquePointer, _ index: Int32) -> DataValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .number(sqlite3_column_double(statement, index))
        default:
            guard let pointer = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: pointer))
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func lastErrorMessage() -> String {
        guard let handle else { return "the analysis database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    /// A prepare that the authorizer refused says "not authorized", which
    /// tells a model nothing about what to do instead. This is the one
    /// place where a better sentence is worth writing by hand.
    private func prepareErrorMessage() -> String {
        let raw = lastErrorMessage()
        if raw.lowercased().contains("not authorized") {
            return "that statement was refused: this tool runs read-only SELECT queries against the attached data. Nothing can be modified, created, attached, or dropped."
        }
        return raw
    }

    private func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// `sqlite3_prepare_v2` needs the statement's byte length to report the
/// unconsumed tail; Swift's String bridging hides it, so this hands over
/// both at once.
private enum SQLiteText {
    static func withUTF8<T>(_ string: String, _ body: (UnsafePointer<CChar>, Int32) -> T) -> T {
        // A nul-terminated copy: `withUTF8` can hand back a nil base
        // address for an empty string, and SQLite must never see one.
        var bytes = Array(string.utf8CString)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!, Int32(buffer.count - 1))
        }
    }
}
