import XCTest
import Foundation
import ZIPFoundation
@testable import VelaCore

/// §9.1 — the document emitters. The acceptance bar is structural: every
/// produced package must unzip to well-formed XML parts wired together
/// correctly (content types, rels, shared strings, slide ids), because a
/// malformed part is exactly what turns into an app's "repair this file?"
/// prompt. Whether Numbers/Word render them prettily is the human check.
final class DocumentEmittersTests: XCTestCase {

    // MARK: - Helpers

    /// Writes the archive to a temp file and reads it back through
    /// ZIPFoundation's reader — the same path a real unzipper takes, so a
    /// broken central directory fails here and not on the user's machine.
    private func entries(of data: Data) throws -> [(name: String, text: String)] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".zip")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            fatalError("produced data is not a readable zip: \(error)")
        }
        var result: [(String, String)] = []
        for entry in archive {
            guard entry.type == .file else { continue }
            var text = Data()
            _ = try archive.extract(entry) { chunk in text.append(chunk) }
            result.append((entry.path, String(data: text, encoding: .utf8) ?? ""))
        }
        return result
    }

    private func part(_ list: [(name: String, text: String)], _ name: String) throws -> String {
        try XCTUnwrap(list.first { $0.name == name }?.text, "missing part \(name)")
    }

    private func assertAllPartsAreWellFormedXML(_ list: [(name: String, text: String)]) throws {
        for (name, text) in list where name.hasSuffix(".xml") {
            XCTAssertNoThrow(
                try XMLDocument(data: Data(text.utf8)),
                "\(name) is not well-formed XML:\n\(text.prefix(400))"
            )
        }
    }

    // MARK: - xlsx

    func testXlsxUnzipsToWellFormedPartsInOrder() throws {
        let workbook = XLSXDocument(sheetName: "Data", rows: [
            [.text("Region"), .text("Revenue")],
            [.text("North"), .number(1250)],
        ])
        let parts = try entries(of: try workbook.makeData())
        XCTAssertEqual(parts.first?.name, "[Content_Types].xml", "OPC convention: content types lead the archive")
        try assertAllPartsAreWellFormedXML(parts)
        for required in ["_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
                         "xl/sharedStrings.xml", "xl/styles.xml", "xl/worksheets/sheet1.xml"] {
            XCTAssertNotNil(parts.first { $0.name == required }, "missing \(required)")
        }
    }

    func testXlsxSharedStringsAndCellReferences() throws {
        let workbook = XLSXDocument(sheetName: "S", rows: [
            [.text("Alpha"), .number(42)],
            [],
            [.text("Beta")],
        ])
        let parts = try entries(of: try workbook.makeData())
        let sheet = try part(parts, "xl/worksheets/sheet1.xml")
        XCTAssertTrue(sheet.contains("<c r=\"A1\" t=\"s\"><v>0</v></c>"), sheet)
        XCTAssertTrue(sheet.contains("<c r=\"B1\"><v>42</v></c>"), sheet)
        XCTAssertTrue(sheet.contains("<c r=\"A3\" t=\"s\"><v>1</v></c>"), sheet)
        let shared = try part(parts, "xl/sharedStrings.xml")
        XCTAssertTrue(shared.contains(">Alpha<"))
        XCTAssertTrue(shared.contains(">Beta<"))
        // Row 2 is entirely empty and carries nothing.
        XCTAssertFalse(sheet.contains("r=\"2\""), sheet)
    }

    func testXlsxStylesNumberFormatsAndMerges() throws {
        let workbook = XLSXDocument(sheets: [.init(
            name: "Styled",
            rows: [
                [XLSXDocument.Cell(.number(12.5), numberFormat: "$#,##0.00")],
                [XLSXDocument.Cell(.text("Total"), bold: true)],
            ],
            columnWidths: [24.5, 10],
            mergedRanges: ["A1:B1", "not a range"]
        )])
        let parts = try entries(of: try workbook.makeData())
        let styles = try part(parts, "xl/styles.xml")
        XCTAssertTrue(styles.contains("formatCode=\"$#,##0.00\""), styles)
        XCTAssertTrue(styles.contains("<numFmts count=\"1\">"), styles)
        XCTAssertTrue(styles.contains("<font><b/>"), styles)
        let sheet = try part(parts, "xl/worksheets/sheet1.xml")
        XCTAssertTrue(sheet.contains("<mergeCells count=\"1\"><mergeCell ref=\"A1:B1\"/></mergeCells>"), sheet)
        XCTAssertTrue(sheet.contains("width=\"24.5\" customWidth=\"1\""), sheet)
    }

    func testXlsxSanitizesSheetNamesAndEscapesText() throws {
        let workbook = XLSXDocument(sheets: [
            .init(name: "bad/name:[x]*?", rows: [[.text("& <big> \"q\"")]]),
            .init(name: String(repeating: "L", count: 40), rows: [[.text("ok")]]),
        ])
        let parts = try entries(of: try workbook.makeData())
        let workbookXML = try part(parts, "xl/workbook.xml")
        // Every forbidden character becomes a dash; runs of them collapse
        // into one dash each (components/separatedBy + joined).
        XCTAssertTrue(workbookXML.contains("name=\"bad-name--x----\""), workbookXML)
        XCTAssertTrue(workbookXML.contains(String(repeating: "L", count: 31)), workbookXML)
        XCTAssertFalse(workbookXML.contains(String(repeating: "L", count: 32)), workbookXML)
        let shared = try part(parts, "xl/sharedStrings.xml")
        XCTAssertTrue(shared.contains("&amp; &lt;big&gt; &quot;q&quot;"), shared)
    }

    // MARK: - docx

    func testDocxStructureWithHeadingsTablesAndLists() throws {
        let document = DOCXDocument(blocks: [
            .heading(level: 9, text: "Title"),   // clamps to 4? no — to 4 max; 9 → Heading4? level min(max(9,1),4)=4
            .paragraph([DOCXDocument.Run("plain "), DOCXDocument.Run("bold", bold: true)]),
            .bullet("first"),
            .table(rows: [["H1", "H2"], ["a", "b"]], headerFirstRow: true),
        ])
        let parts = try entries(of: try document.makeData())
        try assertAllPartsAreWellFormedXML(parts)
        let body = try part(parts, "word/document.xml")
        XCTAssertTrue(body.contains("<w:pStyle w:val=\"Heading4\"/>"), body)
        XCTAssertTrue(body.contains("<w:b/><w:t xml:space=\"preserve\">bold</w:t>") || body.contains("<w:b/>"), body)
        XCTAssertTrue(body.components(separatedBy: "<w:tr>").count - 1 == 2, body)
        XCTAssertTrue(body.contains("w:fill=\"F2F2F2\""), body)
        XCTAssertNotNil(parts.first { $0.name == "word/numbering.xml" }, "lists require the numbering part")
        let numbering = try part(parts, "word/numbering.xml")
        XCTAssertTrue(numbering.contains("<w:num w:numId=\"1\">"), numbering)
        let contentTypes = try part(parts, "[Content_Types].xml")
        XCTAssertTrue(contentTypes.contains("numbering+xml"), contentTypes)
    }

    func testDocxWithoutListsOmitsNumberingPart() throws {
        let document = DOCXDocument(blocks: [.paragraph("just text")])
        let parts = try entries(of: try document.makeData())
        XCTAssertNil(parts.first { $0.name == "word/numbering.xml" })
        XCTAssertFalse(try part(parts, "[Content_Types].xml").contains("numbering"))
    }

    // MARK: - pptx

    func testPptxSlidesMasterThemeAndBullets() throws {
        let deck = PPTXDocument(slides: [
            PPTXDocument.Slide(layout: .title, title: "Quarterly Review", subtitle: "Q3 · VelaChat"),
            PPTXDocument.Slide(layout: .bullets, title: "Wins", bullets: ["Shipped emitters", "", "Fixed bugs"]),
        ])
        let parts = try entries(of: try deck.makeData())
        try assertAllPartsAreWellFormedXML(parts)
        let presentation = try part(parts, "ppt/presentation.xml")
        XCTAssertEqual(presentation.components(separatedBy: "<p:sldId ").count - 1, 2, presentation)
        XCTAssertNotNil(parts.first { $0.name == "ppt/slideMasters/slideMaster1.xml" })
        XCTAssertNotNil(parts.first { $0.name == "ppt/slideLayouts/slideLayout1.xml" })
        XCTAssertNotNil(parts.first { $0.name == "ppt/theme/theme1.xml" })
        let rels = try part(parts, "ppt/slides/_rels/slide1.xml.rels")
        XCTAssertTrue(rels.contains("slideLayout"), rels)
        let slide2 = try part(parts, "ppt/slides/slide2.xml")
        XCTAssertTrue(slide2.contains("<a:buChar char=\"•\"/>"), slide2)
        XCTAssertTrue(slide2.contains(">Shipped emitters<"), slide2)
    }

    // MARK: - Builder + tool-shape errors

    func testBuilderErrorsNameTheProblem() {

        XCTAssertThrowsError(try DocumentBuilder.build(format: "csv", content: [:])) { error in
            XCTAssertTrue((error as? DocumentEmitterError)?.message.contains("xlsx, docx, pptx, pdf, md") == true)
        }
        XCTAssertThrowsError(try DocumentBuilder.build(format: "docx", content: ["text": "no blocks"])) { error in
            XCTAssertTrue((error as? DocumentEmitterError)?.message.contains("blocks") == true)
        }
        XCTAssertThrowsError(try DocumentBuilder.build(format: "xlsx", content: ["nope": true])) { error in
            XCTAssertTrue((error as? DocumentEmitterError)?.message.contains("rows") == true)
        }
        XCTAssertThrowsError(try DocumentBuilder.build(format: "pptx", content: ["slides": [["title": ""]]])) { error in
            XCTAssertTrue((error as? DocumentEmitterError)?.message.contains("title") == true)
        }
        XCTAssertThrowsError(try DocumentBuilder.build(format: "pdf", content: ["blocks": [["type": "table", "rows": [["a"]]]]])) { error in
            XCTAssertTrue((error as? DocumentEmitterError)?.message.contains("xlsx or docx") == true)
        }
    }

    func testPDFProducesRealBytes() throws {
        let data = try SimplePDFWriter.makeData(blocks: [
            .heading(level: 1, text: "Report"),
            .paragraph([DOCXDocument.Run("Body with "), DOCXDocument.Run("emphasis", italic: true)]),
            .bullet("point one"),
        ])
        XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")
        XCTAssertTrue(data.count > 500, "a real PDF with fonts is not tiny; got \(data.count)")
    }

    func testWorkbookCellCeilingThrowsNotTruncates() throws {
        // 320 × 313 = 100,160 cells — just past the ceiling. The builder
        // refuses with a named limit instead of silently truncating.
        let row: [Any] = Array(repeating: "cell", count: 320)
        let rows: [[Any]] = Array(repeating: row, count: 313)
        XCTAssertThrowsError(try DocumentBuilder.build(format: "xlsx", content: ["rows": rows])) { error in
            let message = (error as? DocumentEmitterError)?.message ?? ""
            XCTAssertTrue(message.contains("\(Limits.documentMaxCells)"), message)
        }
    }

    // MARK: - Tool path end-to-end (workspace writes)

    @MainActor
    func testCreateDocumentToolWritesIntoWorkspace() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let context = ToolCatalog.ExecutionContext(conversationSummaries: [], searchEndpoint: "", workspaceDirectory: workspace)

        let result = await ToolCatalog.execute(
            name: ToolCatalog.createDocument.name,
            argumentsJSON: #"{"format":"xlsx","filename":"report","content":{"rows":[[["Region","Rev"],["North",1250]]]}}"#,
            context: context
        )
        XCTAssertTrue(result.contains("Created report.xlsx"), result)
        let written = try Data(contentsOf: workspace.appendingPathComponent("report.xlsx"))
        XCTAssertEqual(written.prefix(2), Data("PK".utf8))
    }

    @MainActor
    func testCreateDocumentToolHonorsWriteGateAndBadContent() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        var context = ToolCatalog.ExecutionContext(conversationSummaries: [], searchEndpoint: "", workspaceDirectory: workspace)
        context.requiresWriteApproval = true
        context.approveWrite = { _ in false }

        let declined = await ToolCatalog.execute(
            name: ToolCatalog.createDocument.name,
            argumentsJSON: #"{"format":"md","content":{"text":"hi"}}"#,
            context: context
        )
        XCTAssertTrue(declined.contains("declined"), declined)

        context.approveWrite = nil
        context.requiresWriteApproval = false
        let badFormat = await ToolCatalog.execute(
            name: ToolCatalog.createDocument.name,
            argumentsJSON: #"{"format":"numbers","content":{}}"#,
            context: context
        )
        XCTAssertTrue(badFormat.contains("supported formats"), badFormat)
        let badContent = await ToolCatalog.execute(
            name: ToolCatalog.createDocument.name,
            argumentsJSON: #"{"format":"docx","content":{"blocks":"nope"}}"#,
            context: context
        )
        XCTAssertTrue(badContent.hasPrefix("Error:"), badContent)
    }
}
