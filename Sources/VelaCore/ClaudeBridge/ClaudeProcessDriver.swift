import Foundation

// MARK: - The §7 process driver

extension CompatibleChatClient {

    /// Drives one `claude` subprocess for one reply — the process layer on
    /// top of the built protocol frames.
    ///
    /// Three probe-verified facts shape everything here:
    /// - **claude runs its own tool loop.** Unlike every other provider,
    ///   VelaChat executes nothing between rounds — claude's Bash/Read/
    ///   Edit run inside its own process. VelaChat's jobs are (a) showing
    ///   everything from the `assistant` `tool_use` frames (invariant 3:
    ///   pre-approved tools never generate a control request, so the
    ///   permission channel alone would hide most of the work), and
    ///   (b) gating permissions over the control channel.
    /// - **An unanswered permission request hangs claude indefinitely**
    ///   (>75s observed, no self-cancel) — the host imposes the deadline
    ///   and auto-denies with a message.
    /// - **`result.is_error` is false even on denials** — so nothing here
    ///   branches on it; every turn simply ends at its `result` frame.
    func streamClaudeCode(
        model: String,
        messages: [ChatMessage],
        toolContext: ToolCatalog.ExecutionContext?,
        onEvent: @escaping @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        guard let located = ClaudeExecutableLocator.locate() else {
            throw APIError.message("Claude Code isn't installed. Install it (`npm install -g @anthropic-ai/claude-code`), run `claude` once to sign in, then retry.")
        }
        let workspace = toolContext?.workspaceDirectory ?? FileManager.default.temporaryDirectory

        // Instruction files materialize into the working directory before
        // the turn, so claude sees the same AGENTS/CLAUDE context it would
        // see in a terminal there.
        for file in InstructionFiles.resolve(in: workspace).files {
            try? InstructionFiles.materialize(from: file, into: workspace)
        }

        // The exact invocation. `--setting-sources ""` is SAFETY-CRITICAL:
        // without it an on-disk permissionMode:auto silently bypasses this
        // host entirely — zero requests reach VelaChat. The empty string is
        // a real argv element, not an omitted flag. Never `--bare`.
        var arguments = ["--print"] + ClaudeExecutableLocator.arguments(includePartialMessages: false)
        arguments += ["--permission-prompt-tool", "stdio", "--model", model]

        let process = Process()
        process.executableURL = located.url
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        // A GUI app inherits launchd's minimal PATH; claude shells out to
        // git and friends constantly. Same fix as CommandRunner.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw APIError.message("Could not launch Claude Code: \(error.localizedDescription)")
        }

        // Cancellation must kill the subprocess, or a Stop leaves a headless
        // claude running with no reader on its pipes.
        let watchdog = Task.detached { [weak process] in
            while let process, process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
            try? stdinPipe.fileHandleForWriting.close()
        }

        func write(_ frame: ClaudeOutboundFrame) {
            guard let data = try? frame.encoded() else { return }
            stdinPipe.fileHandleForWriting.write(data)
        }

        write(.userTurn(text: Self.composedClaudeTurn(messages)))

        var activityByToolUseID: [String: UUID] = [:]

        for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
            guard let frame = ClaudeStreamFrame.decode(line: line) else { continue }
            switch frame {
            case .system:
                break

            case .assistant(let event):
                // Text and thinking stream as deltas; each tool_use becomes
                // an activity row keyed by its id — show-everything reads
                // THESE, never the control channel (Appendix B gotcha 1).
                let text = event.message.text
                let thinking = event.message.thinking
                if !text.isEmpty || !thinking.isEmpty {
                    onEvent(.delta(content: text, reasoning: thinking))
                }
                for use in event.message.toolUses {
                    let activityID = UUID()
                    activityByToolUseID[use.id] = activityID
                    onEvent(.activityStarted(id: activityID, name: use.name, argument: use.summary))
                }
                if let usage = event.message.usage {
                    emitClaudeUsage(usage, onEvent: onEvent)
                }

            case .user(let event):
                // tool results replayed back into the conversation.
                for result in event.toolResults {
                    let id = activityByToolUseID[result.toolUseID] ?? UUID()
                    var text = result.text
                    if text.count > Limits.commandOutputBytes {
                        text = String(text.prefix(Limits.commandOutputBytes)) + "\n[Truncated — kept the first 20 KB.]"
                    }
                    onEvent(.activityFinished(id: id, result: text, isError: result.isError))
                }

            case .rateLimit(let event):
                if let snapshot = Self.quotaSnapshot(fromRateLimit: event) {
                    onEvent(.quota(snapshot))
                }

            case .controlRequest(let request):
                guard request.isPermission else { break }
                await handleClaudePermission(request, toolContext: toolContext, write: write)

            case .controlResponse, .unknown:
                break

            case .result(let result):
                if let usage = result.usage {
                    emitClaudeUsage(usage, onEvent: onEvent)
                }
                onEvent(.finished(reason: nil))
                return
            }
        }

        // Stream ended without a result frame — abnormal but real (a crash
        // mid-turn). Surface stderr rather than finishing silently.
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw APIError.message(
                stderrText.isEmpty
                    ? "Claude Code exited unexpectedly (\(process.terminationStatus))."
                    : "Claude Code failed: \(stderrText.suffix(600))"
            )
        }
        onEvent(.finished(reason: nil))
    }

    // MARK: pieces

    /// Anthropic-shaped usage → ChatStreamEvent.usage. Cache reads map to
    /// cachedTokens; the 5m/1h cache-write split rides through as-is (the
    /// only provider that reports it).
    private func emitClaudeUsage(_ usage: ClaudeUsage, onEvent: @escaping @Sendable (ChatStreamEvent) -> Void) {
        let creation = CacheCreationTokens(
            ephemeral5m: usage.cacheCreation?.ephemeral5m ?? usage.cacheCreationInputTokens,
            ephemeral1h: usage.cacheCreation?.ephemeral1h ?? 0
        )
        onEvent(.usage(
            prompt: usage.inputTokens,
            completion: usage.outputTokens,
            cachedTokens: usage.cacheReadInputTokens,
            cacheCreation: (creation.ephemeral5m ?? 0) > 0 || (creation.ephemeral1h ?? 0) > 0 ? creation : nil
        ))
    }
}

extension CompatibleChatClient {

    /// One permission ask → one decision, with the host-imposed deadline.
    /// The approval UI lives app-side; VelaCore only sees the async
    /// question. On timeout (or no channel wired), auto-deny WITH a reason:
    /// a deny without `message` errors and makes claude retry forever.
    private func handleClaudePermission(
        _ request: ClaudeControlRequest,
        toolContext: ToolCatalog.ExecutionContext?,
        write: @escaping @Sendable (ClaudeOutboundFrame) -> Void
    ) async {
        let requestID = request.requestID ?? ""
        guard let requestID = request.requestID, !requestID.isEmpty else { return }
        let toolName = request.toolName ?? "tool"
        let summary = Self.permissionSummary(request)

        let decision: Bool?
        if let approve = toolContext?.claudePermission {
            decision = await withTimeout(seconds: Limits.claudePermissionTimeout) {
                await approve(toolName, summary, request.toolInput ?? .null)
            }
        } else {
            decision = nil // no channel wired — deny closed below
        }


        if decision == true {
            write(.permissionAllow(requestID: requestID, updatedInput: nil))
        } else {
            let reason = decision == nil
                ? "No approval channel was available for this request."
                : "The approval timed out after \(Int(Limits.claudePermissionTimeout)) seconds with no answer."
            write(.permissionDeny(requestID: requestID, reason: reason))
        }
    }

    /// One-line summary of what the permission is asking about, mirroring
    /// ClaudeToolUse.summary's key preference so the card reads the same
    /// whether the row came from show-everything or from an escalation.
    static func permissionSummary(_ request: ClaudeControlRequest) -> String {
        guard case .object(let fields)? = request.toolInput else { return "" }
        for key in ["command", "file_path", "path", "pattern", "query", "url", "description"] {
            if case .string(let value)? = fields[key] { return value }
        }
        return ""
    }

    /// Bounds an async call; `nil` means the deadline passed. Polling a
    /// thread-safe answer slot rather than task-racing keeps cancellation
    /// simple and never leaks the loser of a race.
    private func withTimeout(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Bool) async -> Bool? {
        let box = TimeoutBox()
        let work = Task.detached {
            let value = await operation()
            box.set(value)
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = box.value {
                work.cancel()
                return value
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        work.cancel()
        return nil
    }

    /// The conversation composed into the single initial user turn — one
    /// process per turn, no external session state (invariant 6). A fresh
    /// conversation sends just its latest message raw; anything longer gets
    /// an explicitly labeled transcript so claude knows what it's reading.
    static func composedClaudeTurn(_ messages: [ChatMessage]) -> String {
        let real = messages.filter { !$0.isSynthetic && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let last = real.last else { return "Hello." }
        guard real.count > 1 else {
            return last.contentForRequest
        }
        var transcript = "Here is the conversation so far. Respond to the LATEST user message at the end.\n\n"
        for message in real.dropLast() {
            let speaker = message.role == "assistant" ? "Assistant" : "User"
            transcript += "--- \(speaker) ---\n\(message.contentForRequest)\n\n"
        }
        transcript += "--- User (respond to this) ---\n\(last.contentForRequest)"
        return transcript
    }

    /// The rate-limit frame carries a reset time and window length but NO
    /// utilization percentage — a percent would be invented, and unobserved
    /// numbers are never implied. Only a definite `rate_limited` status maps
    /// to a full window; everything else stays quiet.
    static func quotaSnapshot(fromRateLimit event: ClaudeRateLimitEvent) -> QuotaSnapshot? {
        guard let info = event.info,
              let resetsAt = info.resetDate else { return nil }
        guard info.status?.lowercased() == "rate_limited" else { return nil }
        return QuotaSnapshot(
            planName: nil,
            primaryWindow: QuotaSnapshot.Window(
                usedPercent: 100,
                windowMinutes: info.windowMinutes,
                resetAt: resetsAt
            ),
            secondaryWindow: nil
        )
    }
}

/// Thread-safe answer slot for the timeout poller.
final class TimeoutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
