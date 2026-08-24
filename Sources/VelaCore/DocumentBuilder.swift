import Foundation

/// Error type shared by §9.1's emitters. The message is what the model
/// sees back through `create_document`, so it always names what was wrong
/// and what shape was expected instead of a bare failure.
public struct DocumentEmitterError: Error, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The five formats `create_document` can produce.
public enum DocumentFormat: String, CaseIterable {
    case xlsx
    case docx
    case pptx
    case pdf
    case md

    public var fileExtension: String { rawValue }
}

/// Turns the tool call's structured `content` object into document bytes,
/// using the VelaCore emitters. All schema knowledge for the tool lives
/// here so the wire shape has exactly one definition (mirrors how
/// `AskUserQuestionPayload` owns ask_user's payload).
public enum DocumentBuilder {

    /// Builds document bytes from a `content` value that came out of the
    /// tool arguments (`JSONSerialization`-parsed). Throws
    /// `DocumentEmitterError` with model-actionable messages.
    public static func build(format rawFormat: String, content: Any) throws -> (data: Data, format: DocumentFormat) {
        guard let format = DocumentFormat(rawValue: rawFormat.lowercased().trimmingCharacters(in: .whitespaces)) else {
            let known = DocumentFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw DocumentEmitterError("unknown format \"\(rawFormat)\" — supported formats: \(known)")
        }
        guard let object = content as? [String: Any] else {
            throw DocumentEmitterError("\"content\" must be an object describing the document, e.g. {\"rows\": [[\"Name\", 42]]} for xlsx.")
        }
        switch format {
        case .md:
            return (try markdown(object), format)
        case .xlsx:
            return (try buildSpreadsheet(object).makeData(), format)
        case .docx:
            return (try DOCXDocument(blocks: try blocks(from: object)).makeData(), format)
        case .pptx:
            return (try PPTXDocument(slides: try slides(from: object)).makeData(), format)
        case .pdf:
            return (try SimplePDFWriter.makeData(blocks: try blocks(from: object)), format)
        }
    }

    // MARK: - Markdown

    private static func markdown(_ object: [String: Any]) throws -> Data {
        guard let text = object["text"] as? String else {
            throw DocumentEmitterError("markdown content needs a \"text\" field with the full document body.")
        }
        return Data(text.utf8)
    }

    // MARK: - Spreadsheet

    private static func buildSpreadsheet(_ object: [String: Any]) throws -> XLSXDocument {
        var sheetsJSON: [[String: Any]] = []
        if let explicit = object["sheets"] as? [[String: Any]] {
            sheetsJSON = explicit
        } else if object["rows"] != nil {
            // Single-sheet shorthand: the common case is one grid.
            sheetsJSON = [object]
        } else {
            throw DocumentEmitterError(
                "spreadsheet content needs \"rows\" (an array of rows) or \"sheets\" " +
                    "([{\"name\": \"Q3\", \"rows\": [[\"Region\", \"Revenue\"], [\"North\", 1250]]}])."
            )
        }
        guard !sheetsJSON.isEmpty else {
            throw DocumentEmitterError("the workbook needs at least one sheet.")
        }

        var sheets: [XLSXDocument.Sheet] = []
        var totalCells = 0
        for (offset, json) in sheetsJSON.enumerated() {
            guard let rowsJSON = json["rows"] as? [[Any]] else {
                throw DocumentEmitterError("sheet \(offset + 1) needs a \"rows\" array of arrays, e.g. {\"rows\": [[\"Name\", 42]]}.")
            }
            var rows: [[XLSXDocument.Cell]] = []
            for rowJSON in rowsJSON {
                var row: [XLSXDocument.Cell] = []
                for cellJSON in rowJSON {
                    if let cell = cell(fromJSON: cellJSON) {
                        row.append(cell)
                        totalCells += 1
                        guard totalCells <= Limits.documentMaxCells else {
                            throw DocumentEmitterError("the workbook exceeds \(Limits.documentMaxCells) cells; split it across multiple documents.")
                        }
                    } else {
                        row.append(XLSXDocument.Cell(.text(""), bold: false))
                    }
                }
                rows.append(row)
            }
            let widths = (json["widths"] as? [Any])?.compactMap { width -> Double? in
                numberValue(width)
            }
            let merges = (json["merges"] as? [String]) ?? []
            sheets.append(XLSXDocument.Sheet(
                name: (json["name"] as? String) ?? "Sheet\(offset + 1)",
                rows: rows,
                columnWidths: (widths?.isEmpty ?? true) ? nil : widths,
                mergedRanges: merges
            ))
        }
        return XLSXDocument(sheets: sheets)
    }

    /// One spreadsheet cell: a plain string, a plain number, null (empty),
    /// or an object {"text"/"number", "bold"?, "format"?}.
    private static func cell(fromJSON value: Any) -> XLSXDocument.Cell? {
        if value is NSNull { return nil }
        if let text = value as? String { return .text(text) }
        if let number = numberValue(value) { return .number(number) }
        if let object = value as? [String: Any] {
            let bold = object["bold"] as? Bool ?? false
            let numberFormat = object["format"] as? String
            if let text = object["text"] as? String {
                return XLSXDocument.Cell(.text(text), bold: bold, numberFormat: numberFormat)
            }
            if let number = object["number"].flatMap(numberValue) {
                return XLSXDocument.Cell(.number(number), bold: bold, numberFormat: numberFormat)
            }
        }
        return nil
    }

    private static func numberValue(_ value: Any) -> Double? {
        if let number = value as? Double { return number.isFinite ? number : nil }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let text = value as? String, let number = Double(text), number.isFinite { return number }
        return nil
    }

    // MARK: - Document blocks (docx + pdf)

    private static func blocks(from object: [String: Any]) throws -> [DOCXDocument.Block] {
        guard let blocksJSON = object["blocks"] as? [[String: Any]] else {
            throw DocumentEmitterError(
                "\"content.blocks\" must be an array of {\"type\": ...} objects — types: heading, paragraph, bullet, numbered, table."
            )
        }
        var blocks: [DOCXDocument.Block] = []
        for blockJSON in blocksJSON {
            guard let type = blockJSON["type"] as? String else {
                throw DocumentEmitterError("every block needs a \"type\": heading, paragraph, bullet, numbered, or table.")
            }
            switch type {
            case "heading":
                guard let text = blockJSON["text"] as? String else {
                    throw DocumentEmitterError("a heading block needs \"text\".")
                }
                let level = (blockJSON["level"]).flatMap(numberValue).map(Int.init) ?? 1
                blocks.append(.heading(level: level, text: text))
            case "paragraph":
                if let runsJSON = blockJSON["runs"] as? [[String: Any]] {
                    let runs = runsJSON.map { run in
                        DOCXDocument.Run(
                            run["text"] as? String ?? "",
                            bold: run["bold"] as? Bool ?? false,
                            italic: run["italic"] as? Bool ?? false
                        )
                    }
                    blocks.append(.paragraph(runs))
                } else if let text = blockJSON["text"] as? String {
                    blocks.append(.paragraph(text))
                } else {
                    throw DocumentEmitterError("a paragraph block needs \"text\" or \"runs\".")
                }
            case "bullet", "numbered":
                guard let text = blockJSON["text"] as? String else {
                    throw DocumentEmitterError("a \(type) block needs \"text\".")
                }
                blocks.append(type == "bullet" ? .bullet(text) : .numbered(text))
            case "table":
                guard let rows = blockJSON["rows"] as? [[Any]] else {
                    throw DocumentEmitterError("a table block needs \"rows\", an array of rows of cell strings.")
                }
                let cellRows = rows.map { row in
                    row.map { cell -> String in
                        if let text = cell as? String { return text }
                        if let number = numberValue(cell) { return XLSXDocument.numericLiteral(number) }
                        return ""
                    }
                }
                blocks.append(.table(rows: cellRows, headerFirstRow: blockJSON["header"] as? Bool ?? false))
            default:
                throw DocumentEmitterError("unknown block type \"\(type)\" — use heading, paragraph, bullet, numbered, or table.")
            }
        }
        return blocks
    }

    // MARK: - Deck

    private static func slides(from object: [String: Any]) throws -> [PPTXDocument.Slide] {
        guard let slidesJSON = object["slides"] as? [[String: Any]], !slidesJSON.isEmpty else {
            throw DocumentEmitterError(
                "deck content needs \"slides\": [{\"layout\": \"title\"|\"bullets\", \"title\": \"...\", \"subtitle\": \"...\", \"bullets\": [...]}]."
            )
        }
        return try slidesJSON.map { slideJSON in
            guard let title = slideJSON["title"] as? String, !title.isEmpty else {
                throw DocumentEmitterError("every slide needs a non-empty \"title\".")
            }
            let subtitle = slideJSON["subtitle"] as? String ?? ""
            let bullets = ((slideJSON["bullets"] as? [Any]) ?? []).map { item -> String in
                if let text = item as? String { return text }
                if let number = numberValue(item) { return XLSXDocument.numericLiteral(number) }
                return ""
            }
            let layoutRaw = (slideJSON["layout"] as? String)?.lowercased()
            switch layoutRaw {
            case "title":
                return PPTXDocument.Slide(layout: .title, title: title, subtitle: subtitle)
            case "bullets", "", nil:
                return PPTXDocument.Slide(layout: .bullets, title: title, bullets: bullets)
            default:
                throw DocumentEmitterError("slide layout \"\(layoutRaw!)\" is unknown — layouts are \"title\" and \"bullets\".")
            }
        }
    }
}
