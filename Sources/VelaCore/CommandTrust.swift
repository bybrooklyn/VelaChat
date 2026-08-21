import Foundation

/// Remembered "always allow" rules for `run_command`, scoped to one
/// project folder the user attached themselves.
///
/// Modeled on Claude Code's permission rules: a rule is a command
/// *prefix* (`cargo test`, `swift build`, `npm test`) and it matches a
/// command whose leading tokens are exactly that rule. Prefixes are what
/// make build trust usable at all — `cargo test`, `cargo test --lib` and
/// `cargo test -p core` are one decision to a human and three strings to
/// an exact-match list, which is why the session-scoped
/// `alwaysAllowedCommands` set never actually stopped anyone being asked
/// again on the next invocation.
///
/// Three limits are deliberate:
///
/// * **Only an attached folder can hold rules.** The synthetic
///   per-conversation workspace (`SandboxManager.directory`) is a UUID
///   directory inside Application Support that nobody chose and nobody
///   looks at; "always allow `cargo test` there" would be trust granted
///   for a place the user cannot see, silently inherited by whatever the
///   next conversation puts in its own. Attaching a real project folder
///   is an explicit act. A sandbox directory is not, so `folderPath` is
///   nil for one and no rule is ever stored or consulted.
/// * **A rule only ever matches one simple command.** Anything the
///   classifier cannot statically read — a pipe, `;`, a newline, a
///   substitution — can never be prefix-matched, so `cargo test; rm -rf
///   ~` is not a `cargo test`.
/// * **A denial is never overridden by a rule.** See `decision`.
///
/// None of this is a sandbox. `cargo test` runs `build.rs`, proc macros
/// and test bodies — code the model may have written moments earlier —
/// as the user, unconfined. See `SandboxManager` for why no confinement
/// exists, and the README's security note for the honest version.
public enum CommandTrust {
    public enum Decision: Equatable {
        /// A stored rule covers this command; run it without asking.
        case allowed(rule: String)
        /// Ask the user. Also what a previously-denied command gets, even
        /// when a rule would otherwise match it.
        case ask
    }

    /// One folder's remembered decisions.
    private struct FolderTrust: Codable {
        var rules: [String] = []
        /// Commands the user explicitly denied. Kept so that a later
        /// "always allow cargo" cannot quietly re-enable the exact command
        /// they refused.
        var denied: [String] = []
    }

    private static func load() -> [String: FolderTrust] {
        Defaults.decode([String: FolderTrust].self, DefaultsKey.commandAllowRules) ?? [:]
    }

    private static func save(_ store: [String: FolderTrust]) {
        Defaults.encode(store, DefaultsKey.commandAllowRules)
    }

    /// The rules remembered for an attached folder. A nil path (a sandbox
    /// workspace) has none, and never will.
    public static func rules(for folderPath: String?) -> [String] {
        guard let folderPath, !folderPath.isEmpty else { return [] }
        return load()[folderPath]?.rules ?? []
    }

    /// Remembers a prefix rule for an attached folder. Silently does
    /// nothing for a sandbox workspace or a rule that isn't one simple
    /// command — the caller is a UI button, and refusing loudly there
    /// would be noise about a state the UI doesn't offer.
    public static func allow(rule: String, for folderPath: String?) {
        guard let folderPath, !folderPath.isEmpty else { return }
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, CommandRunner.isSingleSimpleCommand(trimmed) else { return }
        var store = load()
        var trust = store[folderPath] ?? FolderTrust()
        guard !trust.rules.contains(trimmed) else { return }
        trust.rules.append(trimmed)
        trust.rules = Array(trust.rules.suffix(Limits.commandRulesPerFolder))
        store[folderPath] = trust
        save(store)
    }

    /// Records a denial so no later rule can auto-approve this exact
    /// command.
    public static func noteDenied(_ command: String, for folderPath: String?) {
        guard let folderPath, !folderPath.isEmpty else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var store = load()
        var trust = store[folderPath] ?? FolderTrust()
        guard !trust.denied.contains(trimmed) else { return }
        trust.denied.append(trimmed)
        trust.denied = Array(trust.denied.suffix(Limits.commandRulesPerFolder))
        store[folderPath] = trust
        save(store)
    }

    /// Drops everything remembered for a folder — the Settings "forget"
    /// action, and the only way rules ever go away.
    public static func forget(folderPath: String?) {
        guard let folderPath, !folderPath.isEmpty else { return }
        var store = load()
        store.removeValue(forKey: folderPath)
        save(store)
    }

    /// Whether this command may run without asking, for this folder.
    ///
    /// Deny wins. A command the user refused goes back to `.ask` rather
    /// than being auto-approved by a rule added afterwards — and to
    /// `.ask`, not to an automatic re-denial, because the person who said
    /// no once is exactly the person who should decide the second time,
    /// with the command in front of them.
    public static func decision(for command: String, folderPath: String?) -> Decision {
        guard let folderPath, !folderPath.isEmpty else { return .ask }
        guard CommandRunner.isSingleSimpleCommand(command) else { return .ask }
        guard let trust = load()[folderPath] else { return .ask }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trust.denied.contains(trimmed) { return .ask }
        if let rule = trust.rules.first(where: { matches(rule: $0, command: trimmed) }) {
            return .allowed(rule: rule)
        }
        return .ask
    }

    /// Prefix matching, token by token. `cargo test` matches
    /// `cargo test --lib`; it does not match `cargo` (too short),
    /// `cargotest` (a different binary), or anything carrying a shell
    /// operator (not statically one command at all).
    public static func matches(rule: String, command: String) -> Bool {
        guard CommandRunner.isSingleSimpleCommand(command) else { return false }
        let ruleTokens = tokens(rule)
        let commandTokens = tokens(command)
        guard !ruleTokens.isEmpty, commandTokens.count >= ruleTokens.count else { return false }
        return Array(commandTokens.prefix(ruleTokens.count)) == ruleTokens
    }

    /// The rule the approval card offers for a command: the binary plus
    /// its subcommand when it has one (`cargo test`, `swift build`,
    /// `git push`), the binary alone otherwise (`make`). Options are never
    /// part of a rule — `cargo test --lib` and `cargo test` are the same
    /// permission, and a rule that included the flags would ask again on
    /// the next invocation, which is the whole problem.
    public static func suggestedRule(for command: String) -> String? {
        guard CommandRunner.isSingleSimpleCommand(command) else { return nil }
        let parts = tokens(command)
        guard let binary = parts.first, !binary.isEmpty else { return nil }
        // An assignment prefix or a path-qualified binary makes the first
        // token something other than a program name; refuse to summarize
        // those into a rule at all.
        guard !binary.contains("="), !binary.contains("/") else { return nil }
        if let second = parts.dropFirst().first, !second.hasPrefix("-") {
            return "\(binary) \(second)"
        }
        return binary
    }

    private static func tokens(_ text: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
