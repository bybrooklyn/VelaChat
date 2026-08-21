import AppKit
import VelaCore
import CoreText

/// Conversation export: clean Markdown, and a real paginated PDF drawn
/// with CoreText (CTFramesetter) — chosen over ImageRenderer (one giant
/// unpaginated raster) and NSPrintOperation (needs live view + panel
/// plumbing) because it produces deterministic multi-page vector text.
@MainActor
enum ConversationExporter {
    static func markdown(for conversation: Conversation) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        var lines: [String] = [
            "# \(conversation.title)",
            "",
            "_Exported from VelaChat · \(dateFormatter.string(from: Date())) · model: \(conversation.model.isEmpty ? "—" : conversation.model)_",
            ""
        ]
        for message in conversation.realMessages {
            lines.append(message.role == "user" ? "## You" : "## Assistant\(message.modelID.map { " (\($0))" } ?? "")")
            lines.append("")
            lines.append(message.content)
            if !message.attachments.isEmpty {
                lines.append("")
                lines.append("_Attachments: \(message.attachments.map(\.filename).joined(separator: ", "))_")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func exportMarkdown(_ conversation: Conversation) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName(conversation, ext: "md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown(for: conversation).write(to: url, atomically: true, encoding: .utf8)
    }

    static func exportPDF(_ conversation: Conversation) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName(conversation, ext: "pdf")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writePDF(conversation, to: url)
    }

    private static func suggestedName(_ conversation: Conversation, ext: String) -> String {
        let base = conversation.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(base.isEmpty ? "conversation" : String(base.prefix(60))).\(ext)"
    }

    private static func writePDF(_ conversation: Conversation, to url: URL) {
        let text = attributedTranscript(conversation)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter
        let margin: CGFloat = 54
        let contentRect = mediaBox.insetBy(dx: margin, dy: margin)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var location = 0
        let length = text.length
        while location < length {
            context.beginPDFPage(nil)
            let path = CGPath(rect: contentRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            location += visible.length
        }
        context.closePDF()
    }

    private static func attributedTranscript(_ conversation: Conversation) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titleFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let roleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        func append(_ string: String, font: NSFont, color: NSColor = .black, spacingAfter: CGFloat = 6) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = spacingAfter
            paragraph.lineHeightMultiple = 1.15
            result.append(NSAttributedString(string: string + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph
            ]))
        }
        append(conversation.title, font: titleFont, spacingAfter: 12)
        for message in conversation.realMessages {
            let speaker = message.role == "user" ? "YOU" : "ASSISTANT\(message.modelID.map { " · \($0)" } ?? "")"
            append(speaker, font: roleFont, color: NSColor(calibratedWhite: 0.35, alpha: 1), spacingAfter: 2)
            append(message.content, font: bodyFont, spacingAfter: 12)
        }
        return result
    }
}
