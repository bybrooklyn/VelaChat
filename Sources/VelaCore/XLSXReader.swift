import Foundation

/// §9.2 — the read side of the §9.1 xlsx emitter, over the same
/// `OOXMLPackage` container. Writer-first paid off here: the parts, their
/// relationships, and the shared-strings indirection are already
/// understood, so this only has to walk them in the other direction.
///
/// Reads what a real workbook (Excel, Numbers, Sheets) actually contains,
/// not only what VelaChat emits: shared or inline strings, formula results,
/// booleans, sparse rows with gaps, and — the one that matters most for
/// analysis — number formats that mean *date*, which come back as ISO text
/// rather than as the raw 45000-ish serial nobody can read.
public enum XLSXReader {

    public struct Sheet: Sendable {
        public var name: String
        /// Row-major cells. Gaps in a sparse sheet are filled with `.null`
        /// so every row has the same shape as the widest one.
        public var rows: [[DataValue]]
    }

    public struct ReadError: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// Sheets in workbook order, each already rectangular.
    public static func read(_ data: Data) throws -> [Sheet] {
        let parts: [String: Data]
        do {
            parts = try OOXMLPackage.parts(of: data)
        } catch {
            throw ReadError("this isn't a readable .xlsx file (its zip container could not be opened)")
        }
        guard let workbookPart = parts["xl/workbook.xml"] else {
            throw ReadError("this zip has no xl/workbook.xml, so it isn't a spreadsheet")
        }

        let sharedStrings = parts["xl/sharedStrings.xml"].map(parseSharedStrings) ?? []
        let dateStyles = parts["xl/styles.xml"].map(parseDateStyleIndexes) ?? []
        let relationships = parts["xl/_rels/workbook.xml.rels"].map(parseRelationships) ?? [:]
        let entries = parseWorkbookSheets(workbookPart)
        guard !entries.isEmpty else {
            throw ReadError("this workbook declares no sheets")
        }

        var sheets: [Sheet] = []
        for (index, entry) in entries.enumerated() {
            // The r:id → part path indirection is the spec's route; the
            // sheetN.xml guess is the fallback for workbooks whose rels
            // part is missing or unreadable, which is a real thing seen in
            // files produced by smaller tools.
            let target = entry.relationshipID.flatMap { relationships[$0] }
            let path = target.map(resolvePartPath) ?? "xl/worksheets/sheet\(index + 1).xml"
            guard let sheetPart = parts[path] ?? parts["xl/worksheets/sheet\(index + 1).xml"] else { continue }
            let rows = parseWorksheet(sheetPart, sharedStrings: sharedStrings, dateStyles: dateStyles)
            sheets.append(Sheet(name: entry.name, rows: rows))
        }
        guard !sheets.isEmpty else {
            throw ReadError("this workbook's sheets could not be read")
        }
        return sheets
    }

    // MARK: - workbook.xml

    private struct SheetEntry {
        var name: String
        var relationshipID: String?
    }

    private static func parseWorkbookSheets(_ data: Data) -> [SheetEntry] {
        var entries: [SheetEntry] = []
        let delegate = ElementScanner(elements: ["sheet"]) { _, attributes in
            let name = attributes["name"] ?? "Sheet\(entries.count + 1)"
            entries.append(SheetEntry(name: name, relationshipID: attributes["r:id"] ?? attributes["id"]))
        }
        delegate.parse(data)
        return entries
    }

    private static func parseRelationships(_ data: Data) -> [String: String] {
        var map: [String: String] = [:]
        let delegate = ElementScanner(elements: ["Relationship"]) { _, attributes in
            guard let id = attributes["Id"], let target = attributes["Target"] else { return }
            map[id] = target
        }
        delegate.parse(data)
        return map
    }

    /// Relationship targets are relative to the *part's* folder (`xl/`) —
    /// or absolute from the package root when they start with a slash.
    private static func resolvePartPath(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        if target.hasPrefix("xl/") { return target }
        return "xl/" + target
    }

    // MARK: - sharedStrings.xml

    private static func parseSharedStrings(_ data: Data) -> [String] {
        var strings: [String] = []
        var current = ""
        var insideItem = false
        var insideText = false
        // Phonetic-guide runs (<rPh>, common in Japanese workbooks) carry
        // pronunciation, not content — including them would duplicate every
        // such string.
        var insidePhonetic = false
        let delegate = StreamingScanner(
            start: { element, _ in
                switch element {
                case "si": insideItem = true; current = ""
                case "rPh": insidePhonetic = true
                case "t": insideText = !insidePhonetic
                default: break
                }
            },
            characters: { text in
                if insideItem && insideText { current += text }
            },
            end: { element in
                switch element {
                case "si":
                    strings.append(current)
                    insideItem = false
                case "rPh": insidePhonetic = false
                case "t": insideText = false
                default: break
                }
            }
        )
        delegate.parse(data)
        return strings
    }

    // MARK: - styles.xml

    /// Indexes into `cellXfs` whose number format means a date or a time.
    /// Anything referencing one of these is converted from Excel's serial
    /// day number into ISO text at read time.
    private static func parseDateStyleIndexes(_ data: Data) -> [Bool] {
        // Built-in formats are not written into the file; the ranges are
        // fixed by the spec (14-22 dates/times, 45-47 elapsed time).
        var dateFormatIDs: Set<Int> = Set(14...22).union(Set(45...47))
        var isDateStyle: [Bool] = []
        var insideCellXfs = false

        let delegate = StreamingScanner(
            start: { element, attributes in
                switch element {
                case "numFmt":
                    guard let idText = attributes["numFmtId"], let id = Int(idText),
                          let code = attributes["formatCode"] else { return }
                    if isDateFormatCode(code) { dateFormatIDs.insert(id) }
                case "cellXfs":
                    insideCellXfs = true
                case "xf":
                    guard insideCellXfs else { return }
                    let id = attributes["numFmtId"].flatMap(Int.init) ?? 0
                    isDateStyle.append(dateFormatIDs.contains(id))
                default: break
                }
            },
            characters: { _ in },
            end: { element in
                if element == "cellXfs" { insideCellXfs = false }
            }
        )
        delegate.parse(data)
        return isDateStyle
    }

    /// A custom format code is a date format when it uses date/time field
    /// letters outside of its literal sections. Colour and condition
    /// sections ("[Red]", "[$-409]") are stripped first — "d" inside them
    /// is not a day field.
    private static func isDateFormatCode(_ code: String) -> Bool {
        var stripped = ""
        var depth = 0
        var iterator = code.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "[": depth += 1
            case "]": depth = max(0, depth - 1)
            case "\"":
                // Literal text runs until the closing quote.
                while let next = iterator.next(), next != "\"" {}
            case "\\":
                _ = iterator.next()
            default:
                if depth == 0 { stripped.append(character) }
            }
        }
        let lowered = stripped.lowercased()
        return lowered.contains("y") || lowered.contains("d")
            || lowered.contains("m") && (lowered.contains(":") || lowered.contains("/") || lowered.contains("-"))
            || lowered.contains("h") || lowered.contains("s")
    }

    // MARK: - worksheets

    private static func parseWorksheet(_ data: Data, sharedStrings: [String], dateStyles: [Bool]) -> [[DataValue]] {
        var rows: [[DataValue]] = []
        var currentRow: [Int: DataValue] = [:]
        var currentRowIndex = 0
        var maxColumn = 0

        var cellReference = ""
        var cellType = ""
        var cellStyle: Int?
        var insideValue = false
        var insideInlineString = false
        var valueText = ""

        let delegate = StreamingScanner(
            start: { element, attributes in
                switch element {
                case "row":
                    currentRow = [:]
                    currentRowIndex = attributes["r"].flatMap(Int.init) ?? (rows.count + 1)
                case "c":
                    cellReference = attributes["r"] ?? ""
                    cellType = attributes["t"] ?? "n"
                    cellStyle = attributes["s"].flatMap(Int.init)
                    valueText = ""
                case "v":
                    insideValue = true
                    valueText = ""
                case "is":
                    insideInlineString = true
                    valueText = ""
                case "t":
                    if insideInlineString { insideValue = true }
                default: break
                }
            },
            characters: { text in
                if insideValue { valueText += text }
            },
            end: { element in
                switch element {
                case "v":
                    insideValue = false
                case "t":
                    if insideInlineString { insideValue = false }
                case "is":
                    insideInlineString = false
                case "c":
                    let column = columnIndex(fromReference: cellReference) ?? (currentRow.keys.max().map { $0 + 1 } ?? 0)
                    let value = decodeCell(
                        type: cellType,
                        raw: valueText,
                        styleIndex: cellStyle,
                        sharedStrings: sharedStrings,
                        dateStyles: dateStyles
                    )
                    if !value.isNull {
                        currentRow[column] = value
                        maxColumn = max(maxColumn, column)
                    }
                case "row":
                    // Sparse sheets skip empty rows entirely (`r` jumps);
                    // the gap is real data — those rows exist and are blank.
                    while rows.count < currentRowIndex - 1 { rows.append([]) }
                    var materialized: [DataValue] = []
                    if let last = currentRow.keys.max() {
                        materialized = (0...last).map { currentRow[$0] ?? .null }
                    }
                    rows.append(materialized)
                default: break
                }
            }
        )
        delegate.parse(data)

        // Rectangularize: every row padded to the widest one, and wholly
        // empty trailing rows dropped.
        let width = rows.map(\.count).max() ?? 0
        while let last = rows.last, last.allSatisfy(\.isNull) { rows.removeLast() }
        return rows.map { row in
            row.count == width ? row : row + Array(repeating: .null, count: width - row.count)
        }
    }

    private static func decodeCell(
        type: String,
        raw: String,
        styleIndex: Int?,
        sharedStrings: [String],
        dateStyles: [Bool]
    ) -> DataValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "s":
            guard let index = Int(trimmed), index >= 0, index < sharedStrings.count else { return .null }
            let text = sharedStrings[index]
            return text.isEmpty ? .null : .text(text)
        case "inlineStr", "str":
            return raw.isEmpty ? .null : .text(raw)
        case "b":
            return .integer(trimmed == "1" ? 1 : 0)
        case "e":
            // A cell holding #DIV/0! is data about the source, not a value
            // to load as if it were one.
            return trimmed.isEmpty ? .null : .text(trimmed)
        default:
            guard !trimmed.isEmpty else { return .null }
            guard let number = Double(trimmed) else { return .text(trimmed) }
            if let styleIndex, styleIndex >= 0, styleIndex < dateStyles.count, dateStyles[styleIndex] {
                return .text(isoDate(fromExcelSerial: number))
            }
            if number == number.rounded(), abs(number) < 9e15, !trimmed.contains(".") {
                return .integer(Int64(number))
            }
            return .number(number)
        }
    }

    /// Excel counts days from 1899-12-30 — one day before its own epoch —
    /// because it deliberately reproduces Lotus 1-2-3's belief that 1900
    /// was a leap year. Serials below 60 predate that phantom 29 February,
    /// so they need the un-shifted base.
    static func isoDate(fromExcelSerial serial: Double) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let baseComponents = DateComponents(
            year: 1899,
            month: 12,
            day: serial < 60 ? 31 : 30
        )
        guard let base = calendar.date(from: baseComponents) else { return String(serial) }
        let whole = floor(serial)
        let fraction = serial - whole
        let date = base.addingTimeInterval(whole * 86_400 + (fraction * 86_400).rounded())

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // A whole-day serial is a date; anything with a time-of-day part
        // keeps it. Both forms are what SQLite's date functions parse.
        formatter.dateFormat = fraction == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// "BC12" → 54 (zero-based). Digits are the row number and ignored.
    static func columnIndex(fromReference reference: String) -> Int? {
        var value = 0
        var sawLetter = false
        for character in reference.uppercased() {
            guard let ascii = character.asciiValue else { return nil }
            if ascii >= 65 && ascii <= 90 {
                value = value * 26 + Int(ascii - 64)
                sawLetter = true
            } else if character.isNumber {
                break
            } else {
                return nil
            }
        }
        return sawLetter ? value - 1 : nil
    }
}

// MARK: - XMLParser plumbing

/// `XMLParser` needs a class delegate; these two wrap that in closures so
/// the parsers above read as the state machines they are instead of as
/// four more NSObject subclasses.
private final class StreamingScanner: NSObject, XMLParserDelegate {
    private let onStart: (String, [String: String]) -> Void
    private let onCharacters: (String) -> Void
    private let onEnd: (String) -> Void

    init(
        start: @escaping (String, [String: String]) -> Void,
        characters: @escaping (String) -> Void,
        end: @escaping (String) -> Void
    ) {
        onStart = start
        onCharacters = characters
        onEnd = end
    }

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        onStart(localName(of: elementName), attributes)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        onCharacters(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        onEnd(localName(of: elementName))
    }

    /// OOXML parts use prefixed elements in places (`<x:sheetData>` from
    /// some producers); matching on the local name keeps this working for
    /// files that do and files that don't.
    private func localName(of element: String) -> String {
        guard let colon = element.lastIndex(of: ":") else { return element }
        return String(element[element.index(after: colon)...])
    }
}

/// The common "collect attributes of every <foo>" case.
private final class ElementScanner {
    private let scanner: StreamingScanner

    init(elements: Set<String>, found: @escaping (String, [String: String]) -> Void) {
        scanner = StreamingScanner(
            start: { element, attributes in
                if elements.contains(element) { found(element, attributes) }
            },
            characters: { _ in },
            end: { _ in }
        )
    }

    func parse(_ data: Data) { scanner.parse(data) }
}
