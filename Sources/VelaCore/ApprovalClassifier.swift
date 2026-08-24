import Foundation

/// The shared two-tier approval classifier (§3) — ONE policy function that
/// every consumer routes through: the shell command runner, the Claude
/// bridge's permission routing, computer use, browsing, git/PR tools, and
/// gist publishing. Modeled on Claude Code's auto-mode: reads and other
/// low-consequence actions flow without prompting; ordinary state changes
/// confirm once and may then ride session trust; the sensitive set always
/// stops, and never rides session auto-allow no matter what was allowed
/// before.
///
/// Why a separate layer from `CommandRunner.classify` and `CommandTrust`:
/// those answer "may this run without asking THIS time" for one consumer.
/// This answers "which KIND of decision does this action deserve" for all
/// of them. A `git push` and a `cargo test` both need approval today, but
/// only one of them may ever be swallowed by "allow every command in this
/// chat" — that difference lives here, in one testable place, not in five
/// consumers' worth of string matching.
public enum ApprovalClassifier {

    // MARK: - Tiers

    public enum Tier: Equatable {
        /// Read-only / pure inspection. Flows without prompting.
        case free
        /// Ordinary state change: confirmable once; session auto-allow
        /// ("allow all", prefix rules) may apply afterwards.
        case confirmable
        /// Sends, purchases, logins, publishing (public + permanent),
        /// irreversible deletes, credential-touching, and anything whose
        /// payload static analysis cannot read. Always a card; session
        /// auto-allow NEVER applies.
        case sensitive(reason: String)
    }

    /// True when session-scoped trust (allow-all, remembered commands,
    /// prefix rules) may absorb this action. The single question every
    /// consumer asks before consulting its own remembered decisions.
    public static func sessionTrustMayAllow(_ tier: Tier) -> Bool {
        if case .sensitive = tier { return false }
        return true
    }

    // MARK: - Action vocabulary

    /// One concrete thing a consumer wants to do, across every approval
    /// consumer's domain. Cases carry exactly the context classification
    /// needs — no more, so perception layers stay dumb reporters.
    public enum Action: Equatable {

        public enum GitOperation: Equatable {
            case status, diff, log, show, blame, branchList
            case add, commit, checkout, createBranch, stash, pull, merge, createTag
            case push
            /// History rewrites and removals that can lose work:
            /// rebase, `reset --hard`, clean, branch/tag delete.
            case rewriteHistory
            case deleteRef
        }

        public enum BrowseAction: Equatable {
            /// DOM perception, page text — reading costs nothing.
            case read
            case navigate(url: URL)
            case click(label: String)
            case type(label: String, isCredentialField: Bool)
            /// Submitting a form. The perception layer reports whether the
            /// form carries password/payment signals; the classifier decides.
            case submitForm(hasPasswordField: Bool, mentionsPayment: Bool)
        }

        public enum ActuationKind: Equatable {
            case inspect
            case press(label: String)
            case typeText(label: String?)
        }

        case shellCommand(String)
        case git(GitOperation)
        case browse(BrowseAction)
        /// Computer use. Scope containment is part of classification: an
        /// actuation aimed at an app the user did not arm is sensitive even
        /// when the action itself would be ordinary (`nil` actual app means
        /// unknown — treated as outside).
        case actuate(ActuationKind, scopedAppBundleID: String?, targetAppBundleID: String?)
        /// Secret-by-default publishing still lands somewhere others can
        /// reach; only the *prompt* differs, never the tier.
        case publishGist(isPublic: Bool)
        case publishPullRequest
        case publishRelease
        case publishPackage
        /// Email/chat/post leaving the machine on the user's behalf.
        case sendMessage(context: String)
    }

    // MARK: - The one function

    public static func classify(_ action: Action) -> Tier {
        switch action {
        case .shellCommand(let command):
            return classifyShell(command)
        case .git(let operation):
            return classifyGit(operation)
        case .browse(let browserAction):
            return classifyBrowse(browserAction)
        case .actuate(let kind, let scoped, let target):
            return classifyActuation(kind, scoped: scoped, target: target)
        case .publishGist, .publishPullRequest, .publishRelease, .publishPackage:
            return .sensitive(reason: "publishing makes content reachable by others")
        case .sendMessage(let context):
            return .sensitive(reason: "sending \(context) reaches someone else")
        }
    }

    // MARK: - Shell

    /// Binaries whose whole job is to run something else, or which actuate
    /// the wider system — allowing them as a class would let any future
    /// command hide inside them.
    private static let launcherBinaries: Set<String> = [
        "osascript", "expect",
    ]

    private static func classifyShell(_ command: String) -> Tier {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Sensitive patterns are matched on the raw string BEFORE the
        // simple-command gate, because several of them are precisely the
        // shapes the gate refuses to reason about (a pipe into a shell).
        if let reason = sensitiveShellReason(trimmed) {
            return .sensitive(reason: reason)
        }

        // Not sensitive: the existing read-only analysis decides between
        // free and confirmable. Its verdicts are unchanged — this layer
        // only adds the hard-stop tier above them.
        switch CommandRunner.classify(trimmed) {
        case .readOnly:
            return .free
        case .needsApproval:
            return .confirmable
        }
    }

    /// The sensitive-set scan for shell commands. Every rule here exists
    /// because session auto-allow must never swallow it.
    private static func sensitiveShellReason(_ command: String) -> String? {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let binary = parts.first else { return nil }

        // Elevation. A sudoed anything can be anything.
        if binary == "sudo" || binary == "su" || binary == "doas" {
            return "runs with elevated privileges"
        }

        // Interpreters invoked with inline code — the payload is invisible
        // to token-level rules, so trusting the wrapper trusts everything.
        if ["sh", "bash", "zsh", "dash", "ksh"].contains(binary), parts.contains("-c") {
            return "runs inline shell code"
        }
        if binary == "eval" || launcherBinaries.contains(binary) {
            return "\(binary) executes arbitrary code"
        }
        if binary == "xargs", let next = parts.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return "xargs runs \(next) with input as arguments"
        }

        // Remote code piped straight into an interpreter.
        let lowercased = command.lowercased()
        if ["curl", "wget"].contains(binary), lowercased.contains("|"),
           ["sh", "bash", "zsh", "python", "python3", "ruby", "perl"].contains(where: { lowercased.contains("| \($0)") || lowercased.contains("|\($0)") }) {
            return "runs code fetched from the network"
        }

        // Publishing to shared state.
        if binary == "git", subcommand(parts) == "push" {
            return "git push updates a remote repository others share"
        }
        if binary == "gh" {
            let ghSubcommand = parts.dropFirst().first ?? ""
            let ghVerb = parts.dropFirst(2).first ?? ""
            if ghSubcommand == "pr", ghVerb == "create" {
                return "opening a pull request publishes to the shared repository"
            }
            if ghSubcommand == "gist", ghVerb == "create" {
                return "publishing a gist makes its content reachable by others"
            }
            if ghSubcommand == "release", ghVerb == "create" {
                return "publishing a release is public and permanent"
            }
            if ghSubcommand == "auth" {
                return "gh auth touches stored credentials"
            }
        }

        // Credentials on disk and in the keychain.
        if binary == "security" {
            return "reads or writes the macOS keychain"
        }
        if binary == "ssh-add" || (binary == "ssh" && subcommand(parts) == "add") {
            return "touches SSH agent credentials"
        }
        let credentialMarkers = ["/.ssh/", "/.aws/", "/.gnupg/", "/.config/gh/", ".netrc", "/.env"]
        if credentialMarkers.contains(where: command.contains) {
            return "touches credential storage"
        }

        // Deletes you cannot take back.
        if binary == "rm" {
            let recursive = parts.dropFirst().contains { token in
                guard token.hasPrefix("-"), !token.hasPrefix("/") else { return false }
                return token.contains("r")
            }
            let broadTargets: Set<String> = ["/", "~", "~/", "/*", "~/*"]
            let targetsRoot = parts.dropFirst().contains { broadTargets.contains($0) }
            if recursive, targetsRoot {
                return "recursively deletes a broad path"
            }
        }
        if (binary == "mkfs" || binary == "diskutil"), lowercased.contains("erase") {
            return "erases a filesystem"
        }
        if binary == "dd", lowercased.contains("of=/dev/") {
            return "writes directly to a device"
        }

        return nil
    }

    private static func subcommand(_ parts: [String]) -> String {
        parts.dropFirst().first { !$0.hasPrefix("-") } ?? ""
    }

    // MARK: - Git (the first-class tools' vocabulary)

    private static func classifyGit(_ operation: Action.GitOperation) -> Tier {
        switch operation {
        case .status, .diff, .log, .show, .blame, .branchList:
            return .free
        case .push:
            return .sensitive(reason: "git push updates a remote repository others share")
        case .rewriteHistory, .deleteRef:
            return .sensitive(reason: "rewrites or removes history — work can be lost")
        case .add, .commit, .checkout, .createBranch, .stash, .pull, .merge, .createTag:
            return .confirmable
        }
    }

    // MARK: - Browsing

    private static func classifyBrowse(_ action: Action.BrowseAction) -> Tier {
        switch action {
        case .read, .navigate:
            return .free
        case .click:
            // An ordinary click stays confirmable even when it lands on a
            // button — the form-submit signals below are what escalate.
            return .confirmable
        case .type(_, let isCredentialField):
            if isCredentialField {
                return .sensitive(reason: "typing into a credential field")
            }
            return .confirmable
        case .submitForm(let hasPasswordField, let mentionsPayment):
            if hasPasswordField {
                return .sensitive(reason: "submitting a login form")
            }
            if mentionsPayment {
                return .sensitive(reason: "submitting a payment or checkout form")
            }
            return .confirmable
        }
    }

    // MARK: - Computer use

    private static func classifyActuation(
        _ kind: Action.ActuationKind,
        scoped: String?,
        target: String?
    ) -> Tier {
        // Reading the AX tree is free, wherever it points.
        if case .inspect = kind { return .free }

        // Scope containment first: acting outside (or outside-known) scope
        // is a hard stop even for an ordinary action, so a wedged agent
        // cannot wander into Mail.
        guard let scoped, let target, scoped == target else {
            return .sensitive(reason: "target app is outside the armed scope")
        }

        switch kind {
        case .inspect:
            return .free
        case .press(let label):
            if SensitiveTargetVocabulary.matches(label) {
                return .sensitive(reason: "target looks like send/delete/purchase/credential (\(label))")
            }
            return .confirmable
        case .typeText(let label):
            if let label, SensitiveTargetVocabulary.matches(label) {
                return .sensitive(reason: "target looks like send/delete/purchase/credential (\(label))")
            }
            return .confirmable
        }
    }
}

/// Label vocabulary that marks a computer-use target as sensitive no matter
/// how ordinary the action type is. A separate type so it can grow without
/// touching the classifier's structure.
enum SensitiveTargetVocabulary {
    private static let markers: [String] = [
        "send", "delete", "remove permanently", "purchase", "buy", "checkout",
        "pay", "payment", "credit card", "sign in", "log in", "login",
        "password", "empty trash",
    ]

    static func matches(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return markers.contains { lowered.contains($0) }
    }
}
