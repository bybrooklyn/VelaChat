import Foundation

/// Classification and execution for `run_command`.
///
/// The safety model is deliberately simple and legible, because a
/// clever-but-opaque one is worse than an obvious one: a command is
/// auto-approved ONLY when every token of it is recognizably read-only.
/// Anything else — unknown binaries, writes, network, redirection,
/// substitution, sudo — asks the user first. Approval is a real human
/// decision in the transcript, not a heuristic pretending to be one.
enum CommandRunner {
    enum Classification: Equatable {
        /// Safe to run without asking: read-only inspection.
        case readOnly
        /// Needs the user's explicit approval, with the stated reason.
        case needsApproval(reason: String)
    }

    /// Commands that only read. Anything not on this list needs approval,
    /// so adding to it is the only way to widen auto-approval.
    ///
    /// Two names that look like they belong here deliberately don't:
    /// `env` runs whatever you put after it (`env rm -rf ~` is an `rm`, not
    /// an `env`), and `man` will execute an arbitrary pager via `-P` or
    /// `$MANPAGER`. Anything that can be turned into a launcher for another
    /// program is not a read-only command however it is named.
    private static let readOnlyBinaries: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "stat", "file", "du", "df",
        "pwd", "echo", "date", "whoami", "uname", "which", "type",
        "rg", "grep", "egrep", "fgrep", "find", "fd", "tree", "basename", "dirname",
        "sort", "uniq", "cut", "column", "diff", "cmp", "jq", "yq",
        "help", "printenv", "ps", "top",
    ]

    /// Flags that turn one of the read-only binaries above into a write.
    /// `sort -o out in` and `yq -i` rewrite files with no shell redirection
    /// anywhere in the command, so the operator scan never sees them.
    private static let writeFlagsByBinary: [String: Set<String>] = [
        "sort": ["-o", "--output"],
        "tree": ["-o"],
        "yq": ["-i", "--inplace"],
        "find": ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"],
    ]

    /// git subcommands that only read. `stash` is not among them — it
    /// rewrites the working tree.
    private static let readOnlyGitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "branch", "remote", "config",
        "blame", "describe", "ls-files", "rev-parse", "shortlog", "tag",
    ]

    /// Shell metacharacters that make static analysis unreliable — with
    /// any of these present, the command is never auto-approved regardless
    /// of which binary it names.
    private static let dangerousShellTokens = ["`", "$(", ">", ">>", "|", "&", ";", "&&", "||", "<"]

    /// Why this command cannot be reasoned about token by token, or nil
    /// when it can. Split out of `classify` because `CommandTrust` needs
    /// exactly the same judgement: a prefix rule must never match a
    /// command carrying a `;` or a newline, since the tokens after the
    /// operator are a different command entirely.
    private static func unanalyzableReason(_ trimmed: String) -> String? {
        for token in dangerousShellTokens where trimmed.contains(token) {
            // A pipe between two read-only commands is common and safe, but
            // proving that statically is exactly the kind of cleverness that
            // gets this wrong — ask instead.
            return "uses shell operators (\(token))"
        }
        // A newline separates commands in `zsh -lc` exactly like `;` does,
        // and splitting on " " alone did not see it: "cat notes.txt\nrm -rf
        // ~" classified on the binary `cat` and auto-ran the `rm`. Any
        // whitespace other than a plain space is treated as a separator we
        // cannot reason about.
        if trimmed.contains(where: { $0.isWhitespace && $0 != " " }) {
            return "spans more than one line"
        }
        return nil
    }

    /// Whether this is one simple command whose leading tokens mean what
    /// they look like. False for anything empty, multi-line, or containing
    /// a shell operator.
    static func isSingleSimpleCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && unanalyzableReason(trimmed) == nil
    }

    static func classify(_ command: String) -> Classification {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .needsApproval(reason: "empty command") }

        if let reason = unanalyzableReason(trimmed) {
            return .needsApproval(reason: reason)
        }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let binary = parts.first else { return .needsApproval(reason: "empty command") }
        if binary.contains("/") {
            return .needsApproval(reason: "runs an executable by path")
        }
        if binary == "sudo" || binary == "su" || binary == "doas" {
            return .needsApproval(reason: "runs with elevated privileges")
        }
        // `FOO=bar cmd` is an assignment prefix: the real binary is the next
        // token, so classifying on the first one reads the wrong command.
        if binary.contains("=") {
            return .needsApproval(reason: "sets environment variables inline")
        }
        if binary == "git" {
            let subcommand = parts.dropFirst().first { !$0.hasPrefix("-") } ?? ""
            if readOnlyGitSubcommands.contains(subcommand) {
                return .readOnly
            }
            return .needsApproval(reason: "git \(subcommand.isEmpty ? "command" : subcommand) can modify the repository")
        }
        let arguments = parts.dropFirst()
        if let writeFlags = writeFlagsByBinary[binary],
           let flag = arguments.first(where: { writeFlags.contains($0) }) {
            return .needsApproval(reason: "\(binary) \(flag) writes a file")
        }
        // `uniq in out` writes its second operand — no flag, no redirection.
        if binary == "uniq", arguments.filter({ !$0.hasPrefix("-") }).count >= 2 {
            return .needsApproval(reason: "uniq with two files writes the second one")
        }
        if readOnlyBinaries.contains(binary) {
            return .readOnly
        }
        return .needsApproval(reason: "\(binary) is not a known read-only command")
    }

    struct Output: Sendable {
        var text: String
        var exitCode: Int32
        var timedOut: Bool
    }

    /// One bool, written by the timeout watchdog and read by the waiter —
    /// on two different queues, so it needs a lock rather than being a
    /// captured `var`.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func set() {
            lock.lock()
            flag = true
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }

    /// Runs the command via `/bin/zsh -lc` in `directory`, capturing
    /// combined output with a hard timeout and an output cap.
    static func run(_ command: String, in directory: URL, timeout: TimeInterval = Limits.toolTimeout) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                // Homebrew paths, same lesson as the MCP client: a GUI app's
                // PATH does not include them.
                let extraPaths = "/opt/homebrew/bin:/usr/local/bin"
                environment["PATH"] = extraPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(text: "Error: could not start the command: \(error.localizedDescription)", exitCode: -1, timedOut: false))
                    return
                }

                let deadline = DispatchTime.now() + timeout
                // The watchdog runs on another queue and this one reads the
                // flag after `waitUntilExit()`, so a plain `var` was a real
                // cross-thread read/write. `cancel()` doesn't close the
                // window either — it can't stop a work item already running.
                let didTimeOut = TimeoutFlag()
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        didTimeOut.set()
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                var text = String(data: data, encoding: .utf8) ?? ""
                if text.count > Limits.commandOutputBytes {
                    text = String(text.prefix(Limits.commandOutputBytes)) + "\n[Truncated — first 20 KB of output.]"
                }
                continuation.resume(returning: Output(text: text, exitCode: process.terminationStatus, timedOut: didTimeOut.value))
            }
        }
    }

    /// The tool-result string the model sees: exit status first (it must
    /// never assume success), then output.
    static func formatted(_ output: Output, command: String) -> String {
        if output.timedOut {
            return "Error: `\(command)` timed out. Partial output:\n\(output.text)"
        }
        let status = output.exitCode == 0 ? "exit 0" : "exit \(output.exitCode)"
        let body = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = output.exitCode == 0 ? "" : "Error: command failed (\(status)).\n"
        if body.isEmpty {
            return prefix.isEmpty ? "(\(status), no output)" : prefix + "(no output)"
        }
        return prefix.isEmpty ? "(\(status))\n\(body)" : prefix + body
    }
}
