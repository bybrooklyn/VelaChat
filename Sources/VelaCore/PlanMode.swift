import Foundation

/// Planning mode: a hard constraint on what the model *can* do, not a
/// polite request in the prompt.
///
/// "Plan first, don't change anything yet" as prose is advisory, and
/// advisory is unverifiable — under pressure a model writes the file
/// anyway, and from outside you cannot tell whether it obeyed or merely
/// happened not to try. So planning mode is enforced where the capability
/// actually lives: the tool list assembled per request (`AppModel.send`)
/// and the run_command gate (`AppModel.executeCommand`). While a
/// conversation is planning, the tools that mutate anything are never
/// attached, so there is nothing to disobey.
///
/// What stays attached matters as much as what doesn't. Reading files,
/// searching the workspace, the web and past conversations, asking the
/// user, posting the plan itself, and read-only shell exploration all
/// remain — a plan written without looking at the code is precisely the
/// failure this is meant to prevent.
///
/// One honest limit: MCP tools are not filtered. They are declared by
/// third-party servers, and nothing in their schema says whether a given
/// one writes; withholding them all would silently break read-only MCP
/// servers during planning, and guessing from names would be a
/// constraint that only looks like one. So the guarantee here is exact —
/// VelaChat's own writing tools and non-read-only shell are impossible
/// while planning — and it does not extend to tools somebody else's
/// server provides (which, as `SettingsView` says, already run without
/// per-call confirmation).
public enum PlanMode {
    /// Withheld while planning. Everything here changes state outside the
    /// conversation: the user's files, or their persistent memory.
    ///
    /// `run_command` is deliberately NOT in this list. Detaching it would
    /// take `ls`, `rg`, and `git log` away with it, which is most of how a
    /// plan gets informed; instead the tool stays attached and every
    /// non-read-only command is refused at the gate (`commandRefusal`).
    public static var withheldToolNames: Set<String> {
        [
            ToolCatalog.writeFile.name,
            ToolCatalog.editFile.name,
            ToolCatalog.createDocument.name,
            ToolCatalog.saveMemory.name,
            ToolCatalog.editMemory.name,
        ]
    }

    /// The request's tools, minus the ones planning mode withholds. Same
    /// shape as `Subagents.allowedTools` — a filter over the definitions
    /// that were already assembled, so a tool added elsewhere can only
    /// ever be *kept*, never accidentally granted by this file.
    public static func filter(_ tools: [ToolCatalog.Definition]) -> [ToolCatalog.Definition] {
        let withheld = withheldToolNames
        return tools.filter { !withheld.contains($0.name) }
    }

    /// The tool-result string for a command planning mode won't run, or
    /// nil when the command is read-only and may proceed.
    ///
    /// It reads as an error on purpose: the model has to learn the
    /// constraint from the result it gets back, since it cannot see the
    /// mode from the tool schema.
    public static func commandRefusal(for command: String) -> String? {
        if case .readOnly = CommandRunner.classify(command) { return nil }
        return """
        Error: this conversation is in planning mode, so only read-only commands run. \
        Explore all you like (ls, cat, rg, git status/log/diff), then post the plan with \
        update_plan — the user approves it before anything is built or changed.
        """
    }

    /// Whether a draft looks like work worth planning before starting.
    ///
    /// Deliberately conservative: the offer is made at most once per
    /// conversation, so a false positive costs the user their one chance
    /// to be asked at the right moment. Short questions, quick lookups and
    /// one-line follow-ups never qualify.
    public static func looksSubstantial(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 140 else { return false }
        // Several lines usually means several requirements — a numbered
        // list or a pasted spec, not a question.
        if trimmed.split(whereSeparator: \.isNewline).count >= 4 { return true }
        if trimmed.count >= 400 { return true }
        let lowercased = trimmed.lowercased()
        // Words that name work spanning more than one file or step. Matched
        // as plain substrings, so the noun forms ("the refactor") match too
        // — that's tolerable only because of the length floor above: a
        // one-line question about a refactor never gets this far.
        let verbs = [
            "refactor", "implement", "migrate", "rewrite", "redesign",
            "port ", "build a", "build the", "add support", "set up",
        ]
        return verbs.contains { lowercased.contains($0) }
    }
}
