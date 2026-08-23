import Foundation

/// Read-only facts about an attached folder being a git repository.
/// Deliberately a FILE READ (`​.git/HEAD`), not a `git` subprocess: this is
/// consulted by UI that renders on every conversation switch, so it must
/// be free, instant, and never need the command runner's approval ladder.
public enum GitInfo {

    /// The current branch name, or nil when the folder isn't a repo, is in
    /// detached-HEAD state, uses an unusual ref layout, or points through
    /// a worktree/submodule `gitdir:` indirection — anything the one-file
    /// read can't vouch for. nil keeps the UI quiet rather than showing a
    /// guess.
    public static func branch(of directory: URL) -> String? {
        let head = directory.appendingPathComponent(".git/HEAD")
        guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: refs/heads/") else { return nil }
        let name = String(trimmed.dropFirst("ref: refs/heads/".count))
        // A ref name can't be empty or contain whitespace; both mean we
        // misread something.
        guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return nil }
        return name
    }

    /// Whether the folder looks like a working repository at all — same
    /// cheap check, used to decide whether repo-aware affordances show.
    public static func isRepository(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
    }
}
