import Foundation

extension FileManager {
    /// Total on-disk size of a directory tree — used to guard repo clones.
    public func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Each conversation gets a real, private, app-managed folder on disk the
/// model can read/write files in — the scoped-down version of the original
/// "sandbox workstation" idea (Phase 4). A `bash`/shell-execution tool was
/// deliberately NOT built: a `sandbox-exec` confinement profile was written
/// and tested by hand before any of this shipped, and it could not be made
/// to reliably confine even a bare `/bin/echo` (repeatedly aborted with
/// SIGABRT) — `sandbox-exec` is undocumented and Apple-deprecated, and
/// shipping a bash tool that *looks* sandboxed but isn't would be actively
/// dangerous, since the model (not the user) decides what commands run,
/// potentially influenced by untrusted content in the conversation. Path-
/// validated file read/write is a fundamentally safer boundary — a
/// candidate path either resolves inside the workspace folder or the call
/// is refused, with no code execution surface at all.
public enum SandboxManager {
    public static func directory(for conversationID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelaChat/Workspaces/\(conversationID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Deletes a conversation's workspace folder without creating it
    /// first — `directory(for:)` creates on access, so deleting a
    /// conversation must not route through it.
    public static func cleanup(for conversationID: UUID) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelaChat/Workspaces/\(conversationID.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
    }

    /// Resolves a model-provided relative path against the workspace
    /// directory and refuses anything that would escape it — `..`
    /// segments, absolute paths, or a standardized path that no longer has
    /// the workspace directory as its prefix. This (not process sandboxing)
    /// is the actual safety boundary for these tools.
    public static func resolve(_ relativePath: String, in directory: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("..") else { return nil }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(relativePath).standardizedFileURL
        // Textual containment is not enough on its own: the base resolves
        // symlinks but the candidate did not, so a symlink *inside* the
        // workspace pointing anywhere on disk read as contained and the
        // read/write then followed it straight out. That never mattered
        // while the workspace was only ever an app-created folder, but a
        // user can attach a real project folder as the workspace root, and
        // real project folders are full of symlinks.
        guard isContained(candidate, in: base) else { return nil }
        return candidate
    }

    /// Whether `candidate` lands inside `base` once symlinks are followed.
    /// A path that doesn't exist yet (a file about to be written) is judged
    /// by its nearest existing ancestor, since that's the link that would
    /// redirect it.
    private static func isContained(_ candidate: URL, in base: URL) -> Bool {
        var existingAncestor = candidate
        var trailing: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path) {
            let parent = existingAncestor.deletingLastPathComponent().standardizedFileURL
            // Walked past the root without finding anything — refuse.
            guard parent.path != existingAncestor.path else { return false }
            trailing.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = parent
        }
        var resolved = existingAncestor.resolvingSymlinksInPath()
        for component in trailing {
            resolved.appendPathComponent(component)
        }
        let path = resolved.standardizedFileURL.path
        return path == base.path || path.hasPrefix(base.path + "/")
    }
}
