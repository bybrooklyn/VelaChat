import Foundation

/// The app's whole voice to the model, composed per-request in one
/// structured preamble instead of scattered instruction fragments. The
/// user's own custom instructions, memories, and skills are inserted ABOVE
/// this by `AppModel.send` — the user always outranks the app.
///
/// Inventory style follows what the serious agent harnesses (Claude
/// Code, Codex CLI) actually do: each tool gets when-to-use guidance,
/// there's an explicit preamble convention for narration, and the model
/// is told what it is and where it's running.
@MainActor
enum SystemPrompt {
    struct Context {
        var tools: [ToolCatalog.Definition] = []
        var nativeSearch = false
        var hasMemories = false
        var providerName = ""
        var modelID = ""
        var userFirstName: String?
        var workspaceFiles: [String] = []
        var activeSkillNames: [String] = []
        var memoryCount = 0
        var attachmentNames: [String] = []
    }

    static func compose(_ context: Context) -> String {
        var sections: [String] = []

        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        var environmentLines = [
            "# Environment",
            "Current date and time: \(formatter.string(from: Date())) (\(TimeZone.current.identifier)) — stamped when this request was sent; do not claim you lack the date.",
        ]
        var identity = "You are the model \"\(context.modelID)\""
        if !context.providerName.isEmpty { identity += " served by \(context.providerName)" }
        identity += ", running inside VelaChat, a native macOS chat app"
        if let name = context.userFirstName, !name.isEmpty {
            identity += " used by \(name)"
        }
        identity += "."
        environmentLines.append(identity)
        environmentLines.append("""
        The user sees your tool calls as quiet activity lines woven into \
        your reply (collapsing into a one-line summary when you finish). \
        Before a call, say what you're doing in one short clause at most \
        ("Checking their docs…") — never narrate tool mechanics or tool \
        names. Markdown renders fully; sizeable code or markdown blocks \
        get an "Open in Inspector" affordance with real rendering.
        """)
        if !context.workspaceFiles.isEmpty {
            let listing = context.workspaceFiles.prefix(20).joined(separator: ", ")
            let suffix = context.workspaceFiles.count > 20 ? ", …" : ""
            environmentLines.append("Workspace files already present: \(listing)\(suffix).")
        }
        if !context.attachmentNames.isEmpty {
            environmentLines.append("Attachments in this conversation: \(context.attachmentNames.joined(separator: ", ")).")
        }
        if !context.activeSkillNames.isEmpty {
            environmentLines.append("Active skills (their instructions are above): \(context.activeSkillNames.joined(separator: ", ")).")
        }
        if context.hasMemories {
            environmentLines.append("Persistent memory: \(context.memoryCount) saved fact\(context.memoryCount == 1 ? "" : "s") about the user.")
        }
        sections.append(environmentLines.joined(separator: "\n"))

        if !context.tools.isEmpty {
            var lines = [
                "# Tools",
                "Real, callable tools are attached to this request. Use them — never claim you lack a capability one of them provides, and never fake a call in plain text.",
            ]
            for tool in context.tools {
                lines.append("- \(tool.name): \(tool.summary). \(tool.guidance)")
            }
            if context.nativeSearch {
                lines.append("- (Your provider also performs live web search natively on this request.)")
            }
            lines.append("When a call errors, read the error and retry with corrected input — errors are feedback, not stop signs. If a page fetch fails or is blocked, try at most ~3 alternative pages, then answer from the search snippets you already have, saying briefly which sources were unreachable.")
            if context.tools.contains(where: { $0.name == ToolCatalog.writeFile.name }) {
                lines.append("Files you write with write_file land in this conversation's private workspace; the user can open, read, and edit them in the inspector — writing a real file is often better than pasting a wall of code.")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        sections.append("""
        # Artifacts
        Fenced blocks tagged html, svg, or mermaid render as live previews. \
        Use them when the user asks for a webpage, vector graphic, or \
        diagram — no special syntax beyond the normal language tag.
        """)

        sections.append(AppModel.askUserQuestionInstruction)

        if context.hasMemories {
            sections.append("""
            # Memory
            You maintain the user's persistent memory yourself: save new \
            durable facts with save_memory as you learn them, and correct \
            or remove outdated ones with edit_memory. Never save secrets.
            """)
        }

        return sections.joined(separator: "\n\n")
    }
}
