import Foundation

extension FileManager {
    /// Total on-disk size of a directory tree — used to guard repo clones.
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
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
enum SandboxManager {
    static func directory(for conversationID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelaChat/Workspaces/\(conversationID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Resolves a model-provided relative path against the workspace
    /// directory and refuses anything that would escape it — `..`
    /// segments, absolute paths, or a standardized path that no longer has
    /// the workspace directory as its prefix. This (not process sandboxing)
    /// is the actual safety boundary for these tools.
    static func resolve(_ relativePath: String, in directory: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("..") else { return nil }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path == base.path || candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}
