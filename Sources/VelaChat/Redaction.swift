import Foundation
import Observation

/// Egress controls: what may leave this machine, and in what form.
///
/// Two independent gates live here because they answer the same question
/// at different altitudes. `Redactor` decides *what* is allowed out of a
/// message; `EgressPolicy` decides *where* anything is allowed to go at
/// all. Both are deliberately enforced below the view layer — a control
/// that only hides a provider in a picker is a suggestion, not a policy.

// MARK: - Rules

/// One named pattern whose matches are replaced before a message is sent.
///
/// `pattern` is an `NSRegularExpression` source string. An invalid pattern
/// is not a crash and not a silent no-op: `Redactor` reports it so the
/// Settings card can show the rule as broken, because a redaction rule
/// that quietly matches nothing is the worst possible failure here.
struct RedactionRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var pattern: String
    var isEnabled: Bool = true
    /// Built-ins can be disabled and edited but never deleted, so the set
    /// can't be silently emptied and forgotten about.
    var isBuiltIn: Bool = false

    init(id: UUID = UUID(), name: String, pattern: String, isEnabled: Bool = true, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }

    /// Shapes chosen because they are unambiguous — each one identifies its
    /// issuer from the literal prefix, so a match is a real credential
    /// rather than any long random-looking string. Email is the exception
    /// and ships disabled: addresses are frequently the actual subject of a
    /// message, so redacting them by default would corrupt normal use.
    static func builtIns() -> [RedactionRule] {
        [
            RedactionRule(name: "Anthropic API key", pattern: "sk-ant-[A-Za-z0-9_\\-]{16,}", isBuiltIn: true),
            RedactionRule(name: "OpenAI API key", pattern: "sk-(?:proj-)?[A-Za-z0-9_\\-]{20,}", isBuiltIn: true),
            RedactionRule(name: "GitHub token", pattern: "gh[pousr]_[A-Za-z0-9]{16,}", isBuiltIn: true),
            RedactionRule(name: "Slack token", pattern: "xox[baprs]-[A-Za-z0-9\\-]{10,}", isBuiltIn: true),
            RedactionRule(name: "Google API key", pattern: "AIza[A-Za-z0-9_\\-]{35}", isBuiltIn: true),
            RedactionRule(name: "AWS access key ID", pattern: "(?:AKIA|ASIA|AGPA|AIDA|AROA)[A-Z0-9]{16}", isBuiltIn: true),
            RedactionRule(name: "AWS secret key", pattern: "(?i)aws_secret_access_key\\s*[=:]\\s*[A-Za-z0-9/+=]{40}", isBuiltIn: true),
            RedactionRule(name: "Bearer token", pattern: "(?i)bearer\\s+[A-Za-z0-9._\\-]{20,}", isBuiltIn: true),
            RedactionRule(name: "Private key block", pattern: "-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----[\\s\\S]*?-----END(?: [A-Z]+)? PRIVATE KEY-----", isBuiltIn: true),
            RedactionRule(name: "Email address", pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}", isEnabled: false, isBuiltIn: true)
        ]
    }
}

/// A single replacement that happened, recorded on the message so the
/// transcript can prove it. `range` indexes into the *redacted* text.
struct RedactionSpan: Codable, Equatable, Hashable, Sendable {
    /// Sentinel for a redaction that happened in an attachment rather than
    /// in the message body, where a body offset would be meaningless.
    static let notInMessageBody = -1

    var ruleName: String
    /// UTF-16 offset and length of the placeholder in the redacted string,
    /// or `notInMessageBody`.
    var location: Int
    var length: Int

    var isInMessageBody: Bool { location != Self.notInMessageBody }
}

struct RedactionResult: Equatable, Sendable {
    var text: String
    var spans: [RedactionSpan]
    var didRedact: Bool { !spans.isEmpty }
}

// MARK: - Redactor

/// Runs enabled rules over outbound text. Pure and synchronous so it can be
/// unit-tested and called on the send path without ceremony.
struct Redactor: Sendable {
    var rules: [RedactionRule]

    init(rules: [RedactionRule]) {
        self.rules = rules
    }

    /// Rules whose pattern does not compile. Surfaced in Settings — never
    /// swallowed, because a rule that matches nothing looks identical to a
    /// rule that found nothing.
    static func invalidRuleIDs(in rules: [RedactionRule]) -> Set<UUID> {
        var bad: Set<UUID> = []
        for rule in rules where (try? NSRegularExpression(pattern: rule.pattern)) == nil {
            bad.insert(rule.id)
        }
        return bad
    }

    /// Replaces every match of every enabled rule with a visible marker.
    ///
    /// Overlap policy: matches are collected across all rules, then sorted
    /// by position and resolved **longest-match-wins** at any given start,
    /// with later overlaps dropped. Without this, "Bearer sk-ant-…" would
    /// be rewritten twice — once by the bearer rule and once by the key
    /// rule — and the second pass would operate on text the first had
    /// already replaced, producing nested markers.
    func redact(_ text: String) -> RedactionResult {
        guard !text.isEmpty else { return RedactionResult(text: text, spans: []) }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        struct Hit {
            let range: NSRange
            let ruleName: String
        }
        var hits: [Hit] = []
        for rule in rules where rule.isEnabled {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            for match in regex.matches(in: text, range: full) where match.range.length > 0 {
                hits.append(Hit(range: match.range, ruleName: rule.name))
            }
        }
        guard !hits.isEmpty else { return RedactionResult(text: text, spans: []) }

        // Earliest first; at the same start the longest wins, so the more
        // specific rule survives.
        hits.sort { a, b in
            a.range.location == b.range.location
                ? a.range.length > b.range.length
                : a.range.location < b.range.location
        }
        var chosen: [Hit] = []
        var consumedUpTo = 0
        for hit in hits where hit.range.location >= consumedUpTo {
            chosen.append(hit)
            consumedUpTo = hit.range.location + hit.range.length
        }

        var output = ""
        var spans: [RedactionSpan] = []
        var cursor = 0
        for hit in chosen {
            output += ns.substring(with: NSRange(location: cursor, length: hit.range.location - cursor))
            let marker = Self.marker(for: hit.ruleName)
            spans.append(RedactionSpan(
                ruleName: hit.ruleName,
                location: (output as NSString).length,
                length: (marker as NSString).length
            ))
            output += marker
            cursor = hit.range.location + hit.range.length
        }
        output += ns.substring(from: cursor)
        return RedactionResult(text: output, spans: spans)
    }

    /// The placeholder left in the sent text. Deliberately readable rather
    /// than a hash or an empty string: the model receiving it should be
    /// able to tell that something was removed and why, instead of seeing a
    /// mangled sentence.
    static func marker(for ruleName: String) -> String { "[redacted: \(ruleName)]" }
}

// MARK: - Store

@MainActor
@Observable
final class RedactionStore {
    var isEnabled: Bool {
        didSet { Defaults.set(isEnabled, DefaultsKey.redactionEnabled) }
    }
    private(set) var rules: [RedactionRule] = [] {
        didSet { persist() }
    }

    init() {
        isEnabled = Defaults.bool(DefaultsKey.redactionEnabled, default: true)
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.redactionRules),
           let saved = try? JSONDecoder().decode([RedactionRule].self, from: data), !saved.isEmpty {
            // Built-ins added in a later version have to appear for users
            // who already have a saved set, or new protections would only
            // ever reach fresh installs.
            var merged = saved
            let knownNames = Set(saved.filter(\.isBuiltIn).map(\.name))
            for builtIn in RedactionRule.builtIns() where !knownNames.contains(builtIn.name) {
                merged.append(builtIn)
            }
            rules = merged
        } else {
            rules = RedactionRule.builtIns()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.redactionRules)
        }
    }

    var redactor: Redactor { Redactor(rules: isEnabled ? rules : []) }

    var invalidRuleIDs: Set<UUID> { Redactor.invalidRuleIDs(in: rules) }

    func add(name: String, pattern: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPattern.isEmpty else { return }
        rules.append(RedactionRule(name: trimmedName, pattern: trimmedPattern))
    }

    func update(_ rule: RedactionRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
    }

    /// Built-ins are disabled, never removed — see `RedactionRule.isBuiltIn`.
    func delete(_ id: UUID) {
        rules.removeAll { $0.id == id && !$0.isBuiltIn }
    }

    func restoreBuiltIns() {
        let custom = rules.filter { !$0.isBuiltIn }
        rules = RedactionRule.builtIns() + custom
    }
}

// MARK: - Local-only mode

/// Whether any request may leave the loopback interface.
///
/// This is a process-wide gate rather than a value threaded through every
/// call site because it has to hold for paths that never see `AppModel` —
/// the ChatGPT web client, the Codex endpoint, quota probes, model
/// discovery. A view-level check would leave all of those open.
///
/// Deliberately enforced at request construction, so turning the switch on
/// blocks a request that a stale view might still offer.
enum EgressPolicy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _isLocalOnly = false

    static var isLocalOnly: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isLocalOnly }
        set { lock.lock(); _isLocalOnly = newValue; lock.unlock() }
    }

    /// Loopback only. A LAN address is not loopback: a model server on
    /// another machine is still a network egress, and "local-only" that
    /// silently permitted 192.168.x.x would not mean anything.
    static func isLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "localhost" || normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" { return true }
        if normalized == "127.0.0.1" { return true }
        // The whole 127.0.0.0/8 block, not just .1.
        let parts = normalized.split(separator: ".")
        if parts.count == 4, parts[0] == "127", parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return false
    }

    /// Throws rather than returning a bool so no call site can forget to
    /// check the result.
    static func check(_ url: URL) throws {
        guard isLocalOnly else { return }
        guard let host = url.host, isLoopback(host) else {
            throw APIError.message(
                "Local-only mode is on, so VelaChat refused to contact \(url.host ?? url.absoluteString). Turn it off in Settings → Privacy to use hosted providers."
            )
        }
    }
}
