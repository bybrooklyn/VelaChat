import Foundation

/// §9.1 — the xlsx emitter. High-fidelity subset, deliberately: sheets,
/// rows/columns, strings and numbers (via a real `sharedStrings` part),
/// basic styles (bold, custom number formats), explicit column widths,
/// and merged ranges. Everything else Excel fills in from defaults, which
/// is exactly what keeps this openable-without-repair while staying a few
/// hundred lines instead of a library.
public struct XLSXDocument {
    public struct Cell {
        public enum Value: Sendable {
            case text(String)
            case number(Double)
        }

        public var value: Value
        public var bold: Bool
        public var numberFormat: String?

        public init(_ value: Value, bold: Bool = false, numberFormat: String? = nil) {
            self.value = value
            self.bold = bold
            self.numberFormat = numberFormat
        }

        public static func text(_ text: String) -> Cell { Cell(.text(text)) }
        public static func number(_ number: Double) -> Cell { Cell(.number(number)) }
    }

    public struct Sheet {
        public var name: String
        /// Rows of cells; trailing empty cells in a row are trimmed at
        /// emit time. An inner array may be empty.
        public var rows: [[Cell]]
        /// Explicit widths for columns 1...n (nil = Excel's default).
        public var columnWidths: [Double]?
        /// Merged ranges as cell references, e.g. "A1:C1". Invalid
        /// references are dropped rather than emitted.
        public var mergedRanges: [String]

        public init(name: String, rows: [[Cell]], columnWidths: [Double]? = nil, mergedRanges: [String] = []) {
            self.name = name
            self.rows = rows
            self.columnWidths = columnWidths
            self.mergedRanges = mergedRanges
        }
    }

    public var sheets: [Sheet]

    public init(sheets: [Sheet]) {
        self.sheets = sheets
    }

    public init(sheetName: String, rows: [[Cell]]) {
        self.init(sheets: [Sheet(name: sheetName, rows: rows)])
    }

    // MARK: - Emission

    func makePackage() throws -> OOXMLPackage {
        guard !sheets.isEmpty else {
            throw DocumentEmitterError("a workbook needs at least one sheet")
        }
        let names = sanitizedSheetNames()
        var package = OOXMLPackage()

        // Shared strings are collected up front because worksheets carry
        // indexes into that part; two passes over an in-memory model are
        // cheaper than streaming machinery.
        var sharedStrings: [String] = []
        var sharedStringIndexes: [String: Int] = [:]
        var styleKeys: [StyleKey] = []
        var styleIndexes: [StyleKey: Int] = [:]
        for sheet in sheets {
            for row in sheet.rows {
                for cell in row {
                    if case .text(let text) = cell.value {
                        if sharedStringIndexes[text] == nil {
                            sharedStringIndexes[text] = sharedStrings.count
                            sharedStrings.append(text)
                        }
                    }
                    let key = StyleKey(bold: cell.bold, numberFormat: cell.numberFormat)
                    if styleIndexes[key] == nil {
                        styleIndexes[key] = styleKeys.count
                        styleKeys.append(key)
                    }
                }
            }
        }

        package.addXML("[Content_Types].xml", Self.contentTypes(sheetCount: sheets.count))
        package.addXML("_rels/.rels", Self.rootRelationships())
        package.addXML("docProps/core.xml", Self.coreProperties())
        package.addXML("docProps/app.xml", Self.appProperties(sheetNames: names))
        package.addXML("xl/workbook.xml", Self.workbookXML(sheetNames: names))
        package.addXML("xl/_rels/workbook.xml.rels", Self.workbookRelationships(sheetCount: sheets.count))
        if !styleKeys.isEmpty {
            package.addXML("xl/styles.xml", Self.stylesXML(styleKeys: styleKeys))
        } else {
            package.addXML("xl/styles.xml", Self.stylesXML(styleKeys: []))
        }
        package.addXML("xl/sharedStrings.xml", Self.sharedStringsXML(sharedStrings))
        for (index, sheet) in sheets.enumerated() {
            package.addXML(
                "xl/worksheets/sheet\(index + 1).xml",
                Self.worksheetXML(sheet, sharedStringIndexes: sharedStringIndexes, styleIndexes: styleIndexes)
            )
        }
        return package
    }

    public func makeData() throws -> Data {
        try makePackage().makeData()
    }

    private func sanitizedSheetNames() -> [String] {
        var names: [String] = []
        var used: Set<String> = []
        for (offset, sheet) in sheets.enumerated() {
            var name = XMLText.sanitizedName(sheet.name, fallback: "Sheet\(offset + 1)")
            if used.contains(name) {
                var suffix = 2
                while used.contains("\(name) \(suffix)") { suffix += 1 }
                name = "\(name) \(suffix)"
            }
            names.append(name)
            used.insert(name)
        }
        return names
    }

    // MARK: - Parts

    private static func contentTypes(sheetCount: Int) -> String {
        var overrides =
            """
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
            <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>\
            <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
            <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
            """
        for index in 1...max(sheetCount, 1) {
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\(overrides)</Types>
        """
    }

    private static func rootRelationships() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
        </Relationships>
        """
    }

    private static func coreProperties() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:creator>VelaChat</dc:creator><cp:lastModifiedBy>VelaChat</cp:lastModifiedBy>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified>\
        </cp:coreProperties>
        """
    }

    private static func appProperties(sheetNames: [String]) -> String {
        var titles = ""
        for name in sheetNames {
            titles += "<vt:lpstr>\(XMLText.escaped(name))</vt:lpstr>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
        <Application>VelaChat</Application><TitlesOfParts><vt:vector size="\((max(sheetNames.count, 1) + 1))" baseType="lpstr"><vt:lpstr>Worksheets</vt:lpstr>\(titles)</vt:vector></TitlesOfParts>\
        </Properties>
        """
    }

    private static func workbookXML(sheetNames: [String]) -> String {
        var sheets = ""
        for (index, name) in sheetNames.enumerated() {
            sheets += "<sheet name=\"\(XMLText.escaped(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <bookViews><workbookView/></bookViews><sheets>\(sheets)</sheets>\
        </workbook>
        """
    }

    private static func workbookRelationships(sheetCount: Int) -> String {
        var relationships = ""
        for index in 1...max(sheetCount, 1) {
            relationships += "<Relationship Id=\"rId\(index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index).xml\"/>"
        }
        relationships += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        relationships += "<Relationship Id=\"rId\(sheetCount + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationships)</Relationships>
        """
    }

    private static func sharedStringsXML(_ strings: [String]) -> String {
        var items = ""
        for string in strings {
            items += "<si><t xml:space=\"preserve\">\(XMLText.escaped(string))</t></si>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(strings.count)" uniqueCount="\(strings.count)">\(items)</sst>
        """
    }

    // MARK: - Styles
    //
    // Styles are built from exactly the (bold, numberFormat) combinations
    // the document actually uses. Fonts/fills/borders lists keep their
    // spec-mandated minimum entries (fills MUST have two — none + the
    // legacy gray125 — or Excel offers to "repair" the file).

    struct StyleKey: Hashable {
        var bold: Bool
        var numberFormat: String?
    }

    private static func stylesXML(styleKeys: [StyleKey]) -> String {
        var numFmts = ""
        var numFmtIds: [String: Int] = [:]
        var nextCustomID = 164
        for key in styleKeys {
            guard let format = key.numberFormat, numFmtIds[format] == nil else { continue }
            numFmtIds[format] = nextCustomID
            numFmts += "<numFmt numFmtId=\"\(nextCustomID)\" formatCode=\"\(XMLText.escaped(format))\"/>"
            nextCustomID += 1
        }

        var cellXfs = ""
        for key in styleKeys {
            let fontID = key.bold ? 1 : 0
            let numFmtID = key.numberFormat.flatMap { numFmtIds[$0] } ?? 0
            let applyNumberFormat = key.numberFormat != nil ? " applyNumberFormat=\"1\"" : ""
            let applyFont = key.bold ? " applyFont=\"1\"" : ""
            cellXfs += "<xf numFmtId=\"\(numFmtID)\" fontId=\"\(fontID)\" fillId=\"0\" borderId=\"0\" xfId=\"0\"\(applyFont)\(applyNumberFormat)/>"
        }
        // A workbook with no styled cells still needs one usable xf.
        if cellXfs.isEmpty { cellXfs = "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" }

        // Element order matters to the schema: numFmts comes FIRST,
        // before fonts/fills/borders/xfs.
        let numFmtsElement = numFmts.isEmpty ? "" : "<numFmts count=\"\(numFmtIds.count)\">\(numFmts)</numFmts>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        \(numFmtsElement)<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="\((styleKeys.isEmpty ? 1 : styleKeys.count))">\(cellXfs)</cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """
    }

    // MARK: - Worksheets

    static func columnLetter(_ columnIndex: Int) -> String {
        precondition(columnIndex >= 0)
        var letter = ""
        var index = columnIndex
        repeat {
            letter.insert(Character(UnicodeScalar(UInt8(65 + index % 26))), at: letter.startIndex)
            index = index / 26 - 1
        } while index >= 0
        return letter
    }

    private static func worksheetXML(
        _ sheet: Sheet,
        sharedStringIndexes: [String: Int],
        styleIndexes: [StyleKey: Int]
    ) -> String {
        var body = ""

        if let widths = sheet.columnWidths, !widths.isEmpty {
            var cols = ""
            for (offset, width) in widths.enumerated() {
                cols += "<col min=\"\(offset + 1)\" max=\"\(offset + 1)\" width=\"\(max(width, 0))\" customWidth=\"1\"/>"
            }
            body += "<cols>\(cols)</cols>"
        }

        // Trailing empty rows and trailing empty cells carry no information;
        // dropping them keeps generated files small without touching data.
        var lastMeaningfulRow = -1
        for (offset, row) in sheet.rows.enumerated() where row.contains(where: { cellMeansSomething($0) }) {
            lastMeaningfulRow = offset
        }

        var rowsXML = ""
        var dimensionColumnCount = 0
        for rowIndex in 0...lastMeaningfulRow where lastMeaningfulRow >= 0 {
            let row = sheet.rows[rowIndex]
            var lastCellIndex = -1
            for (offset, cell) in row.enumerated() where cellMeansSomething(cell) { lastCellIndex = offset }
            guard lastCellIndex >= 0 else { continue }
            dimensionColumnCount = max(dimensionColumnCount, lastCellIndex + 1)
            var cellsXML = ""
            for cellIndex in 0...lastCellIndex {
                let cell = cellIndex < row.count ? row[cellIndex] : Cell(.text(""))
                guard cellMeansSomething(cell) else { continue }
                cellsXML += cellXML(cell, atRow: rowIndex, column: cellIndex, sharedStringIndexes: sharedStringIndexes, styleIndexes: styleIndexes)
            }
            rowsXML += "<row r=\"\(rowIndex + 1)\">\(cellsXML)</row>"
        }
        body += "<sheetData>\(rowsXML)</sheetData>"

        let validMerges = sheet.mergedRanges.filter { Self.isValidRangeReference($0) }
        if !validMerges.isEmpty {
            var merges = ""
            for range in validMerges { merges += "<mergeCell ref=\"\(XMLText.escaped(range))\"/>" }
            body += "<mergeCells count=\"\(validMerges.count)\">\(merges)</mergeCells>"
        }

        let dimensionRef: String
        if lastMeaningfulRow < 0 {
            dimensionRef = "A1"
        } else {
            dimensionRef = "A1:\(columnLetter(max(dimensionColumnCount - 1, 0)))\(lastMeaningfulRow + 1)"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <dimension ref="\(dimensionRef)"/>\(body)</worksheet>
        """
    }

    private static func cellMeansSomething(_ cell: Cell) -> Bool {
        switch cell.value {
        case .text(let text): return !text.isEmpty
        case .number(let number): return number.isFinite
        }
    }

    private static func cellXML(
        _ cell: Cell,
        atRow rowIndex: Int,
        column columnIndex: Int,
        sharedStringIndexes: [String: Int],
        styleIndexes: [StyleKey: Int]
    ) -> String {
        let reference = "\(columnLetter(columnIndex))\(rowIndex + 1)"
        let styleAttribute: String
        if let styleIndex = styleIndexes[StyleKey(bold: cell.bold, numberFormat: cell.numberFormat)], styleIndex > 0 {
            styleAttribute = " s=\"\(styleIndex)\""
        } else {
            styleAttribute = ""
        }
        switch cell.value {
        case .text(let text):
            let index = sharedStringIndexes[text] ?? 0
            return "<c r=\"\(reference)\" t=\"s\"\(styleAttribute)><v>\(index)</v></c>"
        case .number(let number):
            guard number.isFinite else { return "" }
            return "<c r=\"\(reference)\"\(styleAttribute)><v>\(numericLiteral(number))</v></c>"
        }
    }

    static func numericLiteral(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        // Swift prints exponents lowercase ("1e+25"); xsd:double takes
        // either case, but the uppercase form is what every other OOXML
        // writer emits, so match it.
        return String(value).replacingOccurrences(of: "e", with: "E")
    }

    private static func isValidRangeReference(_ reference: String) -> Bool {
        // Loose but honest: LETTERS+digits ":" LETTERS+digits. Deep
        // ordering checks belong to the caller, not the emitter.
        var parts = reference.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return false }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            var letters = false
            var digits = false
            for character in part {
                if character.isLetter && character.isASCII { letters = true }
                else if character.isNumber && character.isASCII { digits = true }
                else { return false }
            }
            guard letters && digits else { return false }
        }
        return true
    }
}
