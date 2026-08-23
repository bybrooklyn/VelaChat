import Foundation

/// Pure logic behind the first-class git tools (§9.7) — parsing real `git`
/// output into structure and building the exact commands the tools run.
/// The subprocess itself is always `CommandRunner.run`; classification and
/// approval tiers come from `ApprovalClassifier`, so nothing here re-
/// implements either.
public enum GitTools {

    // MARK: - status --porcelain=v2 --branch

    public struct Status: Equatable {
        public var branch: String?
        public var ahead = 0
        var behind = 0
        public var staged: [String] = []
        public var unstaged: [String] = []
        public var untracked: [String] = []

        public init() {}
    }

    /// Parses `git status --porcelain=v2 --branch`. Unknown line shapes are
    /// skipped, never fatal — a future format must not break the tool.
    public static func parseStatus(_ text: String) -> Status {
        var status = Status()
        for rawLine in text.split(separator: "\n").map(String.init) {
            guard !rawLine.isEmpty else { continue }
            let parts = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            switch parts.first {
            case "#":
                // Branch metadata: "# branch.head main", "# branch.ab +2 -1"
                let rest = parts.dropFirst().joined(separator: " ")
                if rest.hasPrefix("branch.head "), !rest.contains("(detached)") {
                    status.branch = String(rest.dropFirst("branch.head ".count))
                } else if rest.hasPrefix("branch.ab ") {
                    for piece in parts.dropFirst(2) {
                        if piece.hasPrefix("+"), let n = Int(piece.dropFirst()) { status.ahead = n }
                        if piece.hasPrefix("-"), let n = Int(piece.dropFirst()) { status.behind = n }
                    }
                }
            case "1", "2":
                // Ordinary / renamed entry. Porcelain v2 layout:
                //   1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                //   2 <XY> <sub> … <X><score> <path>\t<origPath>
                // The path lives in field 9 for `1`; renames carry the
                // CURRENT path in the first tab-separated chunk.
                let chunks = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let fields = chunks[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard fields.count >= 3 else { break }
                let xy = fields[1]
                let x = xy.first.map(String.init) ?? "."
                let y = xy.last.map(String.init) ?? "."
                let path: String
                if parts.first == "1" {
                    guard fields.count >= 9 else { break }
                    path = fields[8...].joined(separator: " ")
                } else {
                    guard chunks.count >= 2 else { break }
                    path = chunks[1]
                }
                if x != "." && x != "?" { status.staged.append(path) }
                if y != "." && y != "?" { status.unstaged.append(path) }
            case "u":
                // Unmerged: "u <X> <Y> <S1> <S2> <S3> <S4> <path>"
                if let path = parts.last { status.unstaged.append(path) }
            case "?":
                if parts.count >= 2 { status.untracked.append(parts.dropFirst().joined(separator: " ")) }
            default:
                break
            }
        }
        return status
    }

    /// The human-readable rendering the model receives — structured fields,
    /// not raw porcelain.
    public static func describe(_ status: Status) -> String {
        var lines: [String] = []
        if let branch = status.branch {
            if status.ahead == 0, status.behind == 0 {
                lines.append("Branch: \(branch)")
            } else {
                lines.append("Branch: \(branch) (+\(status.ahead) ahead, -\(status.behind) behind)")
            }
        } else {
            lines.append("Branch: (detached or unborn)")
        }
        func section(_ title: String, _ paths: [String]) {
            guard !paths.isEmpty else { return }
            lines.append("\(title):")
            lines.append(contentsOf: paths.prefix(40).map { "  " + $0 })
            if paths.count > 40 { lines.append("  …and \(paths.count - 40) more") }
        }
        section("Staged", status.staged)
        section("Unstaged", status.unstaged)
        section("Untracked", status.untracked)
        if status.staged.isEmpty && status.unstaged.isEmpty && status.untracked.isEmpty {
            lines.append("Working tree clean.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - log --oneline

    public struct Commit: Equatable {
        public var hash: String
        public var subject: String
    }

    public static func parseLog(_ text: String) -> [Commit] {
        text.split(separator: "\n").map(String.init).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            return Commit(hash: String(parts[0]), subject: String(parts[1]))
        }
    }

}
