import Foundation

/// §9.2 — every non-SQLite source becomes one or more `DataTable`s here,
/// which is the whole uniformity trick: the model writes SQL against
/// tables, and never has to know whether the user attached a CSV, a
/// spreadsheet, or a JSON dump.
///
/// Everything in this file is pure (bytes in, tables out) and lives in
/// VelaCore, so the parsing that decides what the model will be told about
/// the data is unit-tested without a database or a view on the path.
public enum DataSourceLoader {

    public enum Format: String, Sendable, CaseIterable {
        case csv, tsv, json, xlsx, sqlite

        /// The extensions that make a file worth loading as data. `.db` and
        /// `.sqlite3` are the same format under different habits.
        public static func detect(filename: String) -> Format? {
            switch (filename as NSString).pathExtension.lowercased() {
            case "csv": return .csv
            case "tsv", "tab": return .tsv
            case "json", "ndjson", "jsonl": return .json
            case "xlsx": return .xlsx
            case "sqlite", "sqlite3", "db": return .sqlite
            default: return nil
            }
        }
    }

    public struct LoadError: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// How many rows are sampled when deciding a column's type. Enough to
    /// see past a header-shaped first page, cheap enough to run on every
    /// column of a wide file.
    static let typeSampleRows = 200

    /// Loads one attached file into tables. SQLite sources are not handled
    /// here — they are attached to the analysis database directly rather
    /// than copied through this intermediate form (see `AnalysisDatabase`).
    public static func load(filename: String, data: Data) throws -> [DataTable] {
        guard let format = Format.detect(filename: filename) else {
            throw LoadError("\(filename) isn't a data file VelaChat can load (CSV, TSV, JSON, xlsx, or SQLite).")
        }
        let base = SQLIdentifier.sanitize(
            (filename as NSString).deletingPathExtension,
            fallback: "data"
        )
        switch format {
        case .csv, .tsv:
            guard let text = decodeText(data) else {
                throw LoadError("\(filename) isn't readable as text — it may be a different format than its extension says.")
            }
            let delimiter = format == .tsv ? "\t" : detectDelimiter(in: text)
            return [try loadDelimited(text: text, delimiter: delimiter, tableName: base)]
        case .json:
            return try loadJSON(data: data, tableName: base)
        case .xlsx:
            return try loadXLSX(data: data, tableName: base)
        case .sqlite:
            throw LoadError("SQLite files are attached directly, not loaded through the table loader.")
        }
    }

    /// UTF-8 first, then the two encodings spreadsheets actually export
    /// when they aren't UTF-8. A CSV that fails all three is genuinely not
    /// text and should say so rather than loading as mojibake.
    static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Delimited text

    /// Sniffs the delimiter from the first line rather than assuming a
    /// comma: semicolon-separated exports are the normal CSV dialect
    /// wherever the decimal separator is a comma, and they arrive named
    /// ".csv" like everything else.
    static func detectDelimiter(in text: String) -> String {
        let firstLine = text.prefix(while: { $0 != "\n" && $0 != "\r" })
        var best = ","
        var bestCount = 0
        for candidate: Character in [",", ";", "\t", "|"] {
            // Count outside quotes only — a quoted field full of commas
            // must not win the vote for a semicolon-delimited file.
            var count = 0
            var inQuotes = false
            for character in firstLine {
                if character == "\"" { inQuotes.toggle() }
                if !inQuotes && character == candidate { count += 1 }
            }
            if count > bestCount {
                bestCount = count
                best = String(candidate)
            }
        }
        return best
    }

    static func loadDelimited(text: String, delimiter: String, tableName: String) throws -> DataTable {
        let records = parseDelimited(text: text, delimiter: Character(delimiter))
        guard let first = records.first else {
            throw LoadError("that file has no rows in it.")
        }
        // A first row that is entirely numeric is data, not a header —
        // naming a column "42" and then losing that row is the classic way
        // a loader quietly drops a record.
        let hasHeader = first.contains { Double($0.trimmingCharacters(in: .whitespaces)) == nil && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let width = records.map(\.count).max() ?? first.count
        let rawNames: [String] = hasHeader
            ? (0..<width).map { $0 < first.count ? first[$0] : "column_\($0 + 1)" }
            : (0..<width).map { "column_\($0 + 1)" }
        let names = SQLIdentifier.uniqued(rawNames, fallbackPrefix: "column_")
        let bodyRecords = hasHeader ? Array(records.dropFirst()) : records

        var columns: [DataColumn] = []
        for (index, name) in names.enumerated() {
            let samples = bodyRecords.prefix(typeSampleRows).map { index < $0.count ? $0[index] : "" }
            columns.append(DataColumn(name: name, affinity: ColumnAffinity.infer(from: samples)))
        }
        let rows = bodyRecords.map { record in
            (0..<names.count).map { index -> DataValue in
                let raw = index < record.count ? record[index] : ""
                return value(fromRaw: raw, affinity: columns[index].affinity)
            }
        }
        return DataTable(name: tableName, columns: columns, rows: rows)
    }

    /// RFC 4180 with the usual real-world tolerances: CRLF or LF, `""` as
    /// an escaped quote, embedded newlines inside quoted fields, and a
    /// trailing newline that does not invent an empty final record.
    static func parseDelimited(text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            record.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            // A blank line is not a record; a line of empty fields is.
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record = []
        }

        while true {
            let character: Character
            if let pending { character = pending } else if let next = iterator.next() { character = next } else { break }
            pending = nil

            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }

            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case delimiter:
                endField()
            case "\r\n", "\r", "\n":
                // "\r\n" is ONE Character in Swift — a grapheme cluster, not
                // two scalars — so a CRLF file never matches a bare "\r" and
                // its line breaks would land in the field instead.
                endRecord()
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }

    static func value(fromRaw raw: String, affinity: ColumnAffinity) -> DataValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .null }
        switch affinity {
        case .integer:
            return Int64(trimmed).map { DataValue.integer($0) } ?? .text(raw)
        case .real:
            return Double(trimmed).map { DataValue.number($0) } ?? .text(raw)
        case .text:
            return .text(raw)
        }
    }

    // MARK: - JSON

    static func loadJSON(data: Data, tableName: String) throws -> [DataTable] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            // Line-delimited JSON is common enough as a ".json" export that
            // failing on it would be a false negative.
            if let table = try? loadNDJSON(data: data, tableName: tableName) { return [table] }
            throw LoadError("that file isn't valid JSON: \(error.localizedDescription)")
        }
        if let array = object as? [Any] {
            return [try table(fromArray: array, named: tableName)]
        }
        if let dictionary = object as? [String: Any] {
            // {"rows": [...]} — one wrapped array is still one table, and
            // naming it after the file reads better than after the wrapper.
            let arrays = dictionary.compactMap { key, value -> (String, [Any])? in
                guard let array = value as? [Any], array.first is [String: Any] else { return nil }
                return (key, array)
            }.sorted { $0.0 < $1.0 }
            if arrays.count == 1 {
                return [try table(fromArray: arrays[0].1, named: tableName)]
            }
            if arrays.count > 1 {
                let names = SQLIdentifier.uniqued(arrays.map(\.0), fallbackPrefix: "table_")
                return try zip(names, arrays).map { try table(fromArray: $0.1.1, named: $0.0) }
            }
            // A single flat object is a one-row table.
            return [try table(fromArray: [dictionary], named: tableName)]
        }
        throw LoadError("that JSON is a single value, not a table of records.")
    }

    static func loadNDJSON(data: Data, tableName: String) throws -> DataTable {
        guard let text = decodeText(data) else { throw LoadError("that file isn't readable as text.") }
        var objects: [Any] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
                throw LoadError("that file is neither JSON nor line-delimited JSON.")
            }
            objects.append(object)
        }
        return try table(fromArray: objects, named: tableName)
    }

    static func table(fromArray array: [Any], named name: String) throws -> DataTable {
        guard !array.isEmpty else {
            throw LoadError("that JSON array is empty.")
        }
        // Column order follows first appearance across records — stable and
        // recognisable, where a sorted or hashed order would not be.
        var keys: [String] = []
        var seen: Set<String> = []
        var flattened: [[String: Any]] = []
        for element in array {
            guard let object = element as? [String: Any] else {
                throw LoadError("that JSON array holds values, not objects, so it has no columns.")
            }
            let flat = flatten(object)
            for key in flat.keys.sorted() where !seen.contains(key) {
                seen.insert(key)
                keys.append(key)
            }
            flattened.append(flat)
        }
        let names = SQLIdentifier.uniqued(keys, fallbackPrefix: "column_")
        var columnValues: [[DataValue]] = Array(repeating: [], count: keys.count)
        var rows: [[DataValue]] = []
        for record in flattened {
            var row: [DataValue] = []
            for (index, key) in keys.enumerated() {
                let value = jsonValue(record[key])
                row.append(value)
                if columnValues[index].count < typeSampleRows { columnValues[index].append(value) }
            }
            rows.append(row)
        }
        let columns = zip(names, columnValues).map {
            DataColumn(name: $0.0, affinity: ColumnAffinity.infer(fromValues: $0.1))
        }
        return DataTable(name: name, columns: columns, rows: rows)
    }

    /// One level of structure is worth keeping as columns
    /// (`user.name` → `user_name`); an array is kept as its JSON text so
    /// the value is still there to read, rather than silently dropped.
    static func flatten(_ object: [String: Any], prefix: String = "", depth: Int = 0) -> [String: Any] {
        var flat: [String: Any] = [:]
        for (key, value) in object {
            let name = prefix.isEmpty ? key : "\(prefix)_\(key)"
            if let nested = value as? [String: Any], depth < 2 {
                for (nestedKey, nestedValue) in flatten(nested, prefix: name, depth: depth + 1) {
                    flat[nestedKey] = nestedValue
                }
            } else {
                flat[name] = value
            }
        }
        return flat
    }

    static func jsonValue(_ raw: Any?) -> DataValue {
        switch raw {
        case nil, is NSNull:
            return .null
        case let text as String:
            return text.isEmpty ? .null : .text(text)
        case let number as NSNumber:
            // NSNumber erases Bool/Int/Double; the objCType is the only
            // honest way back, and a bool loaded as 0/1 is what SQL wants.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .integer(number.boolValue ? 1 : 0) }
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 9e15, String(cString: number.objCType) != "d" {
                return .integer(number.int64Value)
            }
            return .number(double)
        default:
            // Arrays and anything deeper than the flattening depth keep
            // their JSON so a query can still see them as text.
            if let data = try? JSONSerialization.data(withJSONObject: raw as Any, options: [.fragmentsAllowed]),
               let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
            return .null
        }
    }

    // MARK: - xlsx

    static func loadXLSX(data: Data, tableName: String) throws -> [DataTable] {
        let sheets: [XLSXReader.Sheet]
        do {
            sheets = try XLSXReader.read(data)
        } catch let error as XLSXReader.ReadError {
            throw LoadError(error.description)
        }
        let usable = sheets.filter { sheet in sheet.rows.contains { row in row.contains { !$0.isNull } } }
        guard !usable.isEmpty else {
            throw LoadError("that workbook's sheets are all empty.")
        }
        let names = SQLIdentifier.uniqued(
            usable.map { usable.count == 1 ? tableName : $0.name },
            fallbackPrefix: "sheet_"
        )
        return zip(names, usable).map { name, sheet in table(fromSheet: sheet, named: name) }
    }

    static func table(fromSheet sheet: XLSXReader.Sheet, named name: String) -> DataTable {
        // A header row in a spreadsheet is the first row whose cells are
        // all text — the same rule as the CSV path, applied to values that
        // already carry their type.
        let header = sheet.rows.first ?? []
        let hasHeader = header.contains { if case .text = $0 { return true } else { return false } }
            && !header.contains { if case .number = $0 { return true } else if case .integer = $0 { return true } else { return false } }
        let width = sheet.rows.map(\.count).max() ?? header.count
        let rawNames = (0..<width).map { index -> String in
            guard hasHeader, index < header.count, case .text(let text) = header[index] else {
                return "column_\(index + 1)"
            }
            return text
        }
        let names = SQLIdentifier.uniqued(rawNames, fallbackPrefix: "column_")
        let body = hasHeader ? Array(sheet.rows.dropFirst()) : sheet.rows
        let rows = body.map { row in
            (0..<width).map { index in index < row.count ? row[index] : DataValue.null }
        }
        let columns = names.enumerated().map { index, name in
            DataColumn(
                name: name,
                affinity: ColumnAffinity.infer(fromValues: rows.prefix(typeSampleRows).map { $0[index] })
            )
        }
        return DataTable(name: name, columns: columns, rows: rows)
    }
}
