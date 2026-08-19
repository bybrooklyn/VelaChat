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
    private static let readOnlyBinaries: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "stat", "file", "du", "df",
        "pwd", "echo", "date", "whoami", "uname", "which", "type",
        "rg", "grep", "egrep", "fgrep", "find", "fd", "tree", "basename", "dirname",
        "sort", "uniq", "cut", "column", "diff", "cmp", "jq", "yq",
        "man", "help", "env", "printenv", "ps", "top",
    ]

    /// git subcommands that only read.
    private static let readOnlyGitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "branch", "remote", "config",
        "blame", "describe", "ls-files", "rev-parse", "shortlog", "tag", "stash",
    ]

    /// Shell metacharacters that make static analysis unreliable — with
    /// any of these present, the command is never auto-approved regardless
    /// of which binary it names.
    private static let dangerousShellTokens = ["`", "$(", ">", ">>", "|", "&", ";", "&&", "||", "<"]

    static func classify(_ command: String) -> Classification {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .needsApproval(reason: "empty command") }

        for token in dangerousShellTokens where trimmed.contains(token) {
            // A pipe between two read-only commands is common and safe, but
            // proving that statically is exactly the kind of cleverness that
            // gets this wrong — ask instead.
            return .needsApproval(reason: "uses shell operators (\(token))")
        }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let binary = parts.first else { return .needsApproval(reason: "empty command") }
        if binary.contains("/") {
            return .needsApproval(reason: "runs an executable by path")
        }
        if binary == "sudo" || binary == "su" || binary == "doas" {
            return .needsApproval(reason: "runs with elevated privileges")
        }
        if binary == "git" {
            let subcommand = parts.dropFirst().first { !$0.hasPrefix("-") } ?? ""
            if readOnlyGitSubcommands.contains(subcommand), subcommand != "stash" {
                return .readOnly
            }
            return .needsApproval(reason: "git \(subcommand.isEmpty ? "command" : subcommand) can modify the repository")
        }
        // `find -delete`/`-exec` are writes wearing a read-only name.
        if binary == "find", parts.contains(where: { $0 == "-delete" || $0 == "-exec" || $0 == "-execdir" || $0 == "-ok" }) {
            return .needsApproval(reason: "find would execute or delete")
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

    /// Runs the command via `/bin/zsh -lc` in `directory`, capturing
    /// combined output with a hard timeout and an output cap.
    static func run(_ command: String, in directory: URL, timeout: TimeInterval = 120) async -> Output {
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
                var timedOut = false
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                var text = String(data: data, encoding: .utf8) ?? ""
                if text.count > 20_000 {
                    text = String(text.prefix(20_000)) + "\n[Truncated — first 20 KB of output.]"
                }
                continuation.resume(returning: Output(text: text, exitCode: process.terminationStatus, timedOut: timedOut))
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
