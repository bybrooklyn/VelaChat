import Foundation
import PDFKit

/// A file attached to a message. Images get real multimodal wiring (base64
/// content blocks) for vision-capable models; text/code/PDF are folded into
/// the outgoing message as a labeled block, since that works over plain
/// text with every provider without touching any wire format at all.
public struct Attachment: Identifiable, Codable, Equatable {
    public enum Kind: String, Codable {
        case image, text, code, pdf, git
        /// §9.2 — a CSV/TSV/JSON/xlsx/SQLite file attached to be *queried*
        /// rather than read. Its bytes are never folded into the prompt:
        /// they are loaded into the conversation's analysis database, and
        /// what the model sees is the schema plus a few sample rows.
        case data
    }

    /// Kinds whose payload is raw bytes rather than text — the ones that
    /// belong in the blob store rather than in the conversation history.
    var storesRawBytes: Bool { kind == .image || kind == .data }

    public let id: UUID
    public var kind: Kind
    public var filename: String
    public var mimeType: String
    /// Raw bytes for `.image` and `.data`; UTF-8 text for everything else
    /// (already-extracted text for `.pdf`).
    ///
    /// Image and data-file bytes are NOT encoded into the conversation
    /// history. That history lives in `UserDefaults`, which is read into
    /// memory whole at launch and rewritten on every save — a handful of
    /// screenshots there meant tens of megabytes of base64 in a
    /// preferences plist, and a spreadsheet is the same problem with a
    /// different extension. Both go to a blob store on disk instead and
    /// load lazily; text attachments are small and stay inline where
    /// they're simplest.
    public var data: Data {
        get {
            if let inlineData { return inlineData }
            guard let blobID else { return Data() }
            return AttachmentStore.load(blobID) ?? Data()
        }
        set {
            if storesRawBytes, newValue.count > Limits.inlineAttachmentBytes {
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
    public var originalByteCount: Int
    /// Inclusion control: attached but not sent. Toggled from the
    /// composer's attachment chip.
    public var isIncluded: Bool = true

    public init(id: UUID = UUID(), kind: Kind, filename: String, mimeType: String, data: Data, originalByteCount: Int? = nil, isIncluded: Bool = true) {
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

    public init(from decoder: Decoder) throws {
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
        if storesRawBytes, let inlineData, inlineData.count > Limits.inlineAttachmentBytes {
            blobID = AttachmentStore.save(inlineData, suggestedID: id)
            self.inlineData = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
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

    /// nil for anything whose bytes must not be folded into the prompt —
    /// images, and data files (which reach the model as a schema plus a
    /// queryable table, not as 40,000 rows of CSV).
    public var textContent: String? {
        guard !storesRawBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public var estimatedTokens: Int {
        if kind == .image {
            // No provider publishes an exact formula VelaChat can rely on;
            // this is the widely-used rough OpenAI vision estimate for a
            // single moderate-resolution image, not an exact figure.
            return 765
        }
        if kind == .data {
            // What a data file actually costs the context is its schema
            // block, which is a few columns and three sample rows — not its
            // size on disk. A rough constant is far closer to the truth
            // here than bytes/4 would be.
            return 200
        }
        return max(1, data.count / 4)
    }

    public var sizeLabel: String {
        let bytes = Double(originalByteCount)
        if bytes >= 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f KB", bytes / 1_000) }
        return "\(originalByteCount) B"
    }

    /// A hard cap so one huge pasted file doesn't blow the whole context
    /// budget silently — real summarization (compressing instead of just
    /// cutting off) is a documented gap, not built yet.
    public static let maxTextBytes = 60_000

    public static func fromText(filename: String, kind: Kind, content: String, mimeType: String) -> Attachment {
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
    public static func fromFile(url: URL) -> Attachment? {
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
        // §9.2 — data formats are checked BEFORE the text branch on
        // purpose: a CSV decodes as UTF-8 perfectly well, and attaching it
        // as text is exactly the behaviour this replaces (60 KB of rows
        // inlined into the prompt, truncated, un-queryable).
        if DataSourceLoader.Format.detect(filename: filename) != nil {
            return fromDataFile(filename: filename, data: data)
        }
        if let text = String(data: data, encoding: .utf8) {
            let kind: Kind = codeKind(forExtension: ext) ? .code : .text
            return .fromText(filename: filename, kind: kind, content: text, mimeType: kind == .code ? "text/x-\(ext)" : "text/plain")
        }
        return nil
    }

    /// A data file attaches whole and unparsed: loading it into the
    /// analysis database happens per conversation, at send time, where the
    /// database lives. Over the size ceiling it falls back to nil rather
    /// than pretending — a 200 MB export is a real file the user should be
    /// told about, not something to silently half-load.
    public static func fromDataFile(filename: String, data: Data) -> Attachment? {
        guard data.count <= Limits.dataSourceBytes else { return nil }
        let mimeTypes = [
            "csv": "text/csv", "tsv": "text/tab-separated-values", "tab": "text/tab-separated-values",
            "json": "application/json", "ndjson": "application/x-ndjson", "jsonl": "application/x-ndjson",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "sqlite": "application/vnd.sqlite3", "sqlite3": "application/vnd.sqlite3", "db": "application/vnd.sqlite3",
        ]
        let ext = (filename as NSString).pathExtension.lowercased()
        return Attachment(
            kind: .data,
            filename: filename,
            mimeType: mimeTypes[ext] ?? "application/octet-stream",
            data: data
        )
    }

    public static func fromPDF(filename: String, data pdfData: Data) -> Attachment? {
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
    public static func fromGitFolder(url: URL) -> Attachment? {
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
    public var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    public static func codeKind(forExtension ext: String) -> Bool {
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
public enum AttachmentStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelaChat/Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let cache = NSCache<NSString, NSData>()

    public static func save(_ data: Data, suggestedID: UUID) -> UUID {
        let url = directory.appendingPathComponent(suggestedID.uuidString)
        try? data.write(to: url, options: .atomic)
        cache.setObject(data as NSData, forKey: suggestedID.uuidString as NSString)
        return suggestedID
    }

    public static func load(_ id: UUID) -> Data? {
        if let cached = cache.object(forKey: id.uuidString as NSString) { return cached as Data }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(id.uuidString)) else { return nil }
        cache.setObject(data as NSData, forKey: id.uuidString as NSString)
        return data
    }

    public static func remove(_ id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
    }

    /// Deletes blobs no live attachment references any more. Called after
    /// destructive history operations rather than on a timer, so an
    /// orphan can only survive until the next deletion.
    public static func pruneOrphans(keeping liveIDs: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files {
            guard let id = UUID(uuidString: file), !liveIDs.contains(id) else { continue }
            remove(id)
        }
    }
}
