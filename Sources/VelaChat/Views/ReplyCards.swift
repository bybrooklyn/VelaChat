import SwiftUI
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
        default: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch message.noticeKind {
        case "success": Theme.success
        case "info": Theme.secondaryText
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
                if !approval.isSubagentRequest {
                    Button("Always Allow This") { approval.decide(.approveAlways(trimmed)) }
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                Button(approval.isSubagentRequest ? "Skip" : "Deny") { approval.decide(.deny) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            if !approval.isSubagentRequest {
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
}

/// The model's live task plan (`update_plan`) — a compact checklist that
/// updates in place as steps advance, and collapses to a one-line summary
/// once the reply is done, so a finished conversation doesn't stay full of
/// scaffolding.
struct PlanCard: View {
    let steps: [ToolCatalog.PlanStep]
    let isWorking: Bool
    @State private var isExpanded = true

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
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
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
struct AskUserQuestionCard: View {
    @Environment(AppModel.self) private var appModel
    let payload: AskUserQuestionPayload
    let interactive: Bool

    /// Selections keyed by question text — each question answers
    /// independently; Send unlocks once every one has an answer.
    @State private var selected: [String: Set<String>] = [:]
    @State private var notes = ""
    @State private var submitted = false

    private var canSubmit: Bool {
        payload.questions.allSatisfy { !(selected[$0.id] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(payload.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = question.header, !header.isEmpty {
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
            }
            if payload.allowNotes, interactive, !submitted {
                TextField("Add a note (optional)", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .flatFieldStyle()
                    .lineLimit(1...4)
            }
            if interactive, !submitted {
                Button("Send") { submit() }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentStrong)
                    .disabled(!canSubmit)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceMid, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.accent.opacity(0.2), lineWidth: 1)
        }
        // Selection and the post-submit state settle with a fade instead of
        // controls vanishing in one frame.
        .animation(.easeOut(duration: 0.15), value: selected)
        .animation(.easeOut(duration: 0.2), value: submitted)
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

    private func submit() {
        guard canSubmit else { return }
        submitted = true
        var lines: [String] = []
        for question in payload.questions {
            let chosen = question.options
                .filter { (selected[question.id] ?? []).contains($0.label) }
                .map(\.label)
            let name = question.header ?? question.question
            lines.append(payload.questions.count == 1
                ? "I choose: \(chosen.joined(separator: ", "))"
                : "\(name): \(chosen.joined(separator: ", "))")
        }
        var summary = lines.joined(separator: "\n")
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            summary += "\n\nNote: \(trimmedNotes)"
        }
        appModel.send(summary)
    }
}
