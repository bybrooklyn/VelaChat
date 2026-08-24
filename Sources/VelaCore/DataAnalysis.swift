import Foundation

/// §9.2 — what a `query_data` call produces, and the contract for the
/// chart the model may ask for alongside it.
///
/// The division of labour is the section's whole point: the model writes
/// SQL and *names* a chart; VelaChat runs the query and draws. Nothing
/// here executes anything — this is the shape of the exchange, validated
/// against the result that actually came back.
public enum DataAnalysis {

    /// The chart types VelaChat can render, each mapping to one Swift
    /// `Charts` mark. The renderer is driven by this explicit choice, not
    /// by re-inferring one from the result shape: the model decides, the
    /// contract carries it.
    public enum ChartType: String, Sendable, Equatable, Codable, CaseIterable {
        case bar, line, scatter, area
    }

    public enum ChartSort: String, Sendable, Equatable, Codable {
        case xAscending = "x_asc"
        case xDescending = "x_desc"
        case yAscending = "y_asc"
        case yDescending = "y_desc"
    }

    public struct ChartSpec: Sendable, Equatable, Codable {
        public var type: ChartType
        public var title: String?
        public var xField: String
        public var xLabel: String?
        public var yField: String
        public var yLabel: String?
        /// Splits the marks into one series per distinct value of this
        /// column.
        public var series: String?
        public var sort: ChartSort?
        /// Caps how many rows are plotted (the result itself is already
        /// capped; this is the model's own editorial limit).
        public var limit: Int?

        public init(
            type: ChartType,
            title: String? = nil,
            xField: String,
            xLabel: String? = nil,
            yField: String,
            yLabel: String? = nil,
            series: String? = nil,
            sort: ChartSort? = nil,
            limit: Int? = nil
        ) {
            self.type = type
            self.title = title
            self.xField = xField
            self.xLabel = xLabel
            self.yField = yField
            self.yLabel = yLabel
            self.series = series
            self.sort = sort
            self.limit = limit
        }
    }

    /// A spec that names a column the query didn't return would render as
    /// a blank chart — the failure mode where the model believes it drew
    /// something. Validation refuses it and says which column was wrong,
    /// so the next call can fix the spec instead of the user seeing
    /// nothing.
    public enum ChartSpecError: Error, CustomStringConvertible, Equatable {
        case missingField(String)
        case unknownType(String)
        case unknownColumn(field: String, name: String, available: [String])
        case unknownSort(String)

        public var description: String {
            switch self {
            case .missingField(let name):
                return "the chart spec needs \"\(name)\"."
            case .unknownType(let raw):
                return "\"\(raw)\" isn't a chart type — use bar, line, scatter, or area."
            case .unknownColumn(let field, let name, let available):
                return "the chart's \(field) names \"\(name)\", which isn't a column in this result. Available columns: \(available.joined(separator: ", "))."
            case .unknownSort(let raw):
                return "\"\(raw)\" isn't a sort — use x_asc, x_desc, y_asc, or y_desc."
            }
        }
    }

    /// Parses the model's `chart` object and validates every column
    /// reference against the columns the query actually returned.
    public static func chartSpec(from object: [String: Any], resultColumns: [String]) throws -> ChartSpec {
        func column(_ container: Any?, field: String) throws -> (name: String, label: String?) {
            // Both `{"x": {"field": "region"}}` and the shorthand
            // `{"x": "region"}` are accepted: the schema asks for the
            // object, and refusing the obvious shorthand would fail a call
            // that said exactly what it meant.
            let name: String
            var label: String?
            if let text = container as? String {
                name = text
            } else if let dictionary = container as? [String: Any], let text = dictionary["field"] as? String {
                name = text
                label = dictionary["label"] as? String
            } else {
                throw ChartSpecError.missingField(field)
            }
            guard resultColumns.contains(name) else {
                throw ChartSpecError.unknownColumn(field: field, name: name, available: resultColumns)
            }
            return (name, label)
        }

        guard let rawType = object["type"] as? String else { throw ChartSpecError.missingField("type") }
        guard let type = ChartType(rawValue: rawType.lowercased()) else { throw ChartSpecError.unknownType(rawType) }
        let x = try column(object["x"], field: "x")
        let y = try column(object["y"], field: "y")

        var series: String?
        if let raw = object["series"] as? String, !raw.isEmpty {
            guard resultColumns.contains(raw) else {
                throw ChartSpecError.unknownColumn(field: "series", name: raw, available: resultColumns)
            }
            series = raw
        }
        var sort: ChartSort?
        if let raw = object["sort"] as? String, !raw.isEmpty {
            guard let parsed = ChartSort(rawValue: raw.lowercased()) else { throw ChartSpecError.unknownSort(raw) }
            sort = parsed
        }
        let limit = (object["limit"] as? Int) ?? (object["limit"] as? NSNumber)?.intValue

        return ChartSpec(
            type: type,
            title: object["title"] as? String,
            xField: x.name,
            xLabel: x.label,
            yField: y.name,
            yLabel: y.label,
            series: series,
            sort: sort,
            limit: limit.map { max(1, $0) }
        )
    }

    // MARK: - Result text

    /// What the model reads back. A fixed-width table because that is what
    /// survives being quoted, re-read a round later, and skimmed by a
    /// person reading the transcript — and because column alignment is the
    /// cheapest way to make a wrong join visible.
    public static func resultText(
        columns: [String],
        rows: [[DataValue]],
        truncated: Bool,
        rowLimit: Int = Limits.dataQueryRows,
        byteBudget: Int = Limits.dataQueryTextBytes
    ) -> String {
        guard !columns.isEmpty else { return "That query returned no columns." }
        guard !rows.isEmpty else { return "No rows matched." }

        let cells = rows.map { row in
            columns.indices.map { index -> String in
                let value = index < row.count ? row[index] : .null
                return value.isNull ? "NULL" : value.displayText
            }
        }
        var widths = columns.map { $0.count }
        for row in cells {
            for (index, cell) in row.enumerated() {
                widths[index] = min(max(widths[index], cell.count), 40)
            }
        }
        func pad(_ text: String, _ width: Int) -> String {
            let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
            return clipped.padding(toLength: max(width, clipped.count), withPad: " ", startingAt: 0)
        }

        var lines: [String] = []
        lines.append(zip(columns, widths).map(pad).joined(separator: "  "))
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        var byteCount = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        var shown = 0
        for row in cells {
            let line = zip(row, widths).map(pad).joined(separator: "  ")
            if byteCount + line.utf8.count > byteBudget { break }
            lines.append(line)
            byteCount += line.utf8.count + 1
            shown += 1
        }

        var footer = "\(rows.count) row\(rows.count == 1 ? "" : "s")"
        if shown < rows.count {
            footer += " (\(shown) shown here; the full result is in the transcript table)"
        }
        if truncated {
            footer += ". The result hit the \(rowLimit)-row cap — aggregate in SQL rather than reading every row"
        }
        lines.append(footer + ".")
        return lines.joined(separator: "\n")
    }

    /// The schema block handed to the model when data is attached: table
    /// names, columns with types, row counts, and a few real rows. Written
    /// once here so the tool result, the system-prompt block, and any
    /// future surface all describe the data identically.
    public static func schemaText(_ tables: [AnalysisDatabase.TableSummary]) -> String {
        guard !tables.isEmpty else { return "No data is attached to this conversation." }
        var blocks: [String] = []
        for table in tables {
            var block = "TABLE \(table.name) — \(table.rowCount) row\(table.rowCount == 1 ? "" : "s")\n"
            block += "  columns: " + table.columns.map { "\($0.name) \($0.affinity.rawValue)" }.joined(separator: ", ")
            if !table.sampleRows.isEmpty {
                block += "\n  sample rows:"
                for row in table.sampleRows {
                    let cells = zip(table.columns, row).map { column, value in
                        "\(column.name)=\(value.isNull ? "NULL" : value.displayText)"
                    }
                    block += "\n    " + cells.joined(separator: ", ")
                }
            }
            blocks.append(block)
        }
        return blocks.joined(separator: "\n\n")
    }
}
