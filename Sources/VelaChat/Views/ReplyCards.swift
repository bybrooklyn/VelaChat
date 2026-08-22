import SwiftUI
import VelaCore
import AppKit
import MarkdownUI

/// A `role: "notice"` message rendered as a quiet system card — everything
/// that used to be a banner above the composer (no provider chosen, already
/// generating, saved history unreadable) now shows up here instead, so
/// errors always appear in one place: the conversation itself.
struct NoticeCard: View {
    let message: ChatMessage

    private var symbol: String {
        switch message.noticeKind {
        case "success": "checkmark.circle"
        case "info": "info.circle"
        case "refusal": "hand.raised"
        default: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch message.noticeKind {
        case "success": Theme.success
        case "info": Theme.secondaryText
        case "refusal": Theme.accent
        default: Theme.warning
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(message.content)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceMid, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        }
        .messageColumn()
    }
}

/// Marks where a conversation was compacted — nothing above this is ever
/// deleted or hidden, only left out of the request payload for future
/// turns. Collapsed by default, expandable to see the actual generated
/// summary (what's really being sent in its place).
struct CompactionCard: View {
    let message: ChatMessage
    @State private var isExpanded = false

    var body: some View {
        ActivityRow(
            symbol: "arrow.down.right.and.arrow.up.left",
            title: "Conversation compacted here",
            tint: Theme.tertiaryText,
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing above was deleted — this summary just replaces those messages in what's actually sent to the model from here on.")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
            }
        }
        .messageColumn()
    }
}

/// The run_command approval gate. Generation is genuinely paused behind
/// this card: the exact command and working directory are shown, the
/// command text is editable before approving, and a denial goes back to
/// the model as a normal tool result. "Allow all in this chat" is armed
/// separately and deliberately — never a side effect of approving once.
struct CommandApprovalCard: View {
    let approval: AppModel.CommandApproval
    @State private var editedCommand: String = ""
    @State private var didAppear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: approval.isSubagentRequest ? "person.2" : "terminal")
                    .foregroundStyle(Theme.warning)
                Text(approval.isSubagentRequest ? "Run subagents?" : "Run this command?")
                    .font(.body.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text(approval.reason)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            if approval.isSubagentRequest {
                Text(approval.command)
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Command", text: $editedCommand, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .flatFieldStyle()
                    .lineLimit(1...6)
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text(approval.directory.path)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Theme.tertiaryText)
            }
            HStack(spacing: 8) {
                Button(approval.isSubagentRequest ? "Run" : "Run") { approval.decide(.approveOnce(trimmed)) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                // Sensitive commands offer no trust paths at all — the
                // classifier decided this is a publish/delete/send/
                // credential decision, and those are made fresh every time.
                if !approval.isSubagentRequest, !approval.isSensitive {
                    Button("Always Allow This") { approval.decide(.approveAlways(trimmed)) }
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                Button(approval.isSubagentRequest ? "Skip" : "Deny") { approval.decide(.deny) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            if approval.isSensitive {
                Label("This publishes, deletes, sends, or touches credentials — it always asks, even with \"allow all\" on.", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            if !approval.isSubagentRequest, !approval.isSensitive {
                if let rule = alwaysAllowRule, let folder = approval.trustFolderPath {
                    let folderName = (folder as NSString).lastPathComponent
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            approval.decide(.approveRule(command: trimmed, rule: rule))
                        } label: {
                            Label("Always allow \u{201C}\(rule)…\u{201D} in \(folderName)", systemImage: "checkmark.seal")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Always allow commands starting with \(rule) in the folder \(folderName), remembered after you quit")
                        // The one piece of trust here that outlives the app,
                        // so it says so — and says what it really means:
                        // there is no sandbox behind any of this.
                        Text("Remembered for this folder until you forget it in Settings. Build commands run as you, unsandboxed.")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button {
                    approval.decide(.approveAll(trimmed))
                } label: {
                    Label("Allow every command in this chat (until you quit)", systemImage: "lock.open")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(Theme.sidebarBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.warning.opacity(0.4), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            editedCommand = approval.command
        }
    }

    private var trimmed: String {
        editedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? approval.command
            : editedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The prefix rule this command would be remembered as — nil when the
    /// conversation has no folder of the user's attached (a sandbox
    /// workspace never holds rules) or the command is too shell-shaped to
    /// summarize into one. Derived from the *edited* text, so the offer
    /// always matches what the button above it would actually run.
    private var alwaysAllowRule: String? {
        guard approval.trustFolderPath != nil else { return nil }
        return CommandTrust.suggestedRule(for: trimmed)
    }
}

/// The Approve/Reject decision a `PlanCard` carries while the conversation
/// is in planning mode — the plan is a proposal waiting on an answer then,
/// not a progress checklist.
struct PlanDecision {
    let approve: () -> Void
    let reject: (String) -> Void
}

/// Offered above the composer, once per conversation, when what is being
/// typed looks like real multi-step work.
///
/// Deliberately not a blocking sheet: it sits in the composer stack and
/// the user can ignore it and press Send. Interrupting someone mid-thought
/// to ask a process question is how a good default becomes an annoyance.
struct PlanModeSuggestionCard: View {
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Plan this one first?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text("Planning mode reads and explores but cannot edit files, change memory, or run build commands until you approve a plan.")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Plan first") { onAccept() }
                .buttonStyle(VelaControlButtonStyle(tint: Theme.accent))
                .accessibilityLabel("Turn on planning mode for this conversation")
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryText)
            .help("Not now")
            .accessibilityLabel("Dismiss the planning mode suggestion for this conversation")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous), emphasis: 0.4)
    }
}

/// The model's live task plan (`update_plan`) — a compact checklist that
/// updates in place as steps advance, and collapses to a one-line summary
/// once the reply is done, so a finished conversation doesn't stay full of
/// scaffolding.
struct PlanCard: View {
    let steps: [ToolCatalog.PlanStep]
    let isWorking: Bool
    /// Non-nil only while the conversation is in planning mode and this is
    /// the plan awaiting an answer — the deliberate way out of the mode,
    /// rather than the tools silently unlocking themselves.
    var decision: PlanDecision? = nil
    @State private var isExpanded = true
    @State private var isRejecting = false
    @State private var feedback = ""

    private var completed: Int { steps.filter { $0.status == "completed" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(completed == steps.count ? "Completed \(steps.count) steps" : "Plan · \(completed)/\(steps.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: symbol(for: step.status))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(color(for: step.status))
                                .frame(width: 13)
                            if step.status == "in_progress", isWorking {
                                ShimmerText(text: step.step, font: .caption)
                            } else {
                                Text(step.step)
                                    .font(.caption)
                                    .foregroundStyle(step.status == "completed" ? Theme.tertiaryText : Theme.text)
                                    .strikethrough(step.status == "completed", color: Theme.tertiaryText)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .transition(.opacity)
            }

            if let decision {
                Divider()
                    .padding(.vertical, 1)
                if isRejecting {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("What should change?", text: $feedback, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .flatFieldStyle()
                            .lineLimit(1...4)
                            .accessibilityLabel("What should change about this plan")
                        HStack(spacing: 7) {
                            Button("Send Feedback") {
                                let note = feedback
                                feedback = ""
                                isRejecting = false
                                decision.reject(note)
                            }
                            .buttonStyle(VelaControlButtonStyle(tint: Theme.accent))
                            .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Send this feedback and stay in planning mode")
                            Button("Cancel") { isRejecting = false }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                } else {
                    HStack(spacing: 7) {
                        Button("Approve & Start") { decision.approve() }
                            .buttonStyle(VelaControlButtonStyle(tint: Theme.accent))
                            .accessibilityLabel("Approve this plan, leave planning mode, and start the work")
                        Button("Request Changes") {
                            withAnimation(.easeOut(duration: 0.16)) { isRejecting = true }
                        }
                        .buttonStyle(VelaControlButtonStyle(tint: Theme.secondaryText))
                        .accessibilityLabel("Reject this plan and say what should change, staying in planning mode")
                        Spacer(minLength: 0)
                        Text("Planning mode")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
        }
        .padding(11)
        .messageColumn()
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous), emphasis: 0.4)
        .animation(.easeOut(duration: 0.2), value: steps)
        .onChange(of: isWorking) { _, working in
            // Fold the scaffolding away once the work is finished.
            if !working, completed == steps.count {
                withAnimation(.easeOut(duration: 0.25)) { isExpanded = false }
            }
        }
    }

    private func symbol(for status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted"
        default: "circle"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": Theme.success
        case "in_progress": Theme.accent
        default: Theme.tertiaryText
        }
    }
}

/// Renders a ````ask-user` block as a real interactive picker instead of raw
/// JSON — the model's answer to "what do you want me to do" becomes a click
/// (plus an optional note) instead of a typed reply. Submitting composes a
/// plain-text summary and sends it as the next message, so no new wire
/// format is needed on the way back to the provider.
///
/// Multiple questions render as tabs (one per `header`) rather than stacked
/// vertically — the same shape Claude Code's own picker uses. Navigation is
/// free: any tab can be opened in any order, and a question can be left
/// blank. Because of that, Send never blocks on completeness; it only warns
/// before going out incomplete, via `showingIncompleteConfirm`.
///
/// The primary button reads `Next` until the last question and `Send` only
/// there, so a multi-question card can't be fired off from question one by
/// pressing the only obvious control on screen.
struct AskUserQuestionCard: View {
    @Environment(AppModel.self) private var appModel
    let payload: AskUserQuestionPayload
    let interactive: Bool
    /// Where the composed answer goes. `nil` is the fenced ```ask-user
    /// path, where the model's turn has already ended and the answer has
    /// to travel as a brand-new user message. The real `ask_user` tool
    /// sets this instead, so the answer resumes the suspended tool call
    /// rather than starting another turn.
    var onAnswer: ((String) -> Void)? = nil
    /// A resolved card is a record, not a live control: the picker
    /// collapses to a settled line so an answered question stops looking
    /// like it still wants input. Only the live mount passes `false`.
    var resolved: Bool = false

    /// Selections keyed by question text — each question answers
    /// independently, and any of them may stay empty.
    @State private var selected: [String: Set<String>] = [:]
    @State private var notes = ""
    @State private var submitted = false
    @State private var activeIndex = 0
    @State private var showingIncompleteConfirm = false
    @State private var showsResolvedDetail = false

    private var questions: [AskUserQuestionPayload.Question] { payload.questions }

    private func isAnswered(_ question: AskUserQuestionPayload.Question) -> Bool {
        !(selected[question.id] ?? []).isEmpty
    }

    private var unansweredCount: Int {
        questions.filter { !isAnswered($0) }.count
    }

    /// `Next` until the last question, then `Send` — see
    /// `AskUserQuestionPayload.primaryAction`, which owns the rule so it can
    /// be tested. Free navigation via the tab strip is untouched: any
    /// question can still be revisited in any order, and any of them may
    /// still be left blank.
    private var primaryAction: AskUserQuestionPayload.PrimaryAction {
        AskUserQuestionPayload.primaryAction(activeIndex: activeIndex, questionCount: questions.count)
    }

    var body: some View {
        if resolved {
            resolvedCard
        } else {
            liveCard
        }
    }

    /// The answered-state record: one settled line, expandable to what was
    /// asked. The selections aren't replayed here — they traveled to the
    /// model as the composed answer message, and duplicating them would
    /// invent a state this view no longer owns.
    private var resolvedCard: some View {
        ActivityRow(
            symbol: "checkmark.circle",
            title: questions.count == 1
                ? "User answered the question"
                : "User answered \(questions.count) questions",
            tint: Theme.success,
            isActive: false,
            isExpanded: $showsResolvedDetail
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(questions) { question in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(question.question)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.secondaryText)
                        ForEach(question.options) { option in
                            Text("· " + option.label)
                                .font(.caption)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .messageColumn()
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if questions.count > 1 {
                tabStrip
            }
            questionBody(questions[activeIndex])
            if payload.allowNotes, interactive, !submitted {
                TextField("Add a note (optional)", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .flatFieldStyle()
                    .lineLimit(1...4)
            }
            if interactive, !submitted {
                HStack(spacing: 10) {
                    let action = primaryAction
                    Button(action.title) {
                        switch action {
                        case .next(let index): activeIndex = index
                        case .send: attemptSubmit()
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentStrong)
                    // The title is the whole meaning of this control, so the
                    // announced label has to move with it — a button that
                    // reads "Send" to VoiceOver while showing "Next" is
                    // worse than no label at all.
                    .accessibilityLabel(
                        {
                            switch action {
                            case .next(let index): "Next question, \(index + 1) of \(questions.count)"
                            case .send: "Send answers"
                            }
                        }()
                    )
                    if questions.count > 1 {
                        Text("\(questions.count - unansweredCount) of \(questions.count) answered")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
        }
        .padding(16)
        .messageColumn()
        .background(Theme.surfaceMid, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.accent.opacity(0.2), lineWidth: 1)
        }
        // Selection, the active tab, and the post-submit state settle with a
        // fade instead of controls jumping in one frame.
        .animation(.easeOut(duration: 0.15), value: selected)
        .animation(.easeOut(duration: 0.2), value: submitted)
        .animation(.easeOut(duration: 0.15), value: activeIndex)
        .alert("Send with \(unansweredCount) unanswered?", isPresented: $showingIncompleteConfirm) {
            Button("Send Anyway") { submit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can jump back to any tab and answer first, or send as-is.")
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                tabButton(index: index, question: question)
            }
            Spacer(minLength: 0)
        }
    }

    private func tabButton(index: Int, question: AskUserQuestionPayload.Question) -> some View {
        let answered = isAnswered(question)
        let isActive = activeIndex == index
        let label = (question.header?.isEmpty == false) ? question.header! : "Q\(index + 1)"
        return Button {
            activeIndex = index
        } label: {
            HStack(spacing: 5) {
                Image(systemName: answered ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(answered ? Theme.success : Theme.tertiaryText)
                Text(label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isActive ? Theme.accentSoft.opacity(0.9) : Theme.surfaceHigh.opacity(0.5),
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                    .stroke(isActive ? Theme.accent.opacity(0.4) : Theme.controlStroke.opacity(0.35), lineWidth: 1)
            }
            .foregroundStyle(isActive ? Theme.text : Theme.secondaryText)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)\(answered ? ", answered" : ", unanswered")")
    }

    private func questionBody(_ question: AskUserQuestionPayload.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The tab strip already carries the header for a multi-question
            // card — repeating it here as a chip would be the same label
            // twice in a row. Single-question cards have no tab strip, so
            // they keep the chip as their only header treatment.
            if questions.count == 1, let header = question.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.accentSoft.opacity(0.5), in: Capsule())
            }
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                Text(question.question)
                    .font(.body.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(question.options) { option in
                    optionRow(option, in: question)
                }
            }
        }
        // Re-identify the whole block by question id so a tab switch swaps
        // content instead of SwiftUI trying to diff option rows across two
        // unrelated questions.
        .id(question.id)
    }

    private func optionRow(_ option: AskUserQuestionPayload.Option, in question: AskUserQuestionPayload.Question) -> some View {
        let isOn = (selected[question.id] ?? []).contains(option.label)
        return Button {
            guard interactive, !submitted else { return }
            var current = selected[question.id] ?? []
            if question.multiSelect {
                if current.contains(option.label) { current.remove(option.label) } else { current.insert(option.label) }
            } else {
                current = [option.label]
            }
            selected[question.id] = current
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol(isOn: isOn, multiSelect: question.multiSelect))
                    .foregroundStyle(isOn ? Theme.accent : Theme.tertiaryText)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.text)
                        if option.recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isOn ? Theme.accentSoft.opacity(0.7) : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous)
                    .stroke(
                        isOn ? Theme.accent.opacity(0.35) : Theme.controlStroke.opacity(0.4),
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!interactive || submitted)
    }

    private func symbol(isOn: Bool, multiSelect: Bool) -> String {
        if multiSelect { return isOn ? "checkmark.square.fill" : "square" }
        return isOn ? "largecircle.fill.circle" : "circle"
    }

    /// Free navigation means a question can legitimately be left blank —
    /// Send is never disabled on that basis. It only warns first, once,
    /// when something's missing; the actual send is `submit()`.
    private func attemptSubmit() {
        guard unansweredCount > 0 else {
            submit()
            return
        }
        showingIncompleteConfirm = true
    }

    private func submit() {
        submitted = true
        var lines: [String] = []
        for question in questions {
            let chosen = question.options
                .filter { (selected[question.id] ?? []).contains($0.label) }
                .map(\.label)
            let name = question.header ?? question.question
            if chosen.isEmpty {
                lines.append(questions.count == 1
                    ? "I didn't answer this one."
                    : "\(name): (left unanswered)")
                continue
            }
            lines.append(questions.count == 1
                ? "I choose: \(chosen.joined(separator: ", "))"
                : "\(name): \(chosen.joined(separator: ", "))")
        }
        var summary = lines.joined(separator: "\n")
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            summary += "\n\nNote: \(trimmedNotes)"
        }
        if let onAnswer {
            onAnswer(summary)
        } else {
            appModel.send(summary)
        }
    }
}

/// "What informed this reply" — a dim line under a reply that drew on
/// memory, expanding to the actual excerpts.
///
/// Invisible when nothing was recalled, so ordinary conversation stays
/// clean; when it does appear, every item can be jumped to or forgotten,
/// because memory the user can't inspect or correct is memory they can't
/// trust.
///
/// The two kinds of recall are shown as two labelled groups rather than
/// one list. They are not the same thing and cannot be acted on the same
/// way: a saved fact is a short standing statement the user can strike
/// out individually, while an excerpt is a fragment of a real past
/// message whose only useful action is "show me where that came from".
/// Merged into one list the whole row read as undifferentiated noise, and
/// the "Open" button appearing on some rows and not others looked like a
/// bug rather than a difference in kind.
struct RecallLine: View {
    @Environment(AppModel.self) private var appModel
    let recalls: [MemoryRecall]
    @State private var isExpanded = false

    private var facts: [MemoryRecall] { recalls.filter(\.isFact) }
    private var excerpts: [MemoryRecall] { recalls.filter { !$0.isFact } }

    private var summary: String {
        var parts: [String] = []
        if !facts.isEmpty { parts.append("\(facts.count) saved fact\(facts.count == 1 ? "" : "s")") }
        if !excerpts.isEmpty { parts.append("\(excerpts.count) past \(excerpts.count == 1 ? "message" : "messages")") }
        return "Drew on " + parts.joined(separator: " and ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 10, weight: .medium))
                    Text(summary)
                        .font(.caption)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.tertiaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("What this reply drew on")
            .accessibilityLabel("What this reply drew on")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if !facts.isEmpty {
                        group(title: "Saved facts", items: facts)
                    }
                    if !excerpts.isEmpty {
                        group(title: "From past conversations", items: excerpts)
                    }
                }
                .padding(.leading, 16)
                .transition(.opacity)
            }
        }
        .padding(.top, 2)
    }

    private func group(title: String, items: [MemoryRecall]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { recall in
                row(recall)
            }
        }
    }

    private func row(_ recall: MemoryRecall) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: recall.isFact ? "bookmark" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 2)
            Text(recall.text)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(3)
            Spacer(minLength: 0)
            if case .conversation(let conversationID, _) = recall.origin {
                Button("Open") { appModel.openConversation(id: conversationID) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .help("Jump to that conversation")
                    .accessibilityLabel("Jump to that conversation")
            }
            Button {
                // Still a real delete on both paths: a fact is removed
                // from the store, an excerpt is dropped from the index.
                appModel.forgetRecall(recall)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryText)
            .help(recall.isFact ? "Forget this fact" : "Stop using this message")
            .accessibilityLabel(recall.isFact ? "Forget this fact" : "Stop using this message")
        }
    }
}
