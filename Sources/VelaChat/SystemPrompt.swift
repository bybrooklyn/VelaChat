import Foundation

/// The app's whole voice to the model, assembled per request from
/// sections that each declare when they apply and how much they matter.
///
/// The user's own custom instructions, memories, and skills are inserted
/// ABOVE this by `AppModel.send` — the user always outranks the app.
///
/// Why a registry rather than one long string: guidance that doesn't
/// apply is worse than absent. Telling a model about shell commands it
/// hasn't been given, or workspace rules with no workspace attached,
/// spends tokens teaching it about capabilities it will then be unable
/// to use — which is exactly how models end up claiming they can do
/// things they can't. Each section names its own precondition, and on a
/// small-context model the lowest-priority ones drop out rather than
/// crowding the actual conversation.
@MainActor
enum SystemPrompt {
    struct Context {
        var tools: [ToolCatalog.Definition] = []
        var nativeSearch = false
        var hasMemories = false
        var providerName = ""
        var providerKind: ProviderKind = .compatible
        var modelID = ""
        var contextWindow: Int?
        var userFirstName: String?
        var workspaceFiles: [String] = []
        var hasAttachedFolder = false
        var activeSkillNames: [String] = []
        var memoryCount = 0
        var attachmentNames: [String] = []

        func hasTool(_ definition: ToolCatalog.Definition) -> Bool {
            tools.contains { $0.name == definition.name }
        }
    }

    /// Lower numbers survive trimming; the environment and the tool
    /// inventory are the two things a model genuinely cannot work without.
    private struct Section {
        let priority: Int
        let body: String

        /// Sections at or below this priority are never dropped for budget.
        static let lastRequiredPriority = 1
    }

    static func compose(_ context: Context) -> String {
        var sections: [Section] = []
        sections.append(Section(priority: 0, body: environment(context)))
        if let tools = toolInventory(context) {
            sections.append(Section(priority: 1, body: tools))
        }
        if let agent = agentGuidance(context) {
            sections.append(Section(priority: 2, body: agent))
        }
        if let workspace = workspaceGuidance(context) {
            sections.append(Section(priority: 3, body: workspace))
        }
        // The fenced ```ask-user convention is the FALLBACK for providers
        // without tool calling. When the real `ask_user` tool is attached,
        // sending this too gives the model two different ways to ask the
        // same question — which is how it ends up doing both, or emitting a
        // fenced block the tool loop never sees.
        if !context.hasTool(ToolCatalog.askUser) {
            sections.append(Section(priority: 4, body: AppModel.askUserQuestionInstruction))
        }
        if context.hasMemories {
            sections.append(Section(priority: 5, body: memoryDuties))
        }
        sections.append(Section(priority: 6, body: artifacts))

        // Token budget: roughly four characters per token, and never more
        // than an eighth of the window spent on our own preamble. Sections
        // drop whole rather than being truncated mid-sentence — half an
        // instruction is worse than none.
        let budgetCharacters = context.contextWindow.map { max(2_000, $0 / 8 * 4) } ?? .max

        // Environment and the tool inventory are mandatory. This file
        // already says they are "the two things a model genuinely cannot
        // work without", and a model that doesn't know which tools it has
        // cannot use them at all — so they are never dropped, and the
        // budget governs only what sits below them.
        let required = sections.filter { $0.priority <= Section.lastRequiredPriority }
        let optional = sections.filter { $0.priority > Section.lastRequiredPriority }

        var kept = required
        var used = required.reduce(0) { $0 + $1.body.count + 2 }
        for section in optional.sorted(by: { $0.priority < $1.priority }) {
            let cost = section.body.count + 2
            // `break`, not `continue`. Skipping a section that doesn't fit
            // and carrying on let a small low-priority section leapfrog a
            // larger high-priority one that had just been dropped — which
            // produced exactly the "random subset" this is supposed to
            // prevent (a squeezed prompt that had lost its tool inventory
            // but still carried the artifacts guidance).
            guard used + cost <= budgetCharacters else { break }
            used += cost
            kept.append(section)
        }
        return kept
            .sorted { $0.priority < $1.priority }
            .map(\.body)
            .joined(separator: "\n\n")
    }

    // MARK: - Sections

    private static func environment(_ context: Context) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        var lines = [
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
        lines.append(identity)
        lines.append("""
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
            lines.append("Workspace files already present: \(listing)\(suffix).")
        }
        if !context.attachmentNames.isEmpty {
            lines.append("Attachments in this conversation: \(context.attachmentNames.joined(separator: ", ")).")
        }
        if !context.activeSkillNames.isEmpty {
            lines.append("Active skills (their instructions are above): \(context.activeSkillNames.joined(separator: ", ")).")
        }
        if context.hasMemories {
            lines.append("Persistent memory: \(context.memoryCount) saved fact\(context.memoryCount == 1 ? "" : "s") about the user.")
        }
        return lines.joined(separator: "\n")
    }

    /// The stance here is deliberately *directive*, not permissive.
    ///
    /// The previous wording ("Use them — never claim you lack a capability
    /// one of them provides") only forbade denying a capability, which a
    /// model satisfies perfectly well by never reaching for a tool at all
    /// and answering from memory instead. In practice that is exactly what
    /// happened: real research only occurred when the user explicitly asked
    /// for it. Permission to use a tool is not the same instruction as
    /// when to use one, so this now names the triggers.
    private static func toolInventory(_ context: Context) -> String? {
        guard !context.tools.isEmpty else { return nil }
        var lines = [
            "# Tools",
            "Real, callable tools are attached to this request. Use them — never claim you lack a capability one of them provides, and never fake a call in plain text.",
            """
            Reach for a tool on your own initiative rather than waiting to \
            be asked. Anything you cannot answer correctly from training \
            alone needs one: current events, prices, availability, hours, \
            versions, release status, "best/latest X", anything dated after \
            your training cutoff, and any specific claim about the user's \
            own files, past conversations, or saved facts. Answering those \
            from memory when a tool was attached is a factual error, not a \
            stylistic choice.
            """,
            """
            Do not ask permission to use a tool, and do not offer to do \
            research as a follow-up — if the work is worth doing, do it in \
            this reply and report what you found. Reserve questions for \
            genuine ambiguity about what the user wants, never for whether \
            you may look something up. Equally, do not perform research \
            theatre: a question that training data answers well needs no \
            tool call.
            """,
        ]
        for tool in context.tools {
            lines.append("- \(tool.name): \(tool.summary). \(tool.guidance)")
        }
        if context.nativeSearch {
            lines.append("- (Your provider also performs live web search natively on this request.)")
        }
        lines.append("When a call errors, read the error and retry with corrected input — errors are feedback, not stop signs. If a page fetch fails or is blocked, try at most ~3 alternative pages, then answer from the search snippets you already have, saying briefly which sources were unreachable.")
        return lines.joined(separator: "\n")
    }

    /// Only when the agent abilities are actually attached. Without this
    /// gate the model gets told how to plan and run commands it doesn't
    /// have, which is how it ends up promising work it can't do.
    private static func agentGuidance(_ context: Context) -> String? {
        var lines: [String] = []
        if context.hasTool(ToolCatalog.updatePlan) {
            lines.append("Plans are for genuinely multi-step work only — never pad a simple task with one. When you do plan: 5-7 short steps, exactly one in_progress at a time, updated as you finish each.")
        }
        if context.hasTool(ToolCatalog.runCommand) {
            lines.append("You can run real shell commands in the workspace. Read-only commands run immediately; anything else asks the user first, so keep commands small, explicit, and easy to approve. Always check the exit code instead of assuming success, and if the user denies a command, adapt rather than retrying it.")
        }
        if context.hasTool(Subagents.definition) {
            lines.append("Subagents are for genuinely parallel, independent work. Each prompt must stand alone — they cannot see this conversation.")
        }
        guard !lines.isEmpty else { return nil }
        return (["# Working autonomously"] + lines).joined(separator: "\n")
    }

    /// Only when file tools exist. The "don't paste the file back" rule
    /// matters most here: without it the model writes a file and then
    /// dumps its entire contents into the reply as well.
    private static func workspaceGuidance(_ context: Context) -> String? {
        guard context.hasTool(ToolCatalog.writeFile) || context.hasTool(ToolCatalog.editFile) else { return nil }
        var lines = ["# Files and code"]
        lines.append("Short, self-contained, one-off code belongs in the chat as a normal code block. Code the user will iterate on, run, or that spans files belongs in a file. If they ask for one or the other explicitly, do that.")
        lines.append("When you write or edit a file, do NOT paste its contents back into the reply — the user sees the file itself in the inspector. Say what you did and why in a sentence.")
        if context.hasTool(ToolCatalog.editFile) {
            lines.append("For an existing file prefer edit_file (exact find/replace) over rewriting it whole, and use search_files to locate code instead of guessing paths.")
        }
        if context.hasAttachedFolder {
            lines.append("This workspace is a real folder of the user's, not a scratch directory — treat their existing files with care and never restructure without being asked.")
        }
        return lines.joined(separator: "\n")
    }

    private static let artifacts = """
    # Artifacts
    Fenced blocks tagged html, svg, or mermaid render as live previews. \
    Use them when the user asks for a webpage, vector graphic, or \
    diagram — no special syntax beyond the normal language tag.
    """

    private static let memoryDuties = """
    # Memory
    You maintain the user's persistent memory yourself: save new durable \
    facts with save_memory as you learn them, and correct or remove \
    outdated ones with edit_memory. Never save secrets.
    """
}
