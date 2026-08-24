import Foundation

/// §9.2 — the one currency every data source is loaded into before it
/// reaches SQLite. CSV, TSV, JSON and xlsx have nothing in common on the
/// way in and must have everything in common on the way out, because the
/// point of the section is that the model writes *one* SQL dialect
/// regardless of what the user attached.
public enum DataValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case integer(Int64)
    case null

    /// How the value reads in a result table or a schema sample — never
    /// how it is bound into SQLite (that goes through the typed
    /// `sqlite3_bind_*` calls, not through a string).
    public var displayText: String {
        switch self {
        case .text(let text): return text
        case .integer(let value): return String(value)
        case .number(let value):
            // A whole double formats as "42", not "42.0": these numbers are
            // read by a person and by a model, and a spurious .0 on every
            // count column is noise in both audiences.
            if value == value.rounded(), abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .null: return ""
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// SQLite's own type affinities, which is all the type system this needs:
/// a column is a number, a decimal, or text.
public enum ColumnAffinity: String, Sendable, Equatable {
    case integer = "INTEGER"
    case real = "REAL"
    case text = "TEXT"

    /// Infers a column's affinity from sampled raw strings. Mixed content
    /// falls back to TEXT rather than dropping the rows that don't fit —
    /// a column of numbers with one "n/a" in it is a text column with
    /// numbers in it, and silently nulling that cell would be the analysis
    /// lying about the data.
    ///
    /// Blank samples carry no evidence either way (they load as NULL), so
    /// they neither force TEXT nor, on their own, make a column numeric.
    public static func infer(from samples: [String]) -> ColumnAffinity {
        var sawValue = false
        var allInteger = true
        for sample in samples {
            let trimmed = sample.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            sawValue = true
            if Int64(trimmed) != nil { continue }
            allInteger = false
            guard let value = Double(trimmed), value.isFinite else { return .text }
        }
        guard sawValue else { return .text }
        return allInteger ? .integer : .real
    }

    /// The same question for sources that arrive already typed (xlsx cells,
    /// JSON numbers) — no re-parsing of a string that was never one.
    public static func infer(fromValues values: [DataValue]) -> ColumnAffinity {
        var sawValue = false
        var allInteger = true
        for value in values {
            switch value {
            case .null: continue
            case .integer: sawValue = true
            case .number: sawValue = true; allInteger = false
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                return .text
            }
        }
        guard sawValue else { return .text }
        return allInteger ? .integer : .real
    }
}

public struct DataColumn: Sendable, Equatable {
    public var name: String
    public var affinity: ColumnAffinity

    public init(name: String, affinity: ColumnAffinity) {
        self.name = name
        self.affinity = affinity
    }
}

/// One loaded table, ready to become a `CREATE TABLE` plus a bound
/// `INSERT` loop. Rows are ragged-tolerant: a row shorter than `columns`
/// is padded with NULL at insert time rather than rejected, because real
/// CSVs do that and refusing the file is worse than loading it honestly.
public struct DataTable: Sendable {
    public var name: String
    public var columns: [DataColumn]
    public var rows: [[DataValue]]

    public init(name: String, columns: [DataColumn], rows: [[DataValue]]) {
        self.name = name
        self.columns = columns
        self.rows = rows
    }
}

/// Names arriving from a spreadsheet header row or a JSON key are not SQL
/// identifiers — "Total ($)", "2026", "select" and an empty header all
/// reach this. Quoting them at every use site would work; sanitizing once
/// here means the schema the model is shown is the schema it can type.
public enum SQLIdentifier {
    /// Letters, digits and underscore only, never leading with a digit,
    /// never empty, and never a duplicate within one table.
    public static func sanitize(_ raw: String, fallback: String) -> String {
        var out = ""
        for character in raw {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if character == "_" || character == " " || character == "-" || character == "." {
                // Collapse runs of separators instead of emitting "a__b".
                if !out.hasSuffix("_") && !out.isEmpty { out.append("_") }
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        if let first = out.first, first.isNumber { out = "n_" + out }
        if out.isEmpty { return fallback }
        return String(out.prefix(60))
    }

    /// Applies `sanitize` across a list, disambiguating collisions with a
    /// numeric suffix so two "Total" headers stay two distinct columns.
    public static func uniqued(_ raw: [String], fallbackPrefix: String) -> [String] {
        var used: Set<String> = []
        var names: [String] = []
        for (index, name) in raw.enumerated() {
            var candidate = sanitize(name, fallback: "\(fallbackPrefix)\(index + 1)")
            if used.contains(candidate.lowercased()) {
                var suffix = 2
                while used.contains("\(candidate)_\(suffix)".lowercased()) { suffix += 1 }
                candidate = "\(candidate)_\(suffix)"
            }
            used.insert(candidate.lowercased())
            names.append(candidate)
        }
        return names
    }
}
