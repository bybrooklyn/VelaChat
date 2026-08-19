import Foundation
import PDFKit

/// A file attached to a message. Images get real multimodal wiring (base64
/// content blocks) for vision-capable models; text/code/PDF are folded into
/// the outgoing message as a labeled block, since that works over plain
/// text with every provider without touching any wire format at all.
struct Attachment: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case image, text, code, pdf, git
    }

    let id: UUID
    var kind: Kind
    var filename: String
    var mimeType: String
    /// Raw image bytes for `.image`; UTF-8 text for everything else
    /// (already-extracted text for `.pdf`).
    var data: Data
    /// Original byte count before any truncation — kept for the
    /// attachment inspector even if `data` itself was shortened.
    var originalByteCount: Int
    /// Inclusion control: attached but not sent. Toggled from the
    /// composer's attachment chip.
    var isIncluded: Bool = true

    init(id: UUID = UUID(), kind: Kind, filename: String, mimeType: String, data: Data, originalByteCount: Int? = nil, isIncluded: Bool = true) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.originalByteCount = originalByteCount ?? data.count
        self.isIncluded = isIncluded
    }

    var textContent: String? {
        guard kind != .image else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var estimatedTokens: Int {
        if kind == .image {
            // No provider publishes an exact formula VelaChat can rely on;
            // this is the widely-used rough OpenAI vision estimate for a
            // single moderate-resolution image, not an exact figure.
            return 765
        }
        return max(1, data.count / 4)
    }

    var sizeLabel: String {
        let bytes = Double(originalByteCount)
        if bytes >= 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f KB", bytes / 1_000) }
        return "\(originalByteCount) B"
    }

    /// A hard cap so one huge pasted file doesn't blow the whole context
    /// budget silently — real summarization (compressing instead of just
    /// cutting off) is a documented gap, not built yet.
    static let maxTextBytes = 60_000

    static func fromText(filename: String, kind: Kind, content: String, mimeType: String) -> Attachment {
        let full = Data(content.utf8)
        let truncated = full.count > maxTextBytes
        let bytes = truncated ? full.prefix(maxTextBytes) : full
        var text = String(data: bytes, encoding: .utf8) ?? content
        if truncated {
            text += "\n\n[…truncated — file was \(full.count) bytes, showing the first \(maxTextBytes)]"
        }
        return Attachment(kind: kind, filename: filename, mimeType: mimeType, data: Data(text.utf8), originalByteCount: full.count)
    }

    static func fromPDF(filename: String, data pdfData: Data) -> Attachment? {
        guard let document = PDFDocument(data: pdfData) else { return nil }
        var text = ""
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            text += (page.string ?? "") + "\n\n"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var attachment = fromText(filename: filename, kind: .pdf, content: trimmed, mimeType: "application/pdf")
        attachment.originalByteCount = pdfData.count
        return attachment
    }

    /// Lightweight git awareness: detect a real repo, read its branch and
    /// working-tree status/diff via the actual `git` binary (read-only
    /// commands only — no `add`/`commit`/anything that touches the repo),
    /// and fold that into a text attachment. No standing workspace concept,
    /// no bash tool — a one-shot inspection at attach time, deliberately
    /// scoped down from the full sandbox-workstation idea.
    static func fromGitFolder(url: URL) -> Attachment? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        guard fm.fileExists(atPath: url.appendingPathComponent(".git").path) else { return nil }

        let branch = runGitReadOnly(["branch", "--show-current"], in: url) ?? "(detached HEAD)"
        let status = runGitReadOnly(["status", "--short"], in: url) ?? ""
        let diffStat = runGitReadOnly(["diff", "--stat"], in: url) ?? ""
        let lastCommit = runGitReadOnly(["log", "-1", "--format=%h %s"], in: url) ?? ""

        var content = "Git repository: \(url.lastPathComponent)\nBranch: \(branch)"
        if !lastCommit.isEmpty { content += "\nLast commit: \(lastCommit)" }
        content += status.isEmpty ? "\n\nWorking tree clean." : "\n\nUncommitted changes (git status --short):\n\(status)"
        if !diffStat.isEmpty { content += "\n\nDiff summary (git diff --stat):\n\(diffStat)" }

        return fromText(filename: url.lastPathComponent, kind: .git, content: content, mimeType: "text/plain")
    }

    /// Every call site here passes a fixed, hardcoded argument list — never
    /// user-typed input — so there's no shell-injection surface; `Process`
    /// with an argument array never goes through a shell anyway.
    private static func runGitReadOnly(_ arguments: [String], in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// A `data:` URI for an image attachment — the shape every OpenAI-
    /// compatible `image_url` content part and Anthropic's base64 image
    /// source both start from.
    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    static func codeKind(forExtension ext: String) -> Bool {
        let codeExtensions: Set<String> = [
            "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "rb", "java",
            "kt", "c", "cpp", "h", "hpp", "cs", "php", "sh", "bash", "zsh",
            "sql", "html", "css", "json", "yaml", "yml", "toml", "xml", "md"
        ]
        return codeExtensions.contains(ext.lowercased())
    }
}
