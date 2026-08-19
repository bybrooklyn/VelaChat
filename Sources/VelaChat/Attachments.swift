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
    ///
    /// Image bytes are NOT encoded into the conversation history. That
    /// history lives in `UserDefaults`, which is read into memory whole at
    /// launch and rewritten on every save — a handful of screenshots there
    /// meant tens of megabytes of base64 in a preferences plist. Images
    /// are written to a blob store on disk instead and loaded lazily; text
    /// attachments are small and stay inline where they're simplest.
    var data: Data {
        get {
            if let inlineData { return inlineData }
            guard let blobID else { return Data() }
            return AttachmentStore.load(blobID) ?? Data()
        }
        set {
            if kind == .image, newValue.count > Limits.inlineAttachmentBytes {
                blobID = AttachmentStore.save(newValue, suggestedID: blobID ?? id)
                inlineData = nil
            } else {
                inlineData = newValue
                blobID = nil
            }
        }
    }

    private var inlineData: Data?
    private var blobID: UUID?
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
        self.originalByteCount = originalByteCount ?? data.count
        self.isIncluded = isIncluded
        self.data = data  // routes through the setter: big images go to disk
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, filename, mimeType, data, originalByteCount, isIncluded, blobID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        filename = try container.decode(String.self, forKey: .filename)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        originalByteCount = try container.decodeIfPresent(Int.self, forKey: .originalByteCount) ?? 0
        isIncluded = try container.decodeIfPresent(Bool.self, forKey: .isIncluded) ?? true
        blobID = try container.decodeIfPresent(UUID.self, forKey: .blobID)
        // Histories written before the blob store keep their bytes inline;
        // they're read here and migrate to disk on the next save.
        inlineData = try container.decodeIfPresent(Data.self, forKey: .data)
        if kind == .image, let inlineData, inlineData.count > Limits.inlineAttachmentBytes {
            blobID = AttachmentStore.save(inlineData, suggestedID: id)
            self.inlineData = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(filename, forKey: .filename)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(originalByteCount, forKey: .originalByteCount)
        try container.encode(isIncluded, forKey: .isIncluded)
        try container.encodeIfPresent(blobID, forKey: .blobID)
        try container.encodeIfPresent(inlineData, forKey: .data)
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

    /// Shared file loader (composer + quick chat): image/PDF/text/code by
    /// extension; nil for directories and undecodable binaries.
    static func fromFile(url: URL) -> Attachment? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent
        let imageMimes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "heic": "image/heic"]
        if let mime = imageMimes[ext] {
            return Attachment(kind: .image, filename: filename, mimeType: mime, data: data)
        }
        if ext == "pdf" { return fromPDF(filename: filename, data: data) }
        if let text = String(data: data, encoding: .utf8) {
            let kind: Kind = codeKind(forExtension: ext) ? .code : .text
            return .fromText(filename: filename, kind: kind, content: text, mimeType: kind == .code ? "text/x-\(ext)" : "text/plain")
        }
        return nil
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

/// On-disk storage for large attachment bytes (images), keeping them out
/// of the conversation history that lives in `UserDefaults`.
///
/// Deliberately dumb: one file per blob, named by UUID, in Application
/// Support. A missing file degrades to empty data rather than throwing —
/// an attachment whose bytes went away should show as unavailable, never
/// take the app down.
enum AttachmentStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelaChat/Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let cache = NSCache<NSString, NSData>()

    static func save(_ data: Data, suggestedID: UUID) -> UUID {
        let url = directory.appendingPathComponent(suggestedID.uuidString)
        try? data.write(to: url, options: .atomic)
        cache.setObject(data as NSData, forKey: suggestedID.uuidString as NSString)
        return suggestedID
    }

    static func load(_ id: UUID) -> Data? {
        if let cached = cache.object(forKey: id.uuidString as NSString) { return cached as Data }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(id.uuidString)) else { return nil }
        cache.setObject(data as NSData, forKey: id.uuidString as NSString)
        return data
    }

    static func remove(_ id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
    }

    /// Deletes blobs no live attachment references any more. Called after
    /// destructive history operations rather than on a timer, so an
    /// orphan can only survive until the next deletion.
    static func pruneOrphans(keeping liveIDs: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files {
            guard let id = UUID(uuidString: file), !liveIDs.contains(id) else { continue }
            remove(id)
        }
    }
}
