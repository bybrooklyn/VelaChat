import Foundation

/// Resolving which instruction file(s) a project actually has, and
/// materializing them into the bridge's working directory.
///
/// Claude Code reads its instruction files from its cwd. The bridge runs
/// it in a VelaChat-managed sandbox, which starts empty — so unless these
/// files are copied in, a conversation bound to a project silently loses
/// every instruction that project relies on. The resolution rule is its
/// own function precisely because it has a non-obvious case:
///
/// - `AGENTS.md` is primary.
/// - `CLAUDE.md` is used when `AGENTS.md` is absent.
/// - When both exist, both are used — **unless** `CLAUDE.md` is a symlink
///   resolving to `AGENTS.md`, in which case they are one file and using
///   both would duplicate the entire instruction set.
///
/// That last case is not hypothetical: VelaChat's own repo ships
/// `CLAUDE.md` as a symlink to `AGENTS.md`.
enum InstructionFiles {
    static let agentsName = "AGENTS.md"
    static let claudeName = "CLAUDE.md"

    struct Resolution: Equatable {
        /// Files to materialize, in the order they should be written.
        var files: [URL]
        /// True when both names exist but resolve to the same file on disk.
        var collapsedSymlink: Bool

        var isEmpty: Bool { files.isEmpty }
    }

    /// Which instruction files a source directory really has.
    static func resolve(in directory: URL) -> Resolution {
        let fileManager = FileManager.default
        let agents = directory.appendingPathComponent(agentsName)
        let claude = directory.appendingPathComponent(claudeName)
        let hasAgents = fileManager.fileExists(atPath: agents.path)
        // `fileExists` follows symlinks, so a *broken* CLAUDE.md symlink
        // reports false here — which is the behavior we want, since Claude
        // Code could not read it either.
        let hasClaude = fileManager.fileExists(atPath: claude.path)

        switch (hasAgents, hasClaude) {
        case (false, false):
            return Resolution(files: [], collapsedSymlink: false)
        case (true, false):
            return Resolution(files: [agents], collapsedSymlink: false)
        case (false, true):
            return Resolution(files: [claude], collapsedSymlink: false)
        case (true, true):
            // Both names exist. If they are the same inode, or one is a
            // symlink pointing at the other, they are one document.
            if sameFile(agents, claude) {
                return Resolution(files: [agents], collapsedSymlink: true)
            }
            return Resolution(files: [agents, claude], collapsedSymlink: false)
        }
    }

    /// Whether two paths name the same file once symlinks are followed.
    /// Compared by resolved path first, then by device+inode, so a
    /// hard link is caught too.
    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.resolvingSymlinksInPath().standardizedFileURL
        let right = rhs.resolvingSymlinksInPath().standardizedFileURL
        if left.path == right.path { return true }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let leftID = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let rightID = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier else {
            return false
        }
        return leftID.isEqual(rightID)
    }

    /// Copies the resolved instruction files into `destination`.
    ///
    /// Content is written, not symlinked: the destination is a sandbox
    /// Claude Code may write to, and a symlink there would expose the
    /// user's real file to modification through it.
    @discardableResult
    static func materialize(from source: URL, into destination: URL) throws -> [String] {
        let resolution = resolve(in: source)
        guard !resolution.isEmpty else { return [] }
        var written: [String] = []
        for file in resolution.files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let target = destination.appendingPathComponent(file.lastPathComponent)
            try text.write(to: target, atomically: true, encoding: .utf8)
            written.append(file.lastPathComponent)
        }
        return written
    }
}
