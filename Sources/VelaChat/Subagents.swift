import Foundation
import VelaCore

/// Parallel sub-conversations for fan-out work ("research these three
/// angles at once"). Each subagent is a plain, isolated request to the
/// same provider with the read-only tools — no nesting, no shell, no
/// memory writes — and its transcript is returned to the parent as the
/// tool result, so nothing happens invisibly.
enum Subagents {
    static let definition = ToolCatalog.Definition(
        name: "spawn_agents",
        description: "Run 1-3 independent sub-tasks at the same time, each handled by a fresh assistant that starts with an empty context and only the read-only tools (search, fetch, file reading — no writing, no shell). Returns their finished answers together, one \"## name\" section each, truncated at about 8,000 characters apiece. They run concurrently and cannot talk to each other or to you until they finish.",
        parametersJSON: #"{"type":"object","properties":{"tasks":{"type":"array","maxItems":3,"items":{"type":"object","properties":{"name":{"type":"string","description":"Very short label, e.g. \"pricing research\""},"prompt":{"type":"string","description":"The complete, self-contained instruction — the subagent sees none of this conversation"}},"required":["name","prompt"]}}},"required":["tasks"]}"#,
        guidance: "Each prompt must stand alone: state all the context it needs, since the subagent cannot see this conversation, your files, or the user's earlier messages. Prefer one subagent per genuinely separate question, and never use them for steps that must happen in order."
    )

    struct Task: Sendable {
        let name: String
        let prompt: String
    }

    /// Runs the tasks concurrently and returns one combined, labeled
    /// result. Failures are reported per-task rather than failing the set.
    static func run(
        tasks: [Task],
        profile: ProviderProfile,
        credential: ProviderCredential,
        model: String,
        tools: [ToolCatalog.Definition],
        toolContext: ToolCatalog.ExecutionContext
    ) async -> String {
        let capped = Array(tasks.prefix(Limits.maxSubagents))
        guard !capped.isEmpty else { return "Error: no tasks provided." }

        let results = await withTaskGroup(of: (Int, String).self) { group in
            for (index, task) in capped.enumerated() {
                group.addTask {
                    let system = ChatMessage(
                        role: "system",
                        content: """
                        You are a focused subagent working on one self-contained task for another assistant. \
                        You cannot ask questions or see the parent conversation. Do the work with the tools \
                        you have and reply with the finished result only — findings, answer, or summary — \
                        no preamble, no meta-commentary about being a subagent.
                        """
                    )
                    let user = ChatMessage(role: "user", content: task.prompt)
                    var text = ""
                    do {
                        let events = CompatibleChatClient.shared.streamChatEvents(
                            profile: profile,
                            credential: credential,
                            model: model,
                            thinking: .auto,
                            messages: [system, user],
                            tools: tools,
                            toolContext: tools.isEmpty ? nil : toolContext
                        )
                        for try await event in events {
                            if case .delta(let content, _) = event { text += content }
                        }
                    } catch {
                        return (index, "Error: \(error.localizedDescription)")
                    }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (index, trimmed.isEmpty ? "(no output)" : trimmed)
                }
            }
            var collected: [(Int, String)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }

        return results.map { index, output in
            let body = output.count > Limits.subagentOutputBytes ? String(output.prefix(Limits.subagentOutputBytes)) + "\n[Truncated.]" : output
            let name = capped[index].name
            return "## \(name.isEmpty ? "Subagent \(index + 1)" : name)\n\(body)"
        }.joined(separator: "\n\n")
    }

    /// The read-only slice of the parent's tools a subagent may use:
    /// no shell, no memory writes, no planning, and never spawning more.
    static func allowedTools(from tools: [ToolCatalog.Definition]) -> [ToolCatalog.Definition] {
        let blocked: Set<String> = [
            definition.name,
            ToolCatalog.runCommand.name,
            ToolCatalog.updatePlan.name,
            ToolCatalog.writeFile.name,
            ToolCatalog.editFile.name,
            ToolCatalog.saveMemory.name,
            ToolCatalog.editMemory.name,
        ]
        return tools.filter { !blocked.contains($0.name) }
    }
}
