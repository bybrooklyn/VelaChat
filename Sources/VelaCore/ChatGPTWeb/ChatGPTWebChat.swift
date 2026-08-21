import Foundation

/// Streaming conversation turns over ChatGPT Web — ported from the
/// reference runtime's direct transport: sentinel prefetch, the
/// observed /backend-api/conversation body, SSE snapshots prefix-diffed
/// into deltas, and conversation-state recovery when a stream drops.
///
/// Continuation is real: each VelaChat conversation maps to one
/// upstream ChatGPT conversation and its current assistant node, so
/// follow-up turns send only the new message. If VelaChat's local
/// history diverges (edit/regenerate/branch/relaunch), the turn starts
/// a fresh upstream conversation with an explicit transcript replay —
/// never silently continuing from the wrong node.
public actor ChatGPTWebChat {
    public static let shared = ChatGPTWebChat()

    private struct Continuation {
        var conversationID: String
        var parentNodeID: String
        /// The final assistant text of the last completed turn — the
        /// checksum that proves local history still matches upstream.
        var lastAssistantText: String
    }

    private var continuations: [UUID: Continuation] = [:]
    private var sentinelToken: (token: String?, at: Date)?

    // MARK: - Entry

    public static func stream(
        conversationKey: UUID?,
        model: String,
        thinking: ThinkingLevel,
        messages: [ChatMessage],
        onEvent: @escaping @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        try await shared.run(conversationKey: conversationKey, model: model, thinking: thinking, messages: messages, onEvent: onEvent)
    }

    private func run(
        conversationKey: UUID?,
        model: String,
        thinking: ThinkingLevel,
        messages: [ChatMessage],
        onEvent: @escaping @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        let client = ChatGPTWebClient.shared
        guard await client.isConfigured else {
            throw ChatGPTWebClient.ClientError.notAuthenticated
        }

        // Split incoming request history: system preamble, prior turns,
        // and the current (last) user message.
        let systemText = messages.filter { $0.role == "system" }.map(\.contentForRequest).joined(separator: "\n\n")
        let turns = messages.filter { $0.role == "user" || $0.role == "assistant" }
        guard let currentUser = turns.last, currentUser.role == "user" else {
            throw APIError.message("ChatGPT turns need a trailing user message.")
        }
        let priorTurns = Array(turns.dropLast())

        // Continuation check: history must end exactly where the stored
        // upstream node ended.
        var continuing: Continuation?
        if let conversationKey, let stored = continuations[conversationKey],
           let lastAssistant = priorTurns.last(where: { $0.role == "assistant" }),
           lastAssistant.contentForRequest == stored.lastAssistantText {
            continuing = stored
        }

        var prompt: String
        if continuing != nil {
            prompt = currentUser.contentForRequest
        } else {
            // Fresh upstream conversation — replay context explicitly.
            var sections: [String] = []
            if !systemText.isEmpty {
                sections.append("[App context — follow these instructions]\n\(systemText)")
            }
            if !priorTurns.isEmpty {
                let transcript = priorTurns.map { message in
                    "\(message.role == "user" ? "User" : "Assistant"): \(message.contentForRequest)"
                }.joined(separator: "\n\n")
                sections.append("[Conversation so far — replayed for continuity, do not repeat it]\n\(transcript)")
            }
            sections.append(sections.isEmpty ? currentUser.contentForRequest : "[Current message]\n\(currentUser.contentForRequest)")
            prompt = sections.joined(separator: "\n\n")
        }

        // Sentinel requirements: best-effort prefetch, 60s cache; an
        // interactive challenge is surfaced, never bypassed.
        var sentinel = try? await chatRequirementToken(client: client, force: false)

        let userMessageID = UUID().uuidString.lowercased()
        var body: [String: Any] = [
            "action": "next",
            "messages": [[
                "id": userMessageID,
                "author": ["role": "user"],
                "create_time": Date().timeIntervalSince1970,
                "content": ["content_type": "text", "parts": [prompt]],
                "metadata": [String: String]()
            ]],
            "parent_message_id": continuing?.parentNodeID ?? UUID().uuidString.lowercased(),
            "model": model,
            "timezone_offset_min": -TimeZone.current.secondsFromGMT() / 60,
            "timezone": TimeZone.current.identifier,
            "conversation_mode": ["kind": "primary_assistant"],
            "history_and_training_disabled": false,
            "force_paragen": false,
            "force_rate_limit": false,
            "suggestions": [String]()
        ]
        if let continuing {
            body["conversation_id"] = continuing.conversationID
        }

        // Reasoning effort: the current field name first, the legacy one
        // as fallback, then none — mirroring the reference's attempts.
        let effortValue = Self.effortValue(for: thinking)
        var attempts: [(field: String?, value: String?)] = []
        if let effortValue {
            attempts.append(("thinking_effort", effortValue))
            attempts.append(("reasoning_effort", effortValue))
        }
        attempts.append((nil, nil))

        var sentinelRetried = false
        var streamed: (data: URLSession.AsyncBytes, response: HTTPURLResponse)?
        var lastFailure = ""
        attemptLoop: for attempt in attempts {
            var payload = body
            if let field = attempt.field, let value = attempt.value { payload[field] = value }
            while true {
                var headers = ["content-type": "application/json", "accept": "text/event-stream"]
                if let token = sentinel { headers["openai-sentinel-chat-requirements-token"] = token }
                let (bytes, response) = try await client.authedStream(path: "backend-api/conversation", jsonBody: payload, extraHeaders: headers)
                if response.statusCode == 200 {
                    streamed = (bytes, response)
                    break attemptLoop
                }
                var failureText = ""
                for try await line in bytes.lines { failureText += line; if failureText.count > 2_000 { break } }
                lastFailure = failureText
                if !sentinelRetried, [400, 403, 409, 422].contains(response.statusCode),
                   failureText.range(of: "sentinel|requirement|proof|token", options: [.regularExpression, .caseInsensitive]) != nil {
                    sentinelRetried = true
                    sentinel = try? await chatRequirementToken(client: client, force: true)
                    continue
                }
                if [400, 422].contains(response.statusCode), attempt.field != nil {
                    continue attemptLoop  // try the next reasoning-field variant
                }
                if response.statusCode == 401 { throw ChatGPTWebClient.ClientError.notAuthenticated }
                if response.statusCode == 403 { throw ChatGPTWebClient.ClientError.challenge }
                if response.statusCode == 429 {
                    throw APIError.message("ChatGPT says you've hit a rate limit — check the usage gauge, or wait for the window to reset.")
                }
                throw ChatGPTWebClient.ClientError.http(response.statusCode, String(lastFailure.prefix(300)))
            }
        }
        guard let streamed else {
            throw ChatGPTWebClient.ClientError.http(502, String(lastFailure.prefix(300)))
        }

        // SSE consumption: cumulative message snapshots, prefix-diffed.
        var emittedText = ""
        var emittedReasoning = ""
        var conversationID = continuing?.conversationID
        var nodeID: String?
        var finished = false
        do {
            for try await line in streamed.data.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }
                let payloadText = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payloadText == "[DONE]" { break }
                guard let data = payloadText.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let errorValue = parsed["error"] {
                    throw APIError.message("ChatGPT stream error: \(Self.errorText(errorValue))")
                }
                guard let snapshot = Self.snapshot(from: parsed) else { continue }
                conversationID = snapshot.conversationID ?? conversationID
                nodeID = snapshot.messageID ?? nodeID
                if let text = snapshot.text {
                    if snapshot.isReasoning {
                        if text.hasPrefix(emittedReasoning), text.count > emittedReasoning.count {
                            let delta = String(text.dropFirst(emittedReasoning.count))
                            emittedReasoning = text
                            onEvent(.delta(content: "", reasoning: delta))
                        }
                    } else {
                        if text.hasPrefix(emittedText), text.count > emittedText.count {
                            let delta = String(text.dropFirst(emittedText.count))
                            emittedText = text
                            onEvent(.delta(content: delta, reasoning: ""))
                        } else if emittedText.isEmpty, !text.isEmpty {
                            emittedText = text
                            onEvent(.delta(content: text, reasoning: ""))
                        }
                    }
                }
                if snapshot.endTurn || snapshot.status == "finished_successfully" { finished = true }
            }
        } catch is CancellationError {
            // Stop pressed: tell the backend, keep what streamed.
            if let conversationID {
                try? await stopConversation(client: client, conversationID: conversationID)
            }
            throw CancellationError()
        } catch {
            // Stream dropped mid-turn — recover the assistant text from
            // conversation state instead of failing or replaying the turn.
            guard let conversationID else { throw error }
            guard let recovered = await recoverAssistantText(client: client, conversationID: conversationID, preferredNode: nodeID) else {
                throw error
            }
            if recovered.text.hasPrefix(emittedText), recovered.text.count > emittedText.count {
                onEvent(.delta(content: String(recovered.text.dropFirst(emittedText.count)), reasoning: ""))
            }
            emittedText = recovered.text
            nodeID = recovered.nodeID ?? nodeID
            finished = recovered.finished
        }

        if let conversationKey, let conversationID, let nodeID, finished || !emittedText.isEmpty {
            continuations[conversationKey] = Continuation(
                conversationID: conversationID,
                parentNodeID: nodeID,
                lastAssistantText: emittedText
            )
        }
    }

    /// Local history was rewritten (branch, delete, clear) — never
    /// continue an upstream conversation whose tail no longer matches.
    public func forgetContinuation(for conversationKey: UUID) {
        continuations[conversationKey] = nil
    }

    // MARK: - Helpers

    private func chatRequirementToken(client: ChatGPTWebClient, force: Bool) async throws -> String? {
        if !force, let sentinelToken, Date().timeIntervalSince(sentinelToken.at) < 60 {
            return sentinelToken.token
        }
        let (data, http) = try await client.authedRequest(path: "backend-api/sentinel/chat-requirements", method: "POST", jsonBody: [:])
        guard http.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func required(_ key: String, _ altKey: String? = nil) -> Bool {
            let block = (payload[key] ?? altKey.flatMap { payload[$0] }) as? [String: Any]
            return block?["required"] as? Bool == true
        }
        if required("proofofwork", "proof_of_work") || required("arkose") || required("turnstile") {
            throw ChatGPTWebClient.ClientError.challenge
        }
        let token = (payload["token"] ?? payload["chat_requirements_token"]) as? String
        sentinelToken = (token, Date())
        return token
    }

    private func stopConversation(client: ChatGPTWebClient, conversationID: String) async throws {
        _ = try await client.authedRequest(
            path: "backend-api/stop_conversation",
            method: "POST",
            jsonBody: ["conversation_id": conversationID]
        )
    }

    private func recoverAssistantText(
        client: ChatGPTWebClient,
        conversationID: String,
        preferredNode: String?
    ) async -> (text: String, nodeID: String?, finished: Bool)? {
        for attempt in 0..<3 {
            if let (data, http) = try? await client.authedRequest(path: "backend-api/conversation/\(conversationID)"),
               http.statusCode == 200,
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mapping = payload["mapping"] as? [String: Any] {
                let current = preferredNode ?? (payload["current_node"] as? String)
                if let current,
                   let node = mapping[current] as? [String: Any],
                   let message = node["message"] as? [String: Any],
                   ((message["author"] as? [String: Any])?["role"] as? String) == "assistant" {
                    let text = Self.messageText(message) ?? ""
                    let finished = (message["end_turn"] as? Bool == true) || (message["status"] as? String == "finished_successfully")
                    if !text.isEmpty || finished {
                        return (text, message["id"] as? String ?? current, finished)
                    }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(350_000_000 * (attempt + 1)))
        }
        return nil
    }

    // MARK: - Snapshot parsing (ported parseConversationSnapshot)

    private struct Snapshot {
        var conversationID: String?
        var messageID: String?
        var text: String?
        var isReasoning: Bool
        var status: String?
        var endTurn: Bool
    }

    private static func snapshot(from parsed: [String: Any]) -> Snapshot? {
        let message = (parsed["message"] as? [String: Any])
            ?? ((parsed["data"] as? [String: Any])?["message"] as? [String: Any])
        guard let message else { return nil }
        let role = ((message["author"] as? [String: Any])?["role"] as? String) ?? (message["role"] as? String)
        if let role, role != "assistant", role != "tool" { return nil }
        let content = message["content"] as? [String: Any]
        let contentType = ((content?["content_type"] ?? content?["type"]) as? String)?.lowercased() ?? ""
        // Only user-visible reasoning summaries — never hidden CoT fields.
        let isReasoning = contentType.contains("reasoning_recap")
            || contentType.contains("reasoning_summary")
            || contentType.contains("thought_summary")
        return Snapshot(
            conversationID: (parsed["conversation_id"] ?? parsed["conversationId"]) as? String,
            messageID: message["id"] as? String,
            text: messageText(message),
            isReasoning: isReasoning,
            status: message["status"] as? String,
            endTurn: message["end_turn"] as? Bool == true
        )
    }

    private static func messageText(_ message: [String: Any]) -> String? {
        let content = message["content"] as? [String: Any]
        if let parts = content?["parts"] as? [Any] {
            let text = parts.compactMap { part -> String? in
                if let string = part as? String { return string }
                if let dict = part as? [String: Any] {
                    return (dict["text"] ?? dict["content"]) as? String
                }
                return nil
            }.joined()
            if !text.isEmpty { return text }
        }
        return (content?["text"] as? String) ?? (message["text"] as? String)
    }

    private static func effortValue(for level: ThinkingLevel) -> String? {
        switch level {
        case .auto: nil
        case .off, .low: "instant"
        case .medium: "medium"
        case .high: "high"
        case .extraHigh: "extra_high"
        case .max: "pro"
        }
    }

    private static func errorText(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let dict = value as? [String: Any] {
            return (dict["message"] as? String) ?? String(describing: dict).prefix(200).description
        }
        return String(describing: value).prefix(200).description
    }
}
