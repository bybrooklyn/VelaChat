import Foundation

/// Finding the user's own `claude` binary.
///
/// The bridge spawns the binary the user already installed and logged in
/// to. It never reads their OAuth token out of Keychain to make inference
/// calls itself — that is the line this whole design exists to hold.
///
/// **The path must be absolute.** A bare `"claude"` does not resolve: a
/// GUI-launched app inherits `launchd`'s minimal PATH, not the login
/// shell's, so `/usr/bin/env claude` fails in the bundled app while
/// working perfectly from a terminal. The same bug exists at SDK level.
enum ClaudeExecutableLocator {
    struct Located: Equatable {
        var url: URL
        var version: String?
    }

    /// Where `claude` actually installs, most specific first. The user
    /// override in Settings wins over all of these.
    static func candidatePaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".bun/bin/claude"),
            home.appendingPathComponent(".volta/bin/claude"),
            URL(fileURLWithPath: "/usr/bin/claude")
        ]
    }

    /// Resolves an absolute path, or `nil` when Claude Code isn't
    /// installed. `nil` is a state the UI renders ("Claude Code not
    /// installed", with install instructions) — the provider never
    /// silently disappears from the list.
    static func locate(override: String? = nil) -> Located? {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(fileURLWithPath: override)
            guard isExecutable(url) else { return nil }
            return Located(url: url, version: version(of: url))
        }
        for candidate in candidatePaths() where isExecutable(candidate) {
            return Located(url: candidate, version: version(of: candidate))
        }
        // Last resort: ask a login shell, which has the user's real PATH.
        if let found = viaLoginShell(), isExecutable(found) {
            return Located(url: found, version: version(of: found))
        }
        return nil
    }

    static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// `zsh -lic 'command -v claude'` — a login+interactive shell, because
    /// most installers append to `.zshrc` rather than `.zprofile`.
    private static func viaLoginShell() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        guard first.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: first)
    }

    /// `claude --version` → "2.1.236 (Claude Code)". Captured for display
    /// and diagnostics only — behavior is decided by the `capabilities`
    /// array in the init handshake, never by parsing this.
    static func version(of url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The launch arguments, with the isolation flags **verified against a
    /// real Claude Code 2.1.236 session** rather than assumed:
    ///
    /// - `--setting-sources ""` alone does **not** isolate. A session
    ///   launched with only that flag still reported the user's MCP
    ///   servers, 15 inherited skills, and their full slash-command list
    ///   in the init handshake.
    /// - Adding `--strict-mcp-config` and `--disable-slash-commands`
    ///   produced `mcp_servers: []`, `skills: []`, `slash_commands: []`.
    /// - `--bare` looks like the right tool and is **not**: it forces auth
    ///   to `ANTHROPIC_API_KEY`/`apiKeyHelper` and never reads OAuth or
    ///   Keychain, which defeats the entire point of the bridge.
    /// - `--verbose` is mandatory; `--output-format stream-json` is
    ///   rejected without it.
    static func arguments(includePartialMessages: Bool) -> [String] {
        var args = [
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands"
        ]
        if includePartialMessages {
            args.append("--include-partial-messages")
        }
        return args
    }
}
