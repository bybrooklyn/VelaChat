import Foundation
import Observation

/// A saved prompt, invoked from the composer's `/` menu by name instead of
/// retyping it — the "macro" half of the slash-command system, alongside
/// built-in actions and Skills.
struct PromptSnippet: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var body: String

    init(id: UUID = UUID(), name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }
}

/// A real, portable `SKILL.md` skill — a folder containing `SKILL.md` with
/// YAML frontmatter (`name`, `description` required; `license`,
/// `allowed-tools`, `metadata`, `compatibility` optional) and a markdown
/// body of instructions. This is the same open format Claude Code and
/// Codex CLI both already use, not a VelaChat-invented shape — a skill
/// dropped into either tool's personal skills folder just works here too.
struct Skill: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable {
        case claudeCode = "Claude Code"
        case codex = "Codex CLI"
        case custom = "Added"
    }

    var id: String { folderPath }
    let name: String
    let description: String
    let body: String
    let allowedTools: [String]?
    let folderPath: String
    let source: Source
}

/// Discovers skills already sitting in `~/.claude/skills/` and
/// `~/.codex/skills/` (both tools' real, documented personal-skills
/// locations) with zero import step, plus any folder the user explicitly
/// adds. Project-level `.claude/skills/`/`.codex/skills/` are deliberately
/// out of scope — VelaChat has no standing "current project" concept to
/// resolve those against yet.
@MainActor
@Observable
final class SkillsStore {
    private let customPathsKey = "velachat.custom-skill-paths"
    private let defaults = UserDefaults.standard

    var skills: [Skill] = []
    /// Folders that failed to parse as a real `SKILL.md` — surfaced in
    /// Settings rather than silently dropped, so a malformed skill is
    /// something you can actually notice and fix.
    var failedPaths: [String] = []

    init() {
        refresh()
    }

    var customFolderPaths: [String] {
        (defaults.stringArray(forKey: customPathsKey)) ?? []
    }

    func addCustomFolder(_ path: String) {
        var paths = customFolderPaths
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths, forKey: customPathsKey)
        refresh()
    }

    func removeCustomFolder(_ path: String) {
        let paths = customFolderPaths.filter { $0 != path }
        defaults.set(paths, forKey: customPathsKey)
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var discovered: [Skill] = []
        var failures: [String] = []

        func scan(_ directory: URL, source: Skill.Source) {
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let skillFile = entry.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: skillFile.path) else { continue }
                if let skill = Self.parse(fileURL: skillFile, folderPath: entry.path, source: source) {
                    discovered.append(skill)
                } else {
                    failures.append(entry.path)
                }
            }
        }

        scan(home.appendingPathComponent(".claude/skills"), source: .claudeCode)
        scan(home.appendingPathComponent(".codex/skills"), source: .codex)

        for path in customFolderPaths {
            let entry = URL(fileURLWithPath: path)
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path) else {
                failures.append(path)
                continue
            }
            if let skill = Self.parse(fileURL: skillFile, folderPath: path, source: .custom) {
                discovered.append(skill)
            } else {
                failures.append(path)
            }
        }

        skills = discovered
        failedPaths = failures
    }

    /// Minimal, purpose-built frontmatter reader — real `SKILL.md` files use
    /// flat `key: value` YAML plus one list field (`allowed-tools`), not
    /// arbitrarily nested YAML, so a hand-rolled line parser covers the real
    /// format without pulling in a full YAML dependency for it.
    private static func parse(fileURL: URL, folderPath: String, source: Skill.Source) -> Skill? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        guard let closingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let frontmatterLines = Array(lines[..<closingIndex])
        let bodyLines = Array(lines[(closingIndex + 1)...])

        var name: String?
        var description: String?
        var allowedTools: [String]?
        var currentListKey: String?

        for rawLine in frontmatterLines {
            if rawLine.hasPrefix("  - ") || rawLine.hasPrefix("- "), currentListKey == "allowed-tools" {
                let value = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "- ")).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { allowedTools = (allowedTools ?? []) + [value] }
                continue
            }
            guard let colonIndex = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[rawLine.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            var value = rawLine[rawLine.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            currentListKey = value.isEmpty ? key : nil
            switch key {
            case "name": name = value
            case "description": description = value
            case "allowed-tools":
                if value.hasPrefix("[") {
                    let inline = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    allowedTools = inline.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }.filter { !$0.isEmpty }
                } else if !value.isEmpty {
                    allowedTools = value.split(separator: " ").map(String.init)
                }
            default: break
            }
        }

        guard let name, !name.isEmpty, let description, !description.isEmpty else { return nil }
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Skill(name: name, description: description, body: body, allowedTools: allowedTools, folderPath: folderPath, source: source)
    }
}
