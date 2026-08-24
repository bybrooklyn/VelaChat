import Foundation

/// §9.1 — the docx emitter. Subset covering the 80% case: headings,
/// paragraphs with bold/italic runs, bulleted and numbered lists (a real
/// numbering part, not bullet glyphs faked into plain paragraphs), and
/// bordered tables with an optional bold header row.
public struct DOCXDocument {
    public struct Run {
        public var text: String
        public var bold: Bool
        public var italic: Bool

        public init(_ text: String, bold: Bool = false, italic: Bool = false) {
            self.text = text
            self.bold = bold
            self.italic = italic
        }
    }

    public enum Block {
        /// Levels are clamped to 1...4.
        case heading(level: Int, text: String)
        case paragraph([Run])
        case bullet(String)
        case numbered(String)
        /// Rows of plain cell text. When `headerFirstRow` is set the first
        /// row renders bold on a light fill.
        case table(rows: [[String]], headerFirstRow: Bool)

        public static func paragraph(_ text: String) -> Block { .paragraph([Run(text)]) }
    }

    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    // MARK: - Emission

    func makePackage() throws -> OOXMLPackage {
        var hasLists = false
        for block in blocks {
            if case .bullet = block { hasLists = true }
            if case .numbered = block { hasLists = true }
        }
        let blocks: [Block] = self.blocks.isEmpty ? [.paragraph("")] : self.blocks
        var package = OOXMLPackage()
        package.addXML("[Content_Types].xml", Self.contentTypes(hasNumbering: hasLists))
        package.addXML("_rels/.rels", Self.rootRelationships())
        package.addXML("docProps/core.xml", Self.coreProperties())
        package.addXML("word/_rels/document.xml.rels", Self.documentRelationships(hasNumbering: hasLists))
        package.addXML("word/styles.xml", Self.stylesXML())
        if hasLists {
            package.addXML("word/numbering.xml", Self.numberingXML())
        }
        package.addXML("word/document.xml", Self.documentXML(blocks))
        return package
    }

    public func makeData() throws -> Data {
        try makePackage().makeData()
    }

    // MARK: - Parts

    private static func contentTypes(hasNumbering: Bool) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        \(hasNumbering ? "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>" : "")\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        </Types>
        """
    }

    private static func rootRelationships() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
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

    private static func documentRelationships(hasNumbering: Bool) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        \(hasNumbering ? "<Relationship Id=\"rIdNumbering\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>" : "")\
        </Relationships>
        """
    }

    private static func stylesXML() -> String {
        // Sizes are half-points (Word convention): 22 = 11pt body,
        // 32 = 16pt H1. outlineLvl is what makes Word show these in its
        // navigation pane; keepNext keeps a heading attached to its text.
        func headingStyle(_ level: Int, sizeHalfPoints: Int) -> String {
            """
            <w:style w:type="paragraph" w:styleId="Heading\(level)">\
            <w:name w:val="heading \(level)"/><w:basedOn w:val="Normal"/><w:qFormat/>\
            <w:pPr><w:keepNext/><w:spacing w:before="\((4 - level + 1) * 120)" w:after="120"/><w:outlineLvl w:val="\(level - 1)"/></w:pPr>\
            <w:rPr><w:b/><w:sz w:val="\(sizeHalfPoints)"/></w:rPr></w:style>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/>\
        <w:pPr><w:spacing w:after="120"/></w:pPr></w:style>\
        \(headingStyle(1, sizeHalfPoints: 32))\
        \(headingStyle(2, sizeHalfPoints: 26))\
        \(headingStyle(3, sizeHalfPoints: 24))\
        \(headingStyle(4, sizeHalfPoints: 22))\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/></w:pPr></w:style>\
        </w:styles>
        """
    }

    private static func numberingXML() -> String {
        // One abstract definition per list kind, one concrete num each;
        // all bullets in the document share numId 1, all numbered items
        // numId 2. Restarting numbering per list would need one abstract
        // num per list — out of subset.
        func level(_ format: String, text: String) -> String {
            """
            <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="\(format)"/><w:lvlText w:val="\(text)"/>\
            <w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="singleLevel"/>\(level("bullet", text: "•"))</w:abstractNum>\
        <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="singleLevel"/>\(level("decimal", text: "%1."))</w:abstractNum>\
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>\
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>\
        </w:numbering>
        """
    }

    // MARK: - Document body

    static func runXML(_ run: Run) -> String {
        var rpr = ""
        if run.bold || run.italic {
            rpr = "<w:rPr>\(run.bold ? "<w:b/>" : "")\(run.italic ? "<w:i/>" : "")</w:rPr>"
        }
        return "<w:r>\(rpr)<w:t xml:space=\"preserve\">\(XMLText.escaped(run.text))</w:t></w:r>"
    }

    static func paragraphXML(_ runs: [Run], properties: String = "", style: String? = nil) -> String {
        var ppr = ""
        if let style { ppr += "<w:pStyle w:val=\"\(style)\"/>" }
        ppr += properties
        let wrapped = ppr.isEmpty ? "" : "<w:pPr>\(ppr)</w:pPr>"
        let body = runs.isEmpty ? "" : runs.map(runXML).joined()
        // A paragraph with no runs still needs to exist (empty lines are
        // legitimate spacing), but must not be self-closed wrong.
        return "<w:p>\(wrapped)\(body)</w:p>"
    }

    private static func documentXML(_ blocks: [Block]) -> String {
        var body = ""
        for block in blocks {
            switch block {
            case .heading(let rawLevel, let text):
                let level = min(max(rawLevel, 1), 4)
                body += paragraphXML([Run(text)], style: "Heading\(level)")
            case .paragraph(let runs):
                body += paragraphXML(runs)
            case .bullet(let text):
                let numbering = "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr>"
                body += paragraphXML(
                    [Run(text)],
                    properties: numbering,
                    style: "ListParagraph"
                )
            case .numbered(let text):
                let numbering = "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"2\"/></w:numPr>"
                body += paragraphXML(
                    [Run(text)],
                    properties: numbering,
                    style: "ListParagraph"
                )
            case .table(let rows, let headerFirstRow):
                body += tableXML(rows: rows, headerFirstRow: headerFirstRow)
            }
        }
        // Section properties give the document sane defaults (US Letter,
        // 1in margins); without them Word applies its own, which varies.
        body += """
        <w:p><w:pPr><w:sectPr>\
        <w:pgSz w:w="12240" w:h="15840"/>\
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720"/>\
        </w:sectPr></w:pPr></w:p>
        """
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:body>\(body)</w:body></w:document>
        """
    }

    private static func tableXML(rows: [[String]], headerFirstRow: Bool) -> String {
        guard !rows.isEmpty else { return "" }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return "" }
        let gridWidth = 9360 / columnCount  // usable page width in twips
        var grid = ""
        for _ in 0..<columnCount {
            grid += "<w:gridCol w:w=\"\(gridWidth)\"/>"
        }
        var tableRows = ""
        for (rowIndex, row) in rows.enumerated() {
            let isHeader = headerFirstRow && rowIndex == 0
            var cells = ""
            for columnIndex in 0..<columnCount {
                let text = columnIndex < row.count ? row[columnIndex] : ""
                let shading = isHeader
                    ? "<w:shd w:val=\"clear\" w:fill=\"F2F2F2\"/>"
                    : ""
                let boldPrefix = isHeader ? [Run(text, bold: true)] : [Run(text)]
                cells += """
                <w:tc><w:tcPr><w:tcW w:w="\(gridWidth)" w:type="dxa"/>\(shading)</w:tcPr>\
                \(paragraphXML(boldPrefix))</w:tc>
                """
            }
            tableRows += "<w:tr>\(cells)</w:tr>"
        }
        return """
        <w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>\
        <w:tblBorders>\
        <w:top w:val="single" w:sz="4" w:color="CCCCCC"/><w:left w:val="single" w:sz="4" w:color="CCCCCC"/>\
        <w:bottom w:val="single" w:sz="4" w:color="CCCCCC"/><w:right w:val="single" w:sz="4" w:color="CCCCCC"/>\
        <w:insideH w:val="single" w:sz="4" w:color="CCCCCC"/><w:insideV w:val="single" w:sz="4" w:color="CCCCCC"/>\
        </w:tblBorders></w:tblPr>\
        <w:tblGrid>\(grid)</w:tblGrid>\(tableRows)</w:tbl>
        """
    }
}
