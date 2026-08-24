import SwiftUI
import VelaCore

/// A file a reply produced, as a clickable chip under that reply.
///
/// Files used to have no presence in the transcript at all: the only way
/// into one was to expand the tool row and press an "Open" button hidden
/// inside it, which is not somewhere anyone looks. The reply now ends with
/// what it made.
struct ProducedFile: Identifiable, Equatable {
    var id: String { relativePath }
    /// Path as it should be resolved against the workspace root — already
    /// corrected for the extension `create_document` appends.
    var relativePath: String
    var displayName: String
    var typeLabel: String
    var symbol: String

    /// The activity kinds that leave a file behind. `fileRead` is
    /// deliberately absent: reading a file is not producing one, and a chip
    /// per read would put the reply's own source code under every answer.
    static let producingKinds: Set<ActivityKind> = [.fileWrite, .fileEdit, .document]

    /// Derives the chips for one reply.
    ///
    /// `root` is the conversation's `workspaceRoot`, so an attached project
    /// folder resolves to the real place rather than to the sandbox.
    static func chips(from records: [ActivityRecord], root: URL?) -> [ProducedFile] {
        var byPath: [String: ProducedFile] = [:]
        var order: [String] = []
        for record in records where producingKinds.contains(record.kind) && !record.isError {
            let argument = record.argument.trimmingCharacters(in: .whitespaces)
            guard !argument.isEmpty else { continue }
            guard let path = resolvedPath(for: argument, root: root) else { continue }
            if byPath[path] == nil { order.append(path) }
            let ext = (path as NSString).pathExtension
            byPath[path] = ProducedFile(
                relativePath: path,
                displayName: (path as NSString).lastPathComponent,
                typeLabel: typeLabel(forExtension: ext),
                symbol: symbol(forExtension: ext)
            )
        }
        return order.compactMap { byPath[$0] }
    }

    /// `create_document` appends the format's extension when the model
    /// leaves it off, so the recorded argument can be "report" while the
    /// file on disk is "report.xlsx". A chip that opens nothing is worse
    /// than no chip, so an argument that doesn't exist is matched by
    /// basename against what's actually there.
    private static func resolvedPath(for argument: String, root: URL?) -> String? {
        guard let root else { return argument }
        if let url = SandboxManager.resolve(argument, in: root),
           FileManager.default.fileExists(atPath: url.path) {
            return argument
        }
        let directory = (argument as NSString).deletingLastPathComponent
        let base = ((argument as NSString).lastPathComponent as NSString).deletingPathExtension
        let searchRoot = directory.isEmpty ? root : root.appendingPathComponent(directory, isDirectory: true)
        guard let siblings = try? FileManager.default.contentsOfDirectory(atPath: searchRoot.path) else { return nil }
        guard let match = siblings.first(where: { ($0 as NSString).deletingPathExtension == base }) else { return nil }
        return directory.isEmpty ? match : directory + "/" + match
    }

    /// Office formats get names a person uses; everything else falls
    /// through to the artifact kinds the inspector already knows.
    static func typeLabel(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "xlsx": return "Spreadsheet"
        case "docx": return "Word document"
        case "pptx": return "Slides"
        case "pdf": return "PDF"
        case "csv", "tsv": return "Table"
        default: return Artifact.Kind.from(fileExtension: ext).displayName
        }
    }

    static func symbol(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "xlsx", "csv", "tsv": return "tablecells"
        case "pptx": return "rectangle.on.rectangle"
        case "pdf": return "doc.richtext"
        case "docx": return "doc.text"
        case "html", "htm", "svg": return "globe"
        case "mmd", "mermaid": return "flowchart"
        default: return "doc.text"
        }
    }
}

struct ArtifactChipRow: View {
    let files: [ProducedFile]
    let root: URL?

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(files) { file in
                ArtifactChip(file: file, root: root)
            }
        }
        .messageColumn()
    }
}

private struct ArtifactChip: View {
    let file: ProducedFile
    let root: URL?
    @Environment(ArtifactPresenter.self) private var artifactPresenter
    @State private var isHovering = false
    @State private var failed = false

    var body: some View {
        Button {
            guard let root else { return }
            // Text renders in the panel; a real document opens in the app
            // that owns its format. Either way something visible happens —
            // the old path silently did nothing for anything non-UTF-8.
            let opened = artifactPresenter.openWorkspaceFile(named: file.relativePath, in: root)
            if !opened {
                withAnimation(.easeOut(duration: 0.15)) { failed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeOut(duration: 0.2)) { failed = false }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: failed ? "exclamationmark.triangle" : file.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(failed ? Theme.warning : Theme.accent)
                Text(file.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(failed ? "couldn't open" : file.typeLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                isHovering ? Theme.surfaceHigh : Theme.surfaceMid,
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
            .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous), emphasis: isHovering ? 0.8 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open \(file.displayName)")
        .accessibilityLabel("Open \(file.displayName), \(file.typeLabel)")
        .contextMenu {
            Button {
                guard let root else { return }
                artifactPresenter.revealInFinder(named: file.relativePath, in: root)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.displayName, forType: .string)
            } label: {
                Label("Copy Filename", systemImage: "doc.on.doc")
            }
        }
    }
}

/// Chips wrap instead of overflowing the message column — a reply that
/// wrote six files should not force a horizontal scroll or clip the last
/// one off the edge.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                widest = max(widest, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widest = max(widest, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(widest, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
