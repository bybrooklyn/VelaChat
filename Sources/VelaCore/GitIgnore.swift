import Foundation

/// A readable subset of `.gitignore` semantics, applied to workspace
/// listing and search so the model doesn't drown in build artifacts — or
/// worse, go digging through `node_modules` because it was told to list
/// "the project".
///
/// What is honored (the shapes real-world ignores almost always use):
/// blank lines and `#` comments; `!` negation; trailing `/` for
/// directories; leading or embedded `/` for anchoring; `*`, `?`, and `**`
/// wildcards. Last matching rule wins, exactly as git does. NOT honored:
/// nested per-directory `.gitignore`s (only the root file is read) and
/// character classes — both rare enough to leave out of a first pass, and
/// their absence fails toward showing more, not less.
public enum GitIgnore {

    public struct Rule {
        let negated: Bool
        let directoryOnly: Bool
        let anchored: Bool
        /// The pattern translated into a regular expression source string,
        /// matched against a path *relative to the workspace root* using
        /// forward slashes.
        let regexSource: String
    }

    // MARK: - Parsing

    public static func parse(_ text: String) -> [Rule] {
        var rules: [Rule] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            // A trailing-space run is decoration unless backslash-escaped;
            // this subset treats it as decoration either way.
            while line.hasSuffix(" ") { line.removeLast() }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            var pattern = line
            var negated = false
            if pattern.hasPrefix("!") {
                negated = true
                pattern.removeFirst()
                if pattern.isEmpty { continue }
            }

            var directoryOnly = false
            if pattern.hasSuffix("/") {
                directoryOnly = true
                pattern.removeLast()
                if pattern.isEmpty { continue }
            }

            let anchored = pattern.hasPrefix("/") || pattern.contains("/")
            if pattern.hasPrefix("/") { pattern.removeFirst() }
            guard !pattern.isEmpty else { continue }

            rules.append(Rule(
                negated: negated,
                directoryOnly: directoryOnly,
                anchored: anchored,
                regexSource: translate(pattern)
            ))
        }
        return rules
    }

    public static func load(from root: URL) -> [Rule] {
        guard let text = try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    /// Git wildcard → regex. `*` and `?` never cross `/`; `**` does.
    static func translate(_ pattern: String) -> String {
        var result = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            switch character {
            case "*":
                let count = pattern[index...].prefix(while: { $0 == "*" }).count
                result += count >= 2 ? ".*" : "[^/]*"
                index = pattern.index(index, offsetBy: count)
            case "?":
                result += "[^/]"
                index = pattern.index(after: index)
            default:
                if ".*+^$[]()|\\".contains(character) {
                    result += "\\"
                }
                result.append(character)
                index = pattern.index(after: index)
            }
        }
        return result + "$"
    }

    // MARK: - Matching

    /// Whether `relativePath` (slash-separated, relative to the workspace
    /// root) is ignored. Directory-only rules match a file through its
    /// ancestor directories — `build/` ignores `build/out.o`.
    public static func ignores(_ rules: [Rule], relativePath: String) -> Bool {
        guard !rules.isEmpty, !relativePath.isEmpty else { return false }
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        var ignored = false
        for rule in rules {
            if matches(rule, path: path) {
                ignored = !rule.negated
            }
        }
        return ignored
    }

    private static func matches(_ rule: Rule, path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)

        func patternMatches(_ candidate: String) -> Bool {
            let source = rule.anchored ? rule.regexSource : "(?:.*/)?\(rule.regexSource)"
            let regex = NSRegularExpression.cached(source)
            let range = NSRange(candidate.startIndex..., in: candidate)
            return regex.firstMatch(in: candidate, options: [], range: range) != nil
        }

        // Directory-only: any ancestor directory matching counts.
        if rule.directoryOnly {
            var prefix = ""
            for component in components.dropLast() {
                prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                if patternMatches(prefix) { return true }
            }
        }
        return patternMatches(path)
    }
}

extension NSRegularExpression {
    /// Small compile cache — the same handful of patterns get evaluated
    /// once per listed file during a workspace scan.
    static func cached(_ source: String) -> NSRegularExpression {
        if let existing = regexCache.object(forKey: source as NSString) {
            return existing
        }
        let compiled = (try? NSRegularExpression(pattern: source)) ?? {
            // Unreachable for the sources this type builds, but the fallback
            // must exist — an empty pattern that matches nothing.
            return try! NSRegularExpression(pattern: "^$")
        }()
        regexCache.setObject(compiled, forKey: source as NSString)
        return compiled
    }

    private static let regexCache = NSCache<NSString, NSRegularExpression>()
}
