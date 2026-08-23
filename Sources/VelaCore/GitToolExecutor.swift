import Foundation

/// Execution for the §9.7 git tools: thin wrappers over `CommandRunner.run`
/// in the conversation's workspace, gated through the shared approval flow.
/// Read tools run free (the classifier already tiers `git status/diff/log`
/// as read-only); mutating ones confirm; push/PR hard-stop every time.
enum GitToolExecutor {

    private static func requireRepo(_ context: ToolCatalog.ExecutionContext) -> String? {
        guard GitInfo.isRepository(context.workspaceDirectory) else {
            return "This conversation has no attached folder that is a git repository. Attach the project folder first."
        }
        return nil
    }

    private static func approve(_ summary: String, sensitive: Bool, context: ToolCatalog.ExecutionContext) async -> Bool {
        guard let approve = context.approveGitWrite else { return false }
        return await approve(summary, sensitive)
    }

    static func status(context: ToolCatalog.ExecutionContext) async -> String {
        if let error = requireRepo(context) { return "Error: \(error)" }
        let output = await CommandRunner.run(
            "git status --porcelain=v2 --branch",
            in: context.workspaceDirectory
        )
        guard output.exitCode == 0 else {
            return "Error: git status failed — \(output.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
        }
        return GitTools.describe(GitTools.parseStatus(output.text))
    }

    static func diff(stagedOnly: Bool, context: ToolCatalog.ExecutionContext) async -> String {
        if let error = requireRepo(context) { return "Error: \(error)" }
        let command = stagedOnly ? "git diff --cached" : "git diff HEAD"
        let output = await CommandRunner.run(command, in: context.workspaceDirectory)
        guard output.exitCode == 0 else {
            return "Error: git diff failed — \(output.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
        }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return stagedOnly ? "Nothing is staged." : "No uncommitted changes." }
        if text.count > Limits.commandOutputBytes {
            return String(text.prefix(Limits.commandOutputBytes)) + "\n[Truncated — first 20 KB of diff.]"
        }
        return text
    }

    static func log(count requested: Int, context: ToolCatalog.ExecutionContext) async -> String {
        if let error = requireRepo(context) { return "Error: \(error)" }
        let count = max(1, min(requested, 100))
        let output = await CommandRunner.run(
            "git log --oneline -n \(count)",
            in: context.workspaceDirectory
        )
        guard output.exitCode == 0 else {
            return "Error: git log failed — \(output.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
        }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func commit(message: String, context: ToolCatalog.ExecutionContext) async -> String {
        if let error = requireRepo(context) { return "Error: \(error)" }
        // Confirmable tier per the classifier (.git(.commit)) — asks once;
        // session auto-allow may absorb later commits this chat.
        guard await approve("git commit — \(message.prefix(120))", sensitive: false, context: context) else {
            return "The user declined this commit. Don't retry unchanged — ask what they'd prefer."
        }
        // Single-quoted message via shell escaping discipline: pass the
        // message through `git commit -F -` on stdin instead of building a
        // quoted argv string — messages with quotes/newlines survive intact.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", context.workspaceDirectory.path, "commit", "-F", "-"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe
        do {
            try process.run()
            stdinPipe.fileHandleForWriting.write(Data(message.utf8))
            try? stdinPipe.fileHandleForWriting.close()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0 {
                return "Committed.\n\(text)"
            }
            // The classic case: nothing staged.
            let hint = text.lowercased().contains("no changes added") || text.isEmpty
                ? "\nNothing was staged. Stage files first (the user decides what), or check get_git_status."
                : ""
            return "Error: commit failed.\n\(text)\(hint)"
        } catch {
            return "Error: could not run git — \(error.localizedDescription)"
        }
    }

    static func pullRequest(title: String, body: String, base: String?, context: ToolCatalog.ExecutionContext) async -> String {
        if let error = requireRepo(context) { return "Error: \(error)" }
        // Sensitive tier, always: publishing to a shared repository never
        // rides session trust.
        guard await approve("open pull request \"\(title.prefix(100))\"", sensitive: true, context: context) else {
            return "The user declined to open this pull request."
        }
        guard let ghPath = ghBinary() else {
            return "The gh CLI isn't installed, so pull requests can't be opened from here. Install it (`brew install gh`) and run `gh auth login`. Commits still work without it."
        }
        var arguments = [ghPath, "pr", "create", "--title", title, "--body-file", "-"]
        if let base, !base.isEmpty { arguments += ["--base", base] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = context.workspaceDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["GH_PROMPT_DISABLED"] = "1"
        process.environment = environment
        let stdinPipe = Pipe(), outPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outPipe
        process.standardError = outPipe
        do {
            try process.run()
            stdinPipe.fileHandleForWriting.write(Data(body.utf8))
            try? stdinPipe.fileHandleForWriting.close()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0 {
                return "Pull request opened.\n\(text)"
            }
            var guidance = ""
            if text.lowercased().contains("not committed") || text.lowercased().contains("no commits") {
                guidance = "\nCommit and push first — create_pr opens PRs for existing work."
            } else if text.lowercased().contains("gh auth") {
                guidance = "\nRun `gh auth login` in a terminal once, then retry."
            }
            return "Error: gh pr create failed.\n\(text.suffix(600))\(guidance)"
        } catch {
            return "Error: could not run gh — \(error.localizedDescription)"
        }
    }

    private static func ghBinary() -> String? {
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
