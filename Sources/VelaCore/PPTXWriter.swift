import Foundation

/// §9.1 — the pptx emitter. Slides are absolutely positioned, so instead
/// of building a layout engine this emits fixed fill-in boxes on a 16:9
/// canvas: a centered title slide and a title+bullets slide. Content goes
/// into plain text shapes rather than placeholder-inheriting ones, which
/// is the same approach python-pptx takes for text boxes and opens
/// without repair prompts in PowerPoint, Keynote, and Slides.
///
/// Images are not in this subset yet — they need media parts plus
/// per-slide picture relationships; the plan's acceptance target is a
/// titled slide.
public struct PPTXDocument {
    public enum Layout: String {
        /// Big centered title with an optional subtitle beneath.
        case title
        /// Slide title top-left with a bulleted body below.
        case bullets
    }

    public struct Slide {
        public var layout: Layout
        public var title: String
        /// Used by `.title`.
        public var subtitle: String
        /// Used by `.bullets`.
        public var bullets: [String]

        public init(layout: Layout, title: String, subtitle: String = "", bullets: [String] = []) {
            self.layout = layout
            self.title = title
            self.subtitle = subtitle
            self.bullets = bullets
        }

        public static func titled(_ title: String, subtitle: String) -> Slide {
            Slide(layout: .title, title: title, subtitle: subtitle)
        }

        public static func bulleted(_ title: String, bullets: [String]) -> Slide {
            Slide(layout: .bullets, title: title, bullets: bullets)
        }
    }

    public var slides: [Slide]

    public init(slides: [Slide]) {
        self.slides = slides
    }

    // 16:9 canvas in EMU (English Metric Units; 914,400 per inch).
    private static let canvasWidth = 12_192_000
    private static let canvasHeight = 6_858_000
    private static let margin = 838_200
    private static let contentWidth = canvasWidth - 2 * margin

    func makePackage() throws -> OOXMLPackage {
        guard !slides.isEmpty else {
            throw DocumentEmitterError("a deck needs at least one slide")
        }
        guard slides.count <= Limits.documentMaxSlides else {
            throw DocumentEmitterError("a deck can have at most \(Limits.documentMaxSlides) slides (got \(slides.count))")
        }
        var package = OOXMLPackage()
        package.addXML("[Content_Types].xml", Self.contentTypes(slideCount: slides.count))
        package.addXML("_rels/.rels", Self.rootRelationships())
        package.addXML("docProps/core.xml", Self.coreProperties(deckTitle: slides.first?.title ?? "Presentation"))
        package.addXML("ppt/presentation.xml", Self.presentationXML(slideCount: slides.count))
        package.addXML("ppt/_rels/presentation.xml.rels", Self.presentationRelationships(slideCount: slides.count))
        for (index, slide) in slides.enumerated() {
            package.addXML(
                "ppt/slides/slide\(index + 1).xml",
                Self.slideXML(slide, shapeIDBase: 1)
            )
            package.addXML(
                "ppt/slides/_rels/slide\(index + 1).xml.rels",
                Self.slideRelationships()
            )
        }
        package.addXML("ppt/slideMasters/slideMaster1.xml", Self.slideMasterXML())
        package.addXML("ppt/slideMasters/_rels/slideMaster1.xml.rels", Self.slideMasterRelationships())
        package.addXML("ppt/slideLayouts/slideLayout1.xml", Self.slideLayoutXML())
        package.addXML("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Self.slideLayoutRelationships())
        package.addXML("ppt/theme/theme1.xml", Self.themeXML())
        return package
    }

    public func makeData() throws -> Data {
        try makePackage().makeData()
    }

    // MARK: - Package-level parts

    private static func contentTypes(slideCount: Int) -> String {
        var overrides =
            "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>" +
            "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>" +
            "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>" +
            "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>" +
            "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        for index in 1...slideCount {
            overrides += "<Override PartName=\"/ppt/slides/slide\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
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
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        </Relationships>
        """
    }

    private static func coreProperties(deckTitle: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(XMLText.escaped(deckTitle))</dc:title>\
        <dc:creator>VelaChat</dc:creator><cp:lastModifiedBy>VelaChat</cp:lastModifiedBy>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified>\
        </cp:coreProperties>
        """
    }

    // MARK: - Presentation / master / layout / theme

    private static func presentationXML(slideCount: Int) -> String {
        var ids = ""
        for index in 1...slideCount {
            ids += "<p:sldId id=\"\((255 + index))\" r:id=\"rId\(1 + index)\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        <p:sldIdLst>\(ids)</p:sldIdLst>\
        <p:sldSz cx="\((canvasWidth))" cy="\((canvasHeight))"/><p:notesSz cx="6858000" cy="9144000"/>\
        </p:presentation>
        """
    }

    private static func presentationRelationships(slideCount: Int) -> String {
        var relationships =
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        for index in 1...slideCount {
            relationships += "<Relationship Id=\"rId\(1 + index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(index).xml\"/>"
        }
        relationships += "<Relationship Id=\"rId\(2 + slideCount)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"theme/theme1.xml\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationships)</Relationships>
        """
    }

    private static func slideRelationships() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        </Relationships>
        """
    }

    private static func slideMasterXML() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
        <p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>\
        \(shapeTree(children: ""))</p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
        </p:sldMaster>
        """
    }

    private static func slideMasterRelationships() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>\
        </Relationships>
        """
    }

    private static func slideLayoutXML() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank">\
        <p:cSld name="Blank">\(shapeTree(children: ""))</p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
        </p:sldLayout>
        """
    }

    private static func slideLayoutRelationships() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>\
        </Relationships>
        """
    }

    /// A compact but schema-complete theme. The fmtScheme lists MUST have
    /// exactly three entries each — that count is what readers validate.
    private static func themeXML() -> String {
        func solid(_ color: String) -> String { "<a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill>" }
        let phClr = "<a:schemeClr val=\"phClr\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="VelaChat">\
        <a:themeElements>\
        <a:clrScheme name="VelaChat"><a:dk1><a:srgbClr val="1B1F24"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>\
        <a:dk2><a:srgbClr val="20343E"/></a:dk2><a:lt2><a:srgbClr val="EEF4F3"/></a:lt2>\
        <a:accent1><a:srgbClr val="2E7D74"/></a:accent1><a:accent2><a:srgbClr val="E07A5F"/></a:accent2>\
        <a:accent3><a:srgbClr val="457B9D"/></a:accent3><a:accent4><a:srgbClr val="8A817C"/></a:accent4>\
        <a:accent5><a:srgbClr val="B08968"/></a:accent5><a:accent6><a:srgbClr val="52796F"/></a:accent6>\
        <a:hlink><a:srgbClr val="2E7D74"/></a:hlink><a:folHlink><a:srgbClr val="457B9D"/></a:folHlink></a:clrScheme>\
        <a:fontScheme name="VelaChat"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
        <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
        <a:fmtScheme name="VelaChat">\
        <a:fillStyleLst>\(solid("FFFFFF"))<a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="100000"/></a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:shade val="80000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill>\(solid("FFFFFF"))</a:fillStyleLst>\
        <a:lnStyleLst><a:ln w="9525"><a:solidFill>\(phClr)</a:solidFill><a:prstDash val="solid"/></a:ln>\
        <a:ln w="19050"><a:solidFill>\(phClr)</a:solidFill><a:prstDash val="solid"/></a:ln>\
        <a:ln w="28575"><a:solidFill>\(phClr)</a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst>\
        <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
        <a:bgFillStyleLst>\(solid("FFFFFF"))\(solid("FFFFFF"))\(solid("FFFFFF"))</a:bgFillStyleLst>\
        </a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
        """
    }

    // MARK: - Slides

    /// The spTree boilerplate every slide/master/layout needs. `children`
    /// is the actual shapes payload.
    private static func shapeTree(children: String) -> String {
        """
        <p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
        <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\(children)</p:spTree>
        """
    }

    private static func textBox(
        id: Int,
        name: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        anchor: String,
        paragraphs: [String]
    ) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>\
        <p:txBody><a:bodyPr wrap="square" anchor="\(anchor)"/><a:lstStyle/>\(paragraphs.joined())</p:txBody></p:sp>
        """
    }

    private static func runText(_ text: String, sizeCentipoints: Int, bold: Bool, color: String) -> String {
        let rpr = """
        <a:rPr lang="en-US" sz="\(sizeCentipoints)" b="\(bold ? 1 : 0)">\
        <a:solidFill><a:srgbClr val="\(color)"/></a:solidFill></a:rPr>
        """
        return "<a:r>\(rpr)<a:t>\(XMLText.escaped(text))</a:t></a:r>"
    }

    private static func slideXML(_ slide: Slide, shapeIDBase: Int) -> String {
        var children = ""
        switch slide.layout {
        case .title:
            children += textBox(
                id: shapeIDBase + 1,
                name: "Title",
                x: margin,
                y: canvasHeight / 2 - 900_000,
                width: contentWidth,
                height: 1_400_000,
                anchor: "ctr",
                paragraphs: [
                    "<a:p><a:pPr algn=\"ctr\"/>\(runText(slide.title, sizeCentipoints: 4_000, bold: true, color: "1B1F24"))</a:p>",
                ]
            )
            if !slide.subtitle.isEmpty {
                children += textBox(
                    id: shapeIDBase + 2,
                    name: "Subtitle",
                    x: margin,
                    y: canvasHeight / 2 + 700_000,
                    width: contentWidth,
                    height: 900_000,
                    anchor: "t",
                    paragraphs: [
                        "<a:p><a:pPr algn=\"ctr\"/>\(runText(slide.subtitle, sizeCentipoints: 2_000, bold: false, color: "5A6570"))</a:p>",
                    ]
                )
            }
        case .bullets:
            children += textBox(
                id: shapeIDBase + 1,
                name: "Title",
                x: margin,
                y: 365_125,
                width: contentWidth,
                height: 1_200_000,
                anchor: "t",
                paragraphs: [
                    "<a:p>\(runText(slide.title, sizeCentipoints: 3_200, bold: true, color: "1B1F24"))</a:p>",
                ]
            )
            var paragraphElements: [String] = []
            for bullet in slide.bullets where !bullet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paragraphElements.append(
                    """
                    <a:p><a:pPr marL="285750" indent="-285750"><a:buChar char="•"/></a:pPr>\
                    \(runText(bullet, sizeCentipoints: 1_800, bold: false, color: "33383E"))</a:p>
                    """
                )
            }
            if paragraphElements.isEmpty {
                paragraphElements.append("<a:p><a:endParaRPr lang=\"en-US\"/></a:p>")
            }
            children += textBox(
                id: shapeIDBase + 2,
                name: "Content",
                x: margin,
                y: 1_825_625,
                width: contentWidth,
                height: canvasHeight - 1_825_625 - margin,
                anchor: "t",
                paragraphs: paragraphElements
            )
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
        <p:cSld>\(shapeTree(children: children))</p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
    }
}
