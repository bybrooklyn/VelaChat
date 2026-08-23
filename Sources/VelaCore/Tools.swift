import Foundation

/// Real tool calling, not the pre-fetch trick the old "web search" used —
/// tool definitions go in the request, the model decides whether to call
/// one, VelaChat executes it locally and feeds the result back, looping
/// until the model has enough to answer for real. The loop lives entirely
/// inside `CompatibleChatClient`'s streaming functions (see
/// `streamChat`/`streamAnthropic` in ChatAPI.swift) — callers just see a
/// normal event stream plus `.toolUse` events for UI transparency, never
/// the raw multi-round exchange.
public enum ToolCatalog {
    public struct Definition {

        public init(name: String, description: String, parametersJSON: String, guidance: String) {
            self.name = name
            self.description = description
            self.parametersJSON = parametersJSON
            self.guidance = guidance
        }
        public let name: String
        /// The "what it does" half of the tool description that goes on the
        /// wire: what the tool actually does, what it returns, and what it
        /// cannot do.
        public let description: String
        /// A JSON Schema `properties` object, hand-built per tool rather
        /// than reflected from Swift types — a tiny hand-written schema is
        /// far less risk than a general schema generator for this scope.
        public let parametersJSON: String
        /// The "how to behave" half: when to reach for the tool, when not
        /// to, and what to do when the result isn't what was expected.
        ///
        /// Kept as its own field so the two halves stay separately
        /// editable, but it ships appended to `description` (see
        /// `wireDescription`) — i.e. inside the tool definition, where the
        /// model reads it as part of the tool. It used to be pasted into
        /// the system prompt instead, as a prose "# Tools" list of every
        /// attached tool, and that list is exactly what the model read back
        /// when asked "what can you do?": a categorized brochure of tool
        /// names. Descriptions belong in the tool definitions, once.
        public let guidance: String

        /// What actually goes on the wire as the tool's description.
        public var wireDescription: String {
            guidance.isEmpty ? description : description + " " + guidance
        }
    }

    /// `ask_user` is the one tool `execute` does not race against
    /// `Limits.toolTimeout`. See the comment there.
    public static func isBoundedByTimeout(_ name: String) -> Bool {
        name != askUser.name
    }

    public static let searchConversations = Definition(
        name: "search_conversations",
        description: "Search the text of the user's earlier conversations in this app. Returns up to 8 excerpts — roughly 80 characters either side of the hit — each labelled with the conversation's title and the role that said it, never a whole transcript. Matching is a plain case-insensitive substring test, not semantic or fuzzy search: a multi-word query only matches that exact phrase.",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"One distinctive literal substring — a name, project, filename, or single keyword. Not a question and not several terms at once: \"Helsinki\", not \"what did we decide about the Helsinki trip\"."}},"required":["query"]}"#,
        guidance: "Reach for this whenever the user points at something outside this conversation (\"like we discussed\", \"the project I mentioned\", a name you don't recognise). Run several narrow searches rather than one broad one, and if a query returns nothing, try a different single word before concluding it was never discussed."
    )

    public static let webSearch = Definition(
        name: "web_search",
        description: "Search the live web and return the top results as title, URL, and a one- or two-line snippet each. This is real, current web access. The snippets are search-engine summaries, not the pages themselves — use fetch_url to read anything you intend to rely on.",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"A keyword-style query as you would type it into a search engine — not a full sentence or question. Include a year or version when recency matters, e.g. \"swift 6 strict concurrency migration 2026\"."}},"required":["query"]}"#,
        guidance: "Use it for anything training data can't answer reliably: current events, prices, availability, hours, versions, release status, scores, weather, \"latest/best X\". Two or three targeted searches from different angles beat one broad one. Cite the URLs you actually used, and never tell the user you cannot browse the web — here, you can."
    )

    public static let fetchURL = Definition(
        name: "fetch_url",
        description: "Fetch one http(s) page and return its readable text with markup, scripts, and styling stripped out, truncated at about 12,000 characters (marked \"[Truncated — page continues.]\" when that happens). Text only: it cannot run JavaScript, sign in, or read images or PDFs, and sites that block automated readers come back as an HTTP 403 or 429 error.",
        parametersJSON: #"{"type":"object","properties":{"url":{"type":"string","description":"The full absolute URL including the scheme, e.g. \"https://example.com/docs/page\". A bare domain without \"https://\" is rejected."}},"required":["url"]}"#,
        guidance: "A search snippet is not evidence — fetch the page before quoting it or resting a claim on it, and summarize what you actually read. When a fetch is blocked, switch sources rather than retrying the same URL; after about three failures, answer from the snippets you already have and say briefly which sources were unreachable."
    )

    // current_datetime was retired: the system prompt's Environment
    // section stamps the live date/time on every request, which is both
    // cheaper and always present. (ActivityKind.datetime remains so old
    // transcripts still render their activity lines.)

    public static let calculator = Definition(
        name: "calculator",
        description: "Evaluate one arithmetic expression exactly and return it as \"expression = result\". Supports + - * / % and ^ (exponentiation, right-associative), parentheses, unary minus, and decimals. Numbers only: no variables, units, currency symbols, percentages, or named functions — write a square root as x^0.5.",
        parametersJSON: #"{"type":"object","properties":{"expression":{"type":"string","description":"The whole expression as one string, e.g. \"(1234.5 * 12) / 7\". Strip currency symbols and units first; thousands separators are ignored."}},"required":["expression"]}"#,
        guidance: "Mental arithmetic on long or precise numbers is where confident wrong answers come from — evaluate it here instead, including the intermediate steps of a multi-step calculation."
    )

    public static let readAttachment = Definition(
        name: "read_attachment",
        description: "Return the complete text of a file the user attached to this conversation. Attachments are truncated when they are inlined into the prompt, so this is the only way to see the rest of a long one. Text-bearing files only; when the name doesn't match, the error lists the filenames that are available.",
        parametersJSON: #"{"type":"object","properties":{"filename":{"type":"string","description":"The attachment's filename as it appears in the conversation, e.g. \"report.md\". Case-insensitive, and a distinctive part of the name is enough."}},"required":["filename"]}"#,
        guidance: "If an attachment looks cut off, or the user asks about a part of it you cannot see, read the whole file here before answering rather than reasoning from the visible fragment."
    )

    /// §9.10 — the agent scratchpad: one plain file per conversation,
    /// agent-only, living on disk so its contents survive context
    /// compaction with no re-injection machinery. Distinct from write_file:
    /// never shown to the user as a deliverable, and append-shaped.
    public static let scratchpad = Definition(
        name: "scratchpad",
        description: "Read or append to your private scratchpad for this conversation — persistent notes that survive even when older parts of this conversation leave the context window. One action per call: \"read\" returns everything written so far; \"append\" adds text under an optional heading.",
        parametersJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["read","append"],"description":"\"read\" returns the full pad; \"append\" adds text at the end."},"text":{"type":"string","description":"For append: what to add. Keep it dense — findings, decisions, open questions, next steps."},"heading":{"type":"string","description":"Optional heading appended before the text, e.g. 'Findings 1-10'."}},"required":["action"]}"#,
        guidance: "Write down anything you will need later: intermediate results while processing a long list, candidate answers before choosing, where you left off in a multi-step task. Read it back after any context compaction notice rather than working from memory."
    )

    // MARK: - Git / PR tools (§9.7)

    public static let gitStatus = Definition(
        name: "get_git_status",
        description: "Structured working-tree state of this conversation's attached folder as a git repository: current branch, ahead/behind counts, staged, unstaged, and untracked files. Read-only.",
        parametersJSON: #"{"type":"object","properties":{}}"#,
        guidance: "Check before proposing changes so commits and diffs reference reality. Requires an attached folder that is a real repository."
    )
    public static let gitDiff = Definition(
        name: "git_diff",
        description: "Unified diff of uncommitted changes in the attached repository (staged and unstaged combined, capped in size). Read-only.",
        parametersJSON: #"{"type":"object","properties":{"staged":{"type":"boolean","description":"true = only what is staged; omit for everything uncommitted."}}}"#,
        guidance: "Read a diff before writing commit messages or claiming what changed — never reconstruct edits from memory."
    )
    public static let gitLog = Definition(
        name: "git_log",
        description: "Recent commit history (hash + subject), newest first. Read-only.",
        parametersJSON: #"{"type":"object","properties":{"count":{"type":"integer","description":"How many commits (default 20, max 100)."}}}"#,
        guidance: "Use to learn conventions for messages or find where work left off."
    )
    public static let gitCommit = Definition(
        name: "git_commit",
        description: "Commit STAGED changes with the given message in the attached repository. Does not stage anything itself.",
        parametersJSON: #"{"type":"object","properties":{"message":{"type":"string","description":"The full commit message."}},"required":["message"]}"#,
        guidance: "Stage first with get_git_status + the user's confirmation flow, read git_diff before writing the message, and follow the repository's own message style from git_log."
    )
    public static let createPullRequest = Definition(
        name: "create_pr",
        description: "Open a pull request on GitHub via the gh CLI: pushes the current branch if needed, then creates the PR. Always asks for explicit approval — publishing to a shared repository is not auto-allowed.",
        parametersJSON: #"{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string","description":"Full PR description in markdown."},"base":{"type":"string","description":"Target branch; defaults to the repo's default."}},"required":["title","body"]}"#,
        guidance: "Only after the user has seen and approved the diff. If gh isn't installed the tool says so instead of failing opaquely."
    )

    public static let publishGist = Definition(
        name: "publish_gist",
        description: "Publish one or more workspace files as a GitHub gist via the gh CLI. Secret by default (unlisted, not private — anyone with the link can read it). Every file is scanned for API keys and tokens first; a hit blocks publishing until you redact it. Always asks before publishing.",
        parametersJSON: #"{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"},"description":"Paths relative to the workspace root."},"description":{"type":"string","description":"Short gist description."},"public":{"type":"boolean","description":"true = publicly listed. Default false (secret)."}},"required":["files"]}"#,
        guidance: "For sharing a result the user asked to publish. Never include credentials; if the scan reports hits, tell the user which file and rule matched rather than trying to sneak past."
    )

    /// A real, private, per-conversation folder on disk — not a general
    /// filesystem. See `SandboxManager` for the actual safety boundary
    /// (path validation, not process sandboxing) and why a shell-execution
    /// tool isn't offered alongside these.
    public static let writeFile = Definition(
        name: "write_file",
        description: "Create or overwrite a UTF-8 text file in this conversation's workspace — a real folder on disk, private to this conversation, which the user can open in Finder. Missing parent directories are created. Writing an existing file replaces it entirely. Returns the number of bytes written.",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the workspace root, e.g. \"notes.txt\" or \"src/main.py\". Absolute paths and \"..\" are rejected."},"content":{"type":"string","description":"The complete new contents of the file — the whole thing, never a fragment or a diff."}},"required":["path","content"]}"#,
        guidance: "Right for drafts, code, and notes the user will keep or run; for a change to an existing file use edit_file instead of rewriting it whole. Never paste the file's contents back into your reply afterwards — the user can already see the file."
    )
    public static let readFile = Definition(
        name: "read_file",
        description: "Return the full UTF-8 text of one file in this conversation's workspace folder. Errors if the file doesn't exist yet or isn't text.",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the workspace root, exactly as list_workspace_files or search_files reported it"}},"required":["path"]}"#,
        guidance: "Read a file before editing it: edit_file needs its exact existing text, whitespace included. If you aren't sure what exists, call list_workspace_files rather than guessing a filename."
    )
    public static let listWorkspaceFiles = Definition(
        name: "list_workspace_files",
        description: "List the entries at the top level of this conversation's workspace folder, sorted, one name per line. Says so plainly when the folder is empty.",
        parametersJSON: #"{"type":"object","properties":{}}"#,
        guidance: "It costs nothing — call it rather than guessing filenames or assuming the workspace is empty. Use search_files when you need to look inside subfolders or file contents."
    )

    public static let editFile = Definition(
        name: "edit_file",
        description: "Replace an exact substring of a workspace file with new text — the surgical way to change a file instead of rewriting it whole. old_string is matched literally (no regular expressions, no whitespace normalisation) and must occur exactly once unless replace_all is true. Returns how many occurrences were replaced.",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the workspace root"},"old_string":{"type":"string","description":"The exact text to find, copied verbatim out of the file including indentation and line breaks. Include enough surrounding lines to make it unique."},"new_string":{"type":"string","description":"The exact text to put in its place. An empty string deletes the match."},"replace_all":{"type":"boolean","description":"Replace every occurrence instead of requiring a unique match (default false)"}},"required":["path","old_string","new_string"]}"#,
        guidance: "Prefer this over write_file for any change to a file that already exists. If the result says old_string wasn't found, re-read the file rather than guessing again — what you remembered isn't what's on disk. If it says the match wasn't unique, add surrounding lines until it is."
    )
    public static let searchFiles = Definition(
        name: "search_files",
        description: "Find files in this conversation's workspace by filename pattern, by content, or both. glob filters filenames (\"*\" and \"?\" wildcards, matched against the workspace-relative path and against the bare filename); query is a case-insensitive regular expression matched line by line against file contents. With query the result is \"path:line: text\" per match, with glob alone it is a list of paths. Capped at 100 results, which it says when it hits.",
        parametersJSON: #"{"type":"object","properties":{"glob":{"type":"string","description":"Filename pattern, e.g. \"*.md\" or \"src/*.ts\". Omit to consider every file."},"query":{"type":"string","description":"Regular expression matched against file contents, e.g. \"func handle[A-Z]\". Omit to list files by name only."}}}"#,
        guidance: "Use it to locate code in a folder you didn't create instead of guessing paths, and read the file before editing it. If a content search returns the 100-result cap, narrow it with glob rather than working from a truncated list."
    )
    public static let runCommand = Definition(
        name: "run_command",
        description: "Run one shell command (via zsh) with this conversation's workspace as the working directory, and get back its combined stdout and stderr prefixed by the exit status. Read-only commands run immediately; anything that could modify the system or reach the network pauses for the user's explicit approval, and they may edit or deny it. Each call is a fresh shell, so `cd` and exported variables do not carry over between calls. Output is capped at 20 KB.",
        parametersJSON: #"{"type":"object","properties":{"command":{"type":"string","description":"The exact command line to run, e.g. \"git status --short\". One command per call; chain with && only when the steps are genuinely inseparable."}},"required":["command"]}"#,
        guidance: "Keep commands small, explicit, and approvable at a glance — a wall of chained shell is a command the user will deny. Prefer rg over grep. Never assume a command worked: read the exit status in the result. If the user denies one, read their reason and adapt instead of reissuing it."
    )
    /// The real-tool half of asking the user a question. The fenced
    /// ```ask-user block still exists for providers without tool calling
    /// (see `SystemPrompt.askUserQuestionInstruction`), but it can only end the
    /// turn and wait for a fresh user message. This pauses the generation
    /// instead, so the model can ask and then keep working in the same
    /// reply. Only one of the two is ever advertised at a time.
    public static let askUser = Definition(
        name: "ask_user",
        description: "Put one to four multiple-choice questions to the user on an interactive card and wait for the answer. Everything you have written so far stays on screen, generation pauses, and their selections — plus any free-text note — come back as this tool's result, so you continue in the same reply. A human is answering, so there is no time limit; if they dismiss the card you are told so, and should continue on your best judgement.",
        parametersJSON: #"{"type":"object","properties":{"questions":{"type":"array","description":"1-4 questions, each with 2-4 mutually distinct options","items":{"type":"object","properties":{"header":{"type":"string","description":"Very short chip label, max ~12 characters (e.g. \"Scope\", \"Auth\")"},"question":{"type":"string","description":"The full question, as one sentence"},"multiSelect":{"type":"boolean","description":"true only when several options genuinely combine; default false"},"options":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string","description":"Short option name, a few words"},"description":{"type":"string","description":"One sentence saying what choosing this means"},"recommended":{"type":"boolean","description":"At most ONE per question, and list that option first"}},"required":["label","description"]}}},"required":["question","options"]}},"allowNotes":{"type":"boolean","description":"Let the user attach a free-text note alongside their selections"}},"required":["questions"]}"#,
        guidance: "Write first, then ask. Give the user a short, genuinely useful reply — what you already know, or the part of the work you can do without the answer — finish the thought, and put the question at the end of it; calling this mid-sentence leaves them staring at half a paragraph behind a question card. Batch every related decision into ONE call rather than asking again next reply. Reserve it for choices that actually change what you do next: never to ask permission to use a tool, and never for something a tool or the conversation itself already answers."
    )

    public static let updatePlan = Definition(
        name: "update_plan",
        description: "Post or replace the visible step-by-step plan shown to the user for this reply. Each call sends the whole plan, not a delta: repeat every step with its current status. Steps are short phrases (5-7 words) with a status of pending, in_progress, or completed, and exactly one step should be in_progress until the work is done.",
        parametersJSON: #"{"type":"object","properties":{"steps":{"type":"array","description":"The complete plan in order — every step, every time","items":{"type":"object","properties":{"step":{"type":"string","description":"Short imperative phrase, 5-7 words"},"status":{"type":"string","enum":["pending","in_progress","completed"],"description":"pending, in_progress (exactly one), or completed"}},"required":["step","status"]}}},"required":["steps"]}"#,
        guidance: "Only for genuinely multi-step work — padding a simple task with a plan is noise. Call it again as each step finishes so the user can follow along, rather than posting it once and going quiet."
    )

    public static let getSchedule = Definition(
        name: "get_schedule",
        description: "Read the user's upcoming calendar events and open (incomplete) reminders from the system Calendar and Reminders apps. Read-only. Returns events with their start time, end time, and calendar name, then reminders with their due dates. The first call may raise a one-time macOS permission prompt, and a denial comes back as an explicit error.",
        parametersJSON: #"{"type":"object","properties":{"days":{"type":"integer","description":"How many days ahead to look, 1-7 (default 7). Values outside that range are clamped."}}}"#,
        guidance: "Use it for anything about the user's schedule, availability, or todos rather than asking them to tell you what's on their calendar. If access was denied, relay that plainly instead of guessing or pretending the calendar is empty."
    )
    public static let createScheduleItem = Definition(
        name: "create_schedule_item",
        description: "Create a reminder or a calendar event in the user's own Reminders/Calendar app, in their default list or calendar. Events need a start time; reminders may have one as an optional due date. Confirms back what was created, with the resolved date and the list or calendar it landed in.",
        parametersJSON: #"{"type":"object","properties":{"kind":{"type":"string","enum":["reminder","event"],"description":"\"reminder\" for a todo (due date optional) or \"event\" for a calendar entry (start time required)"},"title":{"type":"string","description":"The title as it should read in Reminders or Calendar"},"start":{"type":"string","description":"Local wall-clock time in ISO 8601, e.g. \"2026-08-20T15:00:00\" — an already-resolved absolute timestamp, never a relative phrase"},"duration_minutes":{"type":"integer","description":"Event length in minutes (default 60); ignored for reminders"},"notes":{"type":"string","description":"Optional body text stored with the item"}},"required":["kind","title"]}"#,
        guidance: "Resolve relative times (\"tomorrow at 3\", \"next Friday\") against the current date in your Environment section yourself and pass the concrete timestamp — the tool does no relative-date parsing. Repeat the time back to the user so they can catch a misreading."
    )
    public static let systemStatus = Definition(
        name: "system_status",
        description: "Read this Mac's current state in one call: battery percentage and whether it's charging, free and total disk space, installed memory, uptime, macOS version, and which media apps are currently running. A snapshot at call time, not a history.",
        parametersJSON: #"{"type":"object","properties":{}}"#,
        guidance: "Use it when the user asks about their machine (\"is my battery ok\", \"am I low on space\", \"what's playing\") instead of guessing or asking them to go and check."
    )
    public static let analyzeImage = Definition(
        name: "analyze_image",
        description: "Run on-device Vision analysis over an image attached to this conversation: returns the image's pixel dimensions, the text found in it by OCR, and a short list of scene labels. It is not a visual description — it cannot tell you layout, colours, style, or who is in a photo.",
        parametersJSON: #"{"type":"object","properties":{"filename":{"type":"string","description":"The image attachment's filename as it appears in the conversation; the error lists the available images if it doesn't match"}},"required":["filename"]}"#,
        guidance: "Use it when you cannot see images yourself but the user attached one — screenshots of text and error messages are what it's best at. If they ask for something OCR and scene labels can't support, say that plainly rather than inventing a description."
    )
    public static let readClipboard = Definition(
        name: "read_clipboard",
        description: "Read what is currently on the user's clipboard — text, or the names of copied files. Reads only at the moment of the call; it cannot see clipboard history or watch for changes.",
        parametersJSON: #"{"type":"object","properties":{}}"#,
        guidance: "\"What do you think of this?\" right after the user copied something usually means the clipboard — read it instead of asking them to paste it in."
    )

    public static let saveMemory = Definition(
        name: "save_memory",
        description: "Save one durable fact ABOUT THE USER to persistent memory, available in every future conversation. Durable means it will still be true next month: a stable preference, part of their identity, or a standing constraint on how they want to be worked with. One short standalone sentence per call — standalone because it will be read without this conversation around it — phrased as a third-person statement starting with \"User\", and filed under a topic used for grouping. Reuse an existing topic from search_memory when one fits rather than inventing a near-duplicate. Rejected on the way in: task state (what is being worked on today), one-off details, anything already said in this conversation, anything you produced yourself, and anything secret.",
        parametersJSON: #"{"type":"object","properties":{"content":{"type":"string","description":"The durable fact as one short third-person sentence, e.g. \"User prefers Swift over Objective-C for new work\" or \"User works mainly in the Europe/Oslo timezone\" — not \"User is debugging the recall query\", not \"they said yes to that\", not a summary of what you just explained"},"topic":{"type":"string","description":"Short grouping topic, e.g. a project name, \"Preferences\", or \"Work\""}},"required":["content","topic"]}"#,
        guidance: "Most turns should save nothing. Save only when the user tells you something lasting about themselves — a preference, how they work, a constraint — and then do it without asking permission. Do not save what is happening in this conversation, what you just wrote, or anything secret. Search first: a near-identical fact is folded into the existing one instead of stored twice."
    )
    public static let searchMemory = Definition(
        name: "search_memory",
        description: "Search persistent memory for stored facts. Returns each match as \"[id] (topic) content\" — the id is what edit_memory needs. Matching is a case-insensitive substring test over content and topic; an empty query returns the 12 most recent memories instead.",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"A single word or short phrase to look for, matched literally. Pass an empty string to see the most recent memories."}},"required":["query"]}"#,
        guidance: "The prompt only carries the memories that looked relevant up front, so search here before telling the user you don't know something about them. Search before saving, too — it's how you find the right existing topic and avoid a duplicate."
    )
    public static let editMemory = Definition(
        name: "edit_memory",
        description: "Update or delete one stored memory, identified by the id that search_memory returns. \"update\" replaces the content and/or topic; \"delete\" removes the memory permanently.",
        parametersJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"The memory's id exactly as search_memory printed it in square brackets"},"action":{"type":"string","enum":["update","delete"],"description":"\"update\" to rewrite it, \"delete\" to remove it"},"content":{"type":"string","description":"Replacement text (update only); omit to keep the existing content"},"topic":{"type":"string","description":"Replacement topic (update only); omit to keep the existing topic"}},"required":["id","action"]}"#,
        guidance: "Keep memory truthful: when the user corrects something you had saved, look it up and update it rather than saving a contradicting second copy. Delete what has simply stopped being true."
    )

    /// What a tool call actually needs at execution time — read-only
    /// snapshots, not a live reference to `AppModel` (this runs from
    /// `CompatibleChatClient`, which has no knowledge of `AppModel`).
    public struct ExecutionContext: Sendable {

        public init(
            conversationSummaries: [ConversationSearchSummary],
            searchEndpoint: String,
            workspaceDirectory: URL
        ) {
            self.conversationSummaries = conversationSummaries
            self.searchEndpoint = searchEndpoint
            self.workspaceDirectory = workspaceDirectory
        }
        public let conversationSummaries: [ConversationSearchSummary]
        public let searchEndpoint: String
        public let workspaceDirectory: URL
        /// Full text of the conversation's text-bearing attachments, keyed
        /// by filename — what `read_attachment` serves.
        public var attachmentTexts: [String: String] = [:]
        /// The memory tools' window into `AppModel.memories` — a read
        /// snapshot plus a MainActor-hopping mutator.
        public var memory: MemoryAccess? = nil
        /// System capabilities, injected as MainActor-hopping closures so
        /// EventKit/NSPasteboard stay out of this Sendable context. nil =
        /// disabled in Settings.
        public var schedule: (@Sendable (Int) async -> String)? = nil
        /// (kind, title, startISO, durationMinutes, notes) → result.
        public var createScheduleItem: (@Sendable (String, String, String?, Int?, String?) async -> String)? = nil
        public var clipboard: (@Sendable () async -> String)? = nil
        public var systemStatus: (@Sendable () async -> String)? = nil
        /// Image attachments by filename, for on-device analysis.
        public var imageAttachments: [String: Data] = [:]
        public var analyzeImage: (@Sendable (Data, String) async -> String)? = nil
        /// Routes mcp_-prefixed tool names to the MCP manager.
        public var mcpCall: (@Sendable (String, String) async -> String)? = nil
        /// True when the workspace is a user-ATTACHED project folder rather
        /// than the app's own sandbox: file writes then require §3
        /// confirmation (reads stay free). The sandbox keeps silent writes.
        public var requiresWriteApproval = false
        /// Ask the host to approve one write; `true` proceeds. Consulted
        /// only when `requiresWriteApproval` is set.
        public var approveWrite: (@Sendable (_ relativePath: String) async -> Bool)? = nil
        /// The §9.7 git tools' approval channel for mutating operations
        /// (commit/push/PR): `true` proceeds. The host decides tiering via
        /// the classifier; sensitive ops must always ask.
        public var approveGitWrite: (@Sendable (_ summary: String, _ isSensitive: Bool) async -> Bool)? = nil
        /// The Claude bridge's permission channel: claude asks to use one
        /// of ITS tools; `true` writes an allow frame, `false` a deny (with
        /// a mandatory reason). nil = every request auto-denies.
        public var claudePermission: (@Sendable (_ toolName: String, _ inputSummary: String, _ input: JSONValue) async -> Bool)? = nil
        /// run_command approval + execution, injected only when the agent
        /// abilities are enabled. Returns the command's combined output (or
        /// an "Error:"/denied message). nil = the tool is disabled.
        public var runCommand: (@Sendable (String) async -> String)? = nil
        /// update_plan sink — hands the parsed steps to the UI layer.
        public var updatePlan: (@Sendable ([PlanStep]) async -> String)? = nil
        /// ask_user gate — presents the question card and suspends until the
        /// user answers. Takes the raw arguments JSON so the payload shape
        /// stays defined in exactly one place (`AskUserQuestionPayload`).
        /// nil = the model has no tool-calling, so the fenced block is in
        /// play instead.
        public var askUser: (@Sendable (String) async -> String)? = nil
        /// spawn_agents runner (name, prompt) pairs → combined result.
        public var spawnAgents: (@Sendable ([(name: String, prompt: String)]) async -> String)? = nil
    }

    public struct PlanStep: Sendable, Equatable, Codable {
        public var step: String
        public var status: String  // pending | in_progress | completed
    }

    public struct MemorySnapshot: Sendable {

        public init(id: UUID, content: String, topic: String?) {
            self.id = id
            self.content = content
            self.topic = topic
        }
        public let id: UUID
        public let content: String
        public let topic: String?
    }

    public enum MemoryMutation: Sendable {
        case save(content: String, topic: String?)
        case update(id: UUID, content: String?, topic: String?)
        case delete(id: UUID)
    }

    public struct MemoryAccess: Sendable {

        public init(snapshot: [MemorySnapshot], mutate: @escaping @Sendable (MemoryMutation) async -> String) {
            self.snapshot = snapshot
            self.mutate = mutate
        }
        public let snapshot: [MemorySnapshot]
        public let mutate: @Sendable (MemoryMutation) async -> String
    }

    /// The minimal slice of a conversation `search_conversations` needs —
    /// built once per request in `AppModel`, not a live `Conversation`
    /// reference (which is `@MainActor`-bound and not `Sendable`).
    public struct ConversationSearchSummary: Sendable {

        public init(title: String, updatedAt: Date, messages: [(role: String, content: String)]) {
            self.title = title
            self.updatedAt = updatedAt
            self.messages = messages
        }
        public let title: String
        public let updatedAt: Date
        public let messages: [(role: String, content: String)]
    }

    /// A short, human-readable stand-in for a tool call's arguments, for
    /// the `ToolUseDisclosure` card's title — "query" for search tools,
    /// "path" for file tools, the raw JSON as a last resort.
    public static func displayArgument(from argumentsJSON: String) -> String {
        guard let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] else {
            return argumentsJSON
        }
        return (arguments["query"] as? String)
            ?? (arguments["path"] as? String)
            ?? (arguments["url"] as? String)
            ?? (arguments["expression"] as? String)
            ?? (arguments["filename"] as? String)
            ?? ""
    }

    /// Outer wrapper: repairs malformed argument JSON where possible and
    /// bounds every tool at 120s — one hung tool must not wedge the whole
    /// reply. ("Error" prefix remains load-bearing for activity tinting.)
    ///
    /// `ask_user` is the single exception (`isBoundedByTimeout`), because
    /// what it is waiting for is a *person* reading a card and picking
    /// answers to up to four questions. Two minutes is a perfectly normal
    /// amount of time for that, and the machine timeout was firing on real
    /// users: the card would still be on screen when the model was handed
    /// "Error: the ask_user tool timed out after 120 seconds" and carried
    /// on without the answer it had just asked for. A stuck ask_user is
    /// also the one case where a bound isn't needed for safety — the user
    /// can always press Stop, and `AppModel+Generation.stopGeneration`
    /// resolves `pendingQuestion` with `nil` *before* cancelling the task
    /// precisely so the continuation can never be stranded.
    public static func execute(name: String, argumentsJSON: String, context: ExecutionContext) async -> String {
        guard isBoundedByTimeout(name) else {
            return await executeInner(name: name, argumentsJSON: argumentsJSON, context: context)
        }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await executeInner(name: name, argumentsJSON: argumentsJSON, context: context)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Limits.toolTimeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? "Error: the \(name) tool timed out after \(Int(Limits.toolTimeout)) seconds."
        }
    }

    /// Models sometimes emit almost-JSON arguments (trailing commas,
    /// smart quotes, prose around the object). Salvage the object rather
    /// than failing the call outright.
    public static func parseArguments(_ argumentsJSON: String) -> [String: Any]? {
        if let parsed = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] {
            return parsed
        }
        var repaired = argumentsJSON
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        // Trailing commas before a closing brace/bracket.
        repaired = repaired.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        if let parsed = (try? JSONSerialization.jsonObject(with: Data(repaired.utf8))) as? [String: Any] {
            return parsed
        }
        // Extract the first balanced {...} span from surrounding prose.
        guard let start = repaired.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var previous: Character = " "
        for index in repaired[start...].indices {
            let character = repaired[index]
            if character == "\"" && previous != "\\" { inString.toggle() }
            if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(repaired[start...index])
                        return (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) as? [String: Any]
                    }
                }
            }
            previous = character
        }
        return nil
    }

    private static func executeInner(name: String, argumentsJSON: String, context: ExecutionContext) async -> String {
        let arguments = parseArguments(argumentsJSON)

        switch name {
        case searchConversations.name:
            guard let query = arguments?["query"] as? String, !query.isEmpty else { return "Error: no query provided." }
            return searchConversationsResult(query: query, context: context)
        case webSearch.name:
            guard let query = arguments?["query"] as? String, !query.isEmpty else { return "Error: no query provided." }
            return await webSearchResult(query: query, context: context)
        case writeFile.name:
            guard let path = arguments?["path"] as? String, let content = arguments?["content"] as? String else {
                return "Error: both \"path\" and \"content\" are required."
            }
            return await writeFileResult(path: path, content: content, context: context)
        case editFile.name:
            guard let path = arguments?["path"] as? String,
                  let oldString = arguments?["old_string"] as? String,
                  let newString = arguments?["new_string"] as? String else {
                return "Error: \"path\", \"old_string\", and \"new_string\" are required."
            }
            return await editFileResult(path: path, oldString: oldString, newString: newString, replaceAll: arguments?["replace_all"] as? Bool ?? false, context: context)
        case searchFiles.name:
            return searchFilesResult(glob: arguments?["glob"] as? String, query: arguments?["query"] as? String, context: context)
        case runCommand.name:
            guard let command = arguments?["command"] as? String, !command.isEmpty else { return "Error: \"command\" is required." }
            guard let runner = context.runCommand else { return "Error: running commands is disabled. The user can enable it in Settings → Agent abilities." }
            return await runner(command)
        case askUser.name:
            guard let asker = context.askUser else { return "Error: asking the user isn't available on this provider." }
            // The raw arguments JSON is forwarded untouched: it already IS
            // the payload shape, so decoding it here would mean a second
            // definition of the same structure drifting from the first.
            return await asker(argumentsJSON)
        case Subagents.definition.name:
            guard let rawTasks = arguments?["tasks"] as? [[String: Any]], !rawTasks.isEmpty else {
                return "Error: \"tasks\" is required and must contain at least one task."
            }
            let tasks = rawTasks.compactMap { entry -> (name: String, prompt: String)? in
                guard let prompt = entry["prompt"] as? String, !prompt.isEmpty else { return nil }
                return (name: (entry["name"] as? String) ?? "", prompt: prompt)
            }
            guard !tasks.isEmpty else { return "Error: every task needs a non-empty \"prompt\"." }
            guard let runner = context.spawnAgents else { return "Error: subagents are disabled. The user can enable them in Settings → Agent abilities." }
            return await runner(tasks)
        case updatePlan.name:
            guard let rawSteps = arguments?["steps"] as? [[String: Any]] else { return "Error: \"steps\" is required." }
            let steps = rawSteps.compactMap { entry -> PlanStep? in
                guard let step = entry["step"] as? String, let status = entry["status"] as? String else { return nil }
                return PlanStep(step: step, status: status)
            }
            guard !steps.isEmpty else { return "Error: no valid steps provided." }
            guard let sink = context.updatePlan else { return "Error: planning is unavailable." }
            return await sink(steps)
        case gitStatus.name:
            return await GitToolExecutor.status(context: context)
        case gitDiff.name:
            return await GitToolExecutor.diff(stagedOnly: arguments?["staged"] as? Bool ?? false, context: context)
        case gitLog.name:
            let requested = arguments?["count"] as? Int ?? Int(arguments?["count"] as? Double ?? 20)
            return await GitToolExecutor.log(count: requested, context: context)
        case gitCommit.name:
            guard let message = arguments?["message"] as? String, !message.isEmpty else { return "Error: \"message\" is required." }
            return await GitToolExecutor.commit(message: message, context: context)
        case createPullRequest.name:
            guard let title = arguments?["title"] as? String, !title.isEmpty,
                  let body = arguments?["body"] as? String else {
                return "Error: \"title\" and \"body\" are required."
            }
            let base = arguments?["base"] as? String
            return await GitToolExecutor.pullRequest(title: title, body: body, base: base, context: context)
        case publishGist.name:
            guard let files = arguments?["files"] as? [String], !files.isEmpty else {
                return "Error: \"files\" must list at least one workspace path."
            }
            let isPublic = arguments?["public"] as? Bool ?? false
            let gistDescription = arguments?["description"] as? String ?? ""
            return await GitToolExecutor.gist(
                files: files,
                gistDescription: gistDescription,
                isPublic: isPublic,
                context: context
            )
        case readFile.name:
            guard let path = arguments?["path"] as? String else { return "Error: \"path\" is required." }
            return readFileResult(path: path, context: context)
        case scratchpad.name:
            let action = arguments?["action"] as? String ?? ""
            return scratchpadResult(action: action, text: arguments?["text"] as? String ?? "", heading: arguments?["heading"] as? String, context: context)
        case listWorkspaceFiles.name:
            return listWorkspaceFilesResult(context: context)
        case fetchURL.name:
            guard let urlString = arguments?["url"] as? String, !urlString.isEmpty else { return "Error: \"url\" is required." }
            return await fetchURLResult(urlString: urlString)
        case calculator.name:
            guard let expression = arguments?["expression"] as? String, !expression.isEmpty else { return "Error: \"expression\" is required." }
            return calculatorResult(expression: expression)
        case readAttachment.name:
            guard let filename = arguments?["filename"] as? String, !filename.isEmpty else { return "Error: \"filename\" is required." }
            return readAttachmentResult(filename: filename, context: context)
        case getSchedule.name:
            guard let schedule = context.schedule else { return "Error: the schedule tool is disabled in Settings." }
            let days = (arguments?["days"] as? Int) ?? Int(arguments?["days"] as? Double ?? 7)
            return await schedule(days)
        case createScheduleItem.name:
            guard let create = context.createScheduleItem else { return "Error: the schedule tool is disabled in Settings." }
            guard let kind = arguments?["kind"] as? String, let title = arguments?["title"] as? String else {
                return "Error: \"kind\" and \"title\" are required."
            }
            let duration = (arguments?["duration_minutes"] as? Int) ?? (arguments?["duration_minutes"] as? Double).map(Int.init)
            return await create(kind, title, arguments?["start"] as? String, duration, arguments?["notes"] as? String)
        case systemStatus.name:
            guard let status = context.systemStatus else { return "Error: the system status tool is disabled in Settings." }
            return await status()
        case analyzeImage.name:
            guard let analyze = context.analyzeImage else { return "Error: image analysis is unavailable." }
            guard let filename = arguments?["filename"] as? String else { return "Error: \"filename\" is required." }
            guard let data = context.imageAttachments[filename] else {
                let available = context.imageAttachments.keys.sorted().joined(separator: ", ")
                return available.isEmpty
                    ? "Error: this conversation has no image attachments."
                    : "Error: no image named \"\(filename)\". Available: \(available)."
            }
            return await analyze(data, filename)
        case readClipboard.name:
            guard let clipboard = context.clipboard else { return "Error: the clipboard tool is disabled in Settings." }
            return await clipboard()
        case saveMemory.name:
            guard let memory = context.memory else { return "Error: memory is unavailable." }
            guard let content = arguments?["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: \"content\" is required."
            }
            return await memory.mutate(.save(content: content, topic: arguments?["topic"] as? String))
        case searchMemory.name:
            guard let memory = context.memory else { return "Error: memory is unavailable." }
            return searchMemoryResult(query: arguments?["query"] as? String ?? "", memory: memory)
        case editMemory.name:
            guard let memory = context.memory else { return "Error: memory is unavailable." }
            guard let idString = arguments?["id"] as? String, let id = UUID(uuidString: idString) else {
                return "Error: a valid \"id\" from search_memory is required."
            }
            switch arguments?["action"] as? String {
            case "delete":
                return await memory.mutate(.delete(id: id))
            case "update":
                return await memory.mutate(.update(id: id, content: arguments?["content"] as? String, topic: arguments?["topic"] as? String))
            default:
                return "Error: \"action\" must be \"update\" or \"delete\"."
            }
        default:
            if name.hasPrefix("mcp_"), let mcpCall = context.mcpCall {
                return await mcpCall(name, argumentsJSON)
            }
            return "Error: unknown tool \"\(name)\"."
        }
    }

    private static func searchMemoryResult(query: String, memory: MemoryAccess) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches: [MemorySnapshot]
        if trimmed.isEmpty {
            matches = Array(memory.snapshot.suffix(12).reversed())
        } else {
            matches = memory.snapshot.filter {
                $0.content.lowercased().contains(trimmed) || ($0.topic?.lowercased().contains(trimmed) ?? false)
            }
        }
        guard !matches.isEmpty else {
            return memory.snapshot.isEmpty
                ? "Memory is empty — nothing has been saved yet."
                : "No stored memories match \"\(query)\"."
        }
        return matches
            .map { "[\($0.id.uuidString)] (\($0.topic ?? "General")) \($0.content)" }
            .joined(separator: "\n")
    }

    private static func readAttachmentResult(filename: String, context: ExecutionContext) -> String {
        if let exact = context.attachmentTexts[filename] { return exact }
        // Tolerate case differences and partial names — the model is typing
        // a filename it saw rendered, not a key it was handed.
        let lowered = filename.lowercased()
        if let match = context.attachmentTexts.first(where: { $0.key.lowercased() == lowered })
            ?? context.attachmentTexts.first(where: { $0.key.lowercased().contains(lowered) }) {
            return match.value
        }
        let available = context.attachmentTexts.keys.sorted().joined(separator: ", ")
        return available.isEmpty
            ? "Error: this conversation has no readable text attachments."
            : "Error: no attachment named \"\(filename)\". Available: \(available)"
    }

    private static func fetchURLResult(urlString: String) async -> String {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "Error: \"\(urlString)\" is not a valid http(s) URL."
        }
        var request = URLRequest(url: url)
        // `probeTimeout` is documented as "cheap probes whose failure is
        // never fatal" (quota headers, warm-up) — 15s. Reading a real page
        // is the opposite: its failure is exactly what the user notices, and
        // `toolTimeout`'s own comment already says it exists "without
        // cutting off slow-but-real work like a large fetch". Big pages
        // behind a slow CDN were being cut off at 15s and reported as
        // failures.
        request.timeoutInterval = Limits.toolTimeout
        // Browser-shaped headers: many sites 403 anything that doesn't
        // look like a real browser. Redirects follow by default.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                let hint = (http.statusCode == 403 || http.statusCode == 429)
                    ? " This site blocks automated readers — try a different source instead of retrying it."
                    : ""
                return "Error: \(url.host ?? urlString) returned HTTP \(http.statusCode) (\(reason)).\(hint)"
            }
            guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return "Error: the page is not text."
            }
            let text = Self.htmlToText(raw)
            let capped = text.count > 12_000 ? String(text.prefix(12_000)) + "\n\n[Truncated — page continues.]" : text
            return capped.isEmpty ? "The page had no readable text." : capped
        } catch {
            return "Error fetching \(urlString): \(error.localizedDescription)"
        }
    }

    /// Good-enough HTML→text: drops script/style/head blocks, turns
    /// block-level tags into newlines, strips the rest, decodes common
    /// entities, collapses blank runs. Not a real DOM parser on purpose.
    public static func htmlToText(_ html: String) -> String {
        var text = html
        for block in ["script", "style", "head", "noscript", "svg"] {
            text = text.replacingOccurrences(of: "<\(block)[\\s\\S]*?</\(block)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tiny recursive-descent parser (+ - * / % ^, parentheses, unary
    /// minus, decimals) rather than NSExpression — NSExpression raises
    /// uncatchable ObjC exceptions on malformed model-typed input.
    private static func calculatorResult(expression: String) -> String {
        var parser = ExpressionParser(expression)
        guard let value = parser.parse() else {
            return "Error: could not evaluate \"\(expression)\" — numbers, + - * / % ^ and parentheses only."
        }
        if value.isNaN || value.isInfinite { return "Error: the expression is undefined (division by zero?)." }
        let formatted = value == value.rounded() && abs(value) < 1e15
            ? String(format: "%.0f", value)
            : String(value)
        return "\(expression) = \(formatted)"
    }

    private struct ExpressionParser {
        private let characters: [Character]
        private var position = 0

        init(_ text: String) { characters = Array(text.replacingOccurrences(of: ",", with: "")) }

        mutating func parse() -> Double? {
            let value = parseAdditive()
            skipSpaces()
            return position == characters.count ? value : nil
        }

        private mutating func parseAdditive() -> Double? {
            guard var left = parseMultiplicative() else { return nil }
            while true {
                skipSpaces()
                guard position < characters.count, characters[position] == "+" || characters[position] == "-" else { return left }
                let op = characters[position]; position += 1
                guard let right = parseMultiplicative() else { return nil }
                left = op == "+" ? left + right : left - right
            }
        }

        private mutating func parseMultiplicative() -> Double? {
            guard var left = parsePower() else { return nil }
            while true {
                skipSpaces()
                guard position < characters.count, "*/%".contains(characters[position]) else { return left }
                let op = characters[position]; position += 1
                guard let right = parsePower() else { return nil }
                switch op {
                case "*": left *= right
                case "/": left /= right
                default: left = left.truncatingRemainder(dividingBy: right)
                }
            }
        }

        private mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            skipSpaces()
            guard position < characters.count, characters[position] == "^" else { return base }
            position += 1
            guard let exponent = parsePower() else { return nil }  // right-associative
            return pow(base, exponent)
        }

        private mutating func parseUnary() -> Double? {
            skipSpaces()
            if position < characters.count, characters[position] == "-" {
                position += 1
                return parseUnary().map { -$0 }
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Double? {
            skipSpaces()
            guard position < characters.count else { return nil }
            if characters[position] == "(" {
                position += 1
                let value = parseAdditive()
                skipSpaces()
                guard position < characters.count, characters[position] == ")" else { return nil }
                position += 1
                return value
            }
            var digits = ""
            while position < characters.count, characters[position].isNumber || characters[position] == "." {
                digits.append(characters[position]); position += 1
            }
            return Double(digits)
        }

        private mutating func skipSpaces() {
            while position < characters.count, characters[position] == " " { position += 1 }
        }
    }

    /// §6 write gate: in an ATTACHED project folder, every file write
    /// confirms through the shared approval flow first (reads stay free).
    /// The app-owned sandbox keeps silent writes. `false` = declined.
    private static func writeApproved(path: String, context: ExecutionContext) async -> Bool {
        guard context.requiresWriteApproval else { return true }
        guard let approve = context.approveWrite else {
            // Attached folder but no approval channel wired — refuse closed.
            return false
        }
        return await approve(path)
    }

    private static func writeFileResult(path: String, content: String, context: ExecutionContext) async -> String {
        guard let url = SandboxManager.resolve(path, in: context.workspaceDirectory) else {
            return "Error: \"\(path)\" is outside the workspace folder — only relative paths within it are allowed."
        }
        guard await writeApproved(path: path, context: context) else {
            return "The user declined this write to \(path). Don't retry unchanged — ask what they'd prefer instead."
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "Wrote \(content.utf8.count) bytes to \(path)."
        } catch {
            return "Error writing \(path): \(error.localizedDescription)"
        }
    }

    private static func readFileResult(path: String, context: ExecutionContext) -> String {
        guard let url = SandboxManager.resolve(path, in: context.workspaceDirectory) else {
            return "Error: \"\(path)\" is outside the workspace folder — only relative paths within it are allowed."
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: could not read \(path) — it may not exist yet."
        }
        return text
    }

    // MARK: - Scratchpad (§9.10)

    static let scratchpadFilename = ".scratchpad.md"

    private static func scratchpadResult(action: String, text: String, heading: String?, context: ExecutionContext) -> String {
        let url = context.workspaceDirectory.appendingPathComponent(scratchpadFilename)
        switch action {
        case "read":
            guard let current = try? String(contentsOf: url, encoding: .utf8), !current.isEmpty else {
                return "(the scratchpad is empty)"
            }
            // A compaction-surviving note must itself survive the reply cap.
            if current.count > Limits.toolResultBytes {
                return String(current.suffix(Limits.toolResultBytes)) + "\n[Older scratchpad entries were trimmed.]"
            }
            return current
        case "append":
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: \"text\" is required when appending."
            }
            var addition = ""
            if let heading, !heading.isEmpty {
                addition += "\n\n## \(heading)\n"
            } else {
                addition += "\n\n"
            }
            addition += text
            let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            do {
                try (current + addition).write(to: url, atomically: true, encoding: .utf8)
                return "Appended to the scratchpad."
            } catch {
                return "Error writing the scratchpad: \(error.localizedDescription)"
            }
        default:
            return "Error: \"action\" must be \"read\" or \"append\"."
        }
    }

    private static func listWorkspaceFilesResult(context: ExecutionContext) -> String {
        let root = context.workspaceDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root.path), !items.isEmpty else {
            return "The workspace folder is empty."
        }
        // .gitignore-aware: a listing is for orientation, and the model
        // doesn't need build artifacts or vendored dependencies in it.
        // (An explicit read_file of an ignored path still works — hiding a
        // file from the overview must not make it unopenable.)
        let ignoreRules = GitIgnore.load(from: root)
        let visible = items.sorted().filter { !$0.hasPrefix(".") && !GitIgnore.ignores(ignoreRules, relativePath: $0) }
        if visible.isEmpty {
            return items.count > 0
                ? "All \(items.count) entries are git-ignored; nothing to list. Use read_file with an exact name if you need one anyway."
                : "The workspace folder is empty."
        }
        let hidden = items.count - visible.count
        let suffix = hidden > 0 ? "\n(\(hidden) git-ignored entries not shown)" : ""
        return visible.joined(separator: "\n") + suffix
    }

    private static func editFileResult(path: String, oldString: String, newString: String, replaceAll: Bool, context: ExecutionContext) async -> String {
        guard let url = SandboxManager.resolve(path, in: context.workspaceDirectory) else {
            return "Error: \"\(path)\" is outside the workspace folder — only relative paths within it are allowed."
        }
        guard await writeApproved(path: path, context: context) else {
            return "The user declined this edit to \(path). Don't retry unchanged — ask what they'd prefer instead."
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: could not read \(path) — it may not exist yet. Use write_file to create it."
        }
        let occurrences = text.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else {
            return "Error: old_string was not found in \(path). Read the file and copy the exact text, including whitespace."
        }
        if occurrences > 1 && !replaceAll {
            return "Error: old_string matched \(occurrences) times in \(path). Add surrounding context to make it unique, or set replace_all=true."
        }
        let updated = text.replacingOccurrences(of: oldString, with: newString)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return "Edited \(path) — replaced \(replaceAll ? occurrences : 1) occurrence\(replaceAll && occurrences != 1 ? "s" : "")."
        } catch {
            return "Error writing \(path): \(error.localizedDescription)"
        }
    }

    private static func searchFilesResult(glob: String?, query: String?, context: ExecutionContext) -> String {
        let root = context.workspaceDirectory
        let globRegex = glob.map { Self.globToRegex($0) }
        let contentRegex = query.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        let ignoreRules = GitIgnore.load(from: root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return "Error: could not read the workspace folder."
        }
        var results: [String] = []
        var scanned = 0
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            if GitIgnore.ignores(ignoreRules, relativePath: relative) {
                // Don't just skip the file — skip descending into ignored
                // directories entirely, or a vendored tree costs the scan
                // budget even though nothing inside can match.
                enumerator.skipDescendants()
                continue
            }
            if let globRegex, relative.range(of: globRegex, options: .regularExpression) == nil,
               fileURL.lastPathComponent.range(of: globRegex, options: .regularExpression) == nil { continue }
            if let contentRegex {
                scanned += 1
                if scanned > 2_000 { break }
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let lines = text.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    if contentRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                        results.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(160))")
                        if results.count >= 100 { break }
                    }
                }
            } else {
                results.append(relative)
            }
            if results.count >= 100 { break }
        }
        if results.isEmpty { return "No matches." }
        let capped = results.count >= 100 ? results + ["[…more matches; refine the search.]"] : results
        return capped.joined(separator: "\n")
    }

    private static func globToRegex(_ glob: String) -> String {
        var regex = "^"
        for character in glob {
            switch character {
            case "*": regex += "[^/]*"
            case "?": regex += "[^/]"
            case ".": regex += "\\."
            default: regex += String(character)
            }
        }
        return regex + "$"
    }

    private static func searchConversationsResult(query: String, context: ExecutionContext) -> String {
        let lowerQuery = query.lowercased()
        var matches: [String] = []
        for summary in context.conversationSummaries {
            for message in summary.messages where message.content.lowercased().contains(lowerQuery) {
                let excerptStart = message.content.lowercased().range(of: lowerQuery)
                let excerpt: String
                if let excerptStart {
                    let start = message.content.index(excerptStart.lowerBound, offsetBy: -80, limitedBy: message.content.startIndex) ?? message.content.startIndex
                    let end = message.content.index(excerptStart.upperBound, offsetBy: 80, limitedBy: message.content.endIndex) ?? message.content.endIndex
                    excerpt = String(message.content[start..<end])
                } else {
                    excerpt = String(message.content.prefix(160))
                }
                matches.append("[\"\(summary.title)\", \(message.role)] …\(excerpt)…")
                if matches.count >= 8 { break }
            }
            if matches.count >= 8 { break }
        }
        guard !matches.isEmpty else { return "No past conversations mention \"\(query)\"." }
        return "Found \(matches.count) match(es) for \"\(query)\":\n\n" + matches.joined(separator: "\n\n")
    }

    private static func webSearchResult(query: String, context: ExecutionContext) async -> String {
        let trimmedEndpoint = context.searchEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            // "Error" prefix is load-bearing: it's how activity lines know a
            // call failed (see `activityFinished` emission in ChatAPI).
            return "Error: web search isn't configured — no SearXNG endpoint is set in Settings."
        }
        do {
            let results = try await CompatibleChatClient.shared.searchWeb(query: query, endpoint: trimmedEndpoint)
            guard !results.isEmpty else { return "No results found for \"\(query)\"." }
            return results.map { "- \($0.title)\n  \($0.url)\n  \($0.snippet)" }.joined(separator: "\n\n")
        } catch {
            return "Error: web search failed — \(error.localizedDescription)"
        }
    }
}
