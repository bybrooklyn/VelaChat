import Foundation
import CoreText
import CoreGraphics

/// §9.1 — the PDF half of `create_document`. Renders the same block model
/// as the docx emitter (headings, paragraphs with bold/italic runs,
/// bullets) into a paginated PDF using only CoreText + CoreGraphics, so
/// it lives in VelaCore beside the other emitters. Tables are the one
/// deliberate gap: CoreText has no table layout and faking columns would
/// produce exactly the kind of broken output this section refuses — the
/// error tells the caller to use xlsx or docx for tabular content.
///
/// Pagination is the same CTFramesetter walk `ConversationExporter` uses
/// for transcripts; the difference is that fonts come from CTFont
/// directly rather than NSFont.
enum SimplePDFWriter {

    static func makeData(blocks: [DOCXDocument.Block]) throws -> Data {
        let text = try attributedBody(blocks) as NSAttributedString
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter
        let margin: CGFloat = 54
        let contentRect = mediaBox.insetBy(dx: margin, dy: margin)

        // CGDataConsumer over NSMutableData keeps this pure bytes-in-
        // bytes-out (the exporter writes straight to a save-panel URL;
        // the tool path needs Data to hand back through its write gate).
        let mutable = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutable),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocumentEmitterError("could not create a PDF context.")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var location = 0
        let length = text.length
        while location < length {
            context.beginPDFPage(nil)
            let path = CGPath(rect: contentRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }  // defensive: no infinite loop on zero-progress frames
            location += visible.length
        }
        context.closePDF()
        return mutable as Data
    }

    // MARK: - Attributed body

    private static func bodyFont() -> CTFont { CTFontCreateWithName("Helvetica" as CFString, 11, nil) }
    private static func headingFont(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil) }

    private static func paragraphStyle(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 6) -> CTParagraphStyle {
        // The settings array holds raw pointers read by
        // CTParagraphStyleCreate below, so the backing storage must stay
        // alive until that call returns — explicit allocations freed by
        // defer do exactly that (defer fires after creation).
        let afterStorage = UnsafeMutablePointer<CGFloat>.allocate(capacity: 1)
        afterStorage.pointee = spacingAfter
        defer { afterStorage.deallocate() }
        var settings: [CTParagraphStyleSetting] = [
            CTParagraphStyleSetting(
                spec: .paragraphSpacing,
                valueSize: MemoryLayout<CGFloat>.size,
                value: afterStorage
            ),
        ]
        if spacingBefore > 0 {
            let beforeStorage = UnsafeMutablePointer<CGFloat>.allocate(capacity: 1)
            beforeStorage.pointee = spacingBefore
            defer { beforeStorage.deallocate() }
            settings.append(CTParagraphStyleSetting(
                spec: .paragraphSpacingBefore,
                valueSize: MemoryLayout<CGFloat>.size,
                value: beforeStorage
            ))
        }
        return CTParagraphStyleCreate(settings, settings.count)
    }

    private static func append(
        _ result: NSMutableAttributedString,
        _ string: String,
        font: CTFont,
        paragraphStyle: CTParagraphStyle
    ) {
        result.append(NSAttributedString(string: string + "\n", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.07, alpha: 1),
            kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraphStyle,
        ]))
    }

    /// Runs flatten to styled text spans; tables refuse loudly.
    private static func attributedBody(_ blocks: [DOCXDocument.Block]) throws -> NSAttributedString {
        guard !blocks.isEmpty else {
            throw DocumentEmitterError("pdf content needs at least one block.")
        }
        let result = NSMutableAttributedString()
        for block in blocks {
            switch block {
            case .heading(let rawLevel, let text):
                let level = min(max(rawLevel, 1), 4)
                let sizes: [CGFloat] = [20, 16, 14, 12]
                append(result, text, font: headingFont(sizes[level - 1]), paragraphStyle: paragraphStyle(spacingBefore: 10))
            case .paragraph(let runs):
                for run in runs where !run.text.isEmpty {
                    let font = run.bold ? CTFontCreateCopyWithSymbolicTraits(bodyFont(), 11, nil, .boldTrait, .boldTrait) ?? bodyFont()
                        : run.italic ? CTFontCreateCopyWithSymbolicTraits(bodyFont(), 11, nil, .italicTrait, .italicTrait) ?? bodyFont()
                        : bodyFont()
                    result.append(NSAttributedString(string: run.text, attributes: [
                        kCTFontAttributeName as NSAttributedString.Key: font,
                        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.07, alpha: 1),
                    ]))
                }
                append(result, "", font: bodyFont(), paragraphStyle: paragraphStyle())
            case .bullet(let text):
                append(result, "•  " + text, font: bodyFont(), paragraphStyle: paragraphStyle(spacingAfter: 3))
            case .numbered(let text):
                append(result, "1.  " + text, font: bodyFont(), paragraphStyle: paragraphStyle(spacingAfter: 3))
            case .table:
                throw DocumentEmitterError("pdf output cannot render tables — put tabular content in an xlsx or docx document instead.")
            }
        }
        return result as CFAttributedString
    }
}
