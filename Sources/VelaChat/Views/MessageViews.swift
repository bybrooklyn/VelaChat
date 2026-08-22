import SwiftUI
import VelaCore
import AppKit
import MarkdownUI

struct MessageRow: View {
    @Environment(AppModel.self) private var appModel
    let message: ChatMessage
    let isLastMessage: Bool
    @State private var showingReasoning = false
    @State private var showingSearchResults = false
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editedText = ""
    @State private var alternateIndex = 0

    private var totalVersions: Int { message.alternates.count + 1 }
    private var displayedMessage: ChatMessage {
        guard alternateIndex > 0, alternateIndex - 1 < message.alternates.count else { return message }
        return message.alternates[alternateIndex - 1]
    }

    private var pinIndicator: some View {
        HStack(spacing: 3) {
            Image(systemName: "pin.fill")
                .font(.system(size: 8))
            Text("Pinned")
                .font(.caption2)
        }
        .foregroundStyle(Theme.accent)
    }

    var isGroupedWithPrevious: Bool = false

    static func timestampLabel(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return "\(relative) · \(time.string(from: date))"
    }

    var body: some View {
        if message.role == "notice" {
            NoticeCard(message: message)
        } else if message.role == "compaction" {
            CompactionCard(message: message)
        } else if message.role == "user" {
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 120)
                Button {
                    editedText = message.content
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
                .help("Edit message")
                .accessibilityLabel("Edit message")
                .opacity(isHovering && !isEditing ? 1 : 0)
                .allowsHitTesting(isHovering && !isEditing)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                VStack(alignment: .trailing, spacing: 4) {
                    if isEditing {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextField("Message", text: $editedText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(1...6)
                            HStack(spacing: 6) {
                                Button("Cancel") { isEditing = false }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.tertiaryText)
                                Button("Save") {
                                    isEditing = false
                                    appModel.editMessage(message, newContent: editedText)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, appModel.density.bubblePadding)
                        .frame(minWidth: 220)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                    } else {
                        if !message.attachments.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(message.attachments) { attachment in
                                    AttachmentChip(attachment: attachment)
                                }
                            }
                        }
                        if !message.redactions.isEmpty {
                            RedactionChipRow(spans: message.redactions)
                        }
                        RichMessageText(text: message.content, isUser: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, appModel.density.bubblePadding)
                            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                            .contextMenu {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(message.content, forType: .string)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                Button {
                                    editedText = message.content
                                    isEditing = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button {
                                    if let conversation = appModel.activeConversation {
                                        appModel.branchConversation(from: message, in: conversation)
                                    }
                                } label: {
                                    Label("Branch from Here", systemImage: "arrow.triangle.branch")
                                }
                                Button {
                                    appModel.toggleMessagePin(message)
                                } label: {
                                    Label(message.isPinned ? "Unpin" : "Pin", systemImage: message.isPinned ? "pin.slash" : "pin")
                                }
                                Button(role: .destructive) {
                                    appModel.deleteMessage(message)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    if message.isPinned {
                        pinIndicator
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isEditing)
            }
            .onHover { isHovering = $0 }
        } else {
            HStack(alignment: .top, spacing: 11) {
                if isGroupedWithPrevious {
                    // Same speaker as above: the avatar yields to a spacer so
                    // consecutive replies read as one tight run.
                    Color.clear.frame(width: 23, height: 1)
                } else {
                    VelaMark(size: 23)
                        .padding(.top, 1)
                        .help(displayedMessage.modelID.map { "Generated by \($0)" } ?? (displayedMessage.providerName ?? ""))
                        .accessibilityLabel(displayedMessage.modelID.map { "Generated by \($0)" } ?? (displayedMessage.providerName ?? ""))
                }
                VStack(alignment: .leading, spacing: 7) {
                    // No provider-name header — the VelaMark avatar is the
                    // whole signature (model id lives in its tooltip).
                    if message.isPinned || totalVersions > 1 {
                        HStack(spacing: 8) {
                            Spacer()
                            if message.isPinned {
                                pinIndicator
                            }
                            if totalVersions > 1 {
                                AlternateStepper(index: $alternateIndex, total: totalVersions)
                            }
                        }
                    }

                    if alternateIndex == 0, let record = appModel.searchByMessage[message.id] {
                        SearchResultsDisclosure(record: record, isExpanded: $showingSearchResults)
                    }

                    if alternateIndex == 0, let steps = appModel.planByMessage[message.id], !steps.isEmpty {
                        PlanCard(
                            steps: steps,
                            isWorking: message.isStreaming,
                            decision: planDecision(for: message, steps: steps)
                        )
                    }

                    if alternateIndex == 0, let recalled = appModel.recallByMessage[message.id], !recalled.isEmpty {
                        RecallLine(recalls: recalled)
                    }

                    // Fallback only. Reasoning now rides the timeline and
                    // renders inside `AssistantTimeline` at the point the
                    // model actually thought; this pinned-to-the-top block
                    // is what transcripts saved before segments carried
                    // reasoning still need. Gating on `hasTimelineReasoning`
                    // rather than on `reasoning` being non-empty is what
                    // stops a new message showing the same chain twice.
                    if let reasoning = displayedMessage.reasoning, !reasoning.isEmpty,
                       !displayedMessage.hasTimelineReasoning {
                        ReasoningDisclosure(
                            reasoning: reasoning,
                            isThinking: alternateIndex == 0 && message.isStreaming
                                && (displayedMessage.content.isEmpty || appModel.isRevealingReasoning(message.id)),
                            isExpanded: $showingReasoning
                        )
                    }

                    if let error = displayedMessage.error {
                        VStack(alignment: .leading, spacing: 8) {
                            // A mid-stream failure keeps whatever already
                            // streamed — hiding 800 words behind a triangle
                            // was pure data loss for the reader.
                            if !displayedMessage.content.isEmpty {
                                RichMessageText(text: displayedMessage.content, isUser: false)
                            }
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.danger)
                            if alternateIndex == 0 {
                                Button("Try Again") { appModel.retryLastMessage() }
                                    .buttonStyle(VelaControlButtonStyle(tint: Theme.danger))
                            }
                        }
                    } else if alternateIndex == 0, let ask = displayedMessage.askQuestion {
                        // The card appears the moment the closing fence
                        // arrives — no need to wait for the stream to end.
                        VStack(alignment: .leading, spacing: 10) {
                            if !ask.prefix.isEmpty {
                                RichMessageText(text: ask.prefix, isUser: false)
                            }
                            AskUserQuestionCard(
                                payload: ask.payload,
                                interactive: isLastMessage && !appModel.isGenerating
                            )
                            if !ask.suffix.isEmpty {
                                RichMessageText(text: ask.suffix, isUser: false)
                            }
                        }
                    } else if message.isStreaming, alternateIndex == 0,
                              AskUserQuestionPayload.hasUnterminatedFence(in: displayedMessage.content) {
                        // Mid-stream, fence open: never show the raw JSON
                        // typing itself out — a quiet placeholder instead.
                        VStack(alignment: .leading, spacing: 10) {
                            let prefix = AskUserQuestionPayload.prefixBeforeUnterminatedFence(in: displayedMessage.content)
                            if !prefix.isEmpty {
                                RichMessageText(text: prefix, isUser: false)
                            }
                            HStack(spacing: 8) {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.tertiaryText)
                                ShimmerText(text: "Preparing a question…", font: .callout)
                            }
                        }
                    } else if message.isStreaming, alternateIndex == 0,
                              displayedMessage.content.isEmpty,
                              (displayedMessage.reasoning ?? "").isEmpty,
                              displayedMessage.segments.isEmpty,
                              appModel.planByMessage[message.id]?.isEmpty ?? true {
                        // Nothing has arrived yet — no text, no reasoning, no
                        // tool activity, no plan. Without this the bubble is
                        // just blank until the first token lands, which reads
                        // as "is this even doing anything" on a slow or
                        // failing provider. `statusMessage` wins when it's
                        // set (it names the real pre-stream work — "Starting
                        // MCP servers…"); a generic "Thinking…" still beats
                        // silence when nothing more specific is known yet.
                        HStack(spacing: 8) {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.tertiaryText)
                            ShimmerText(text: appModel.statusMessage ?? "Thinking…", font: .callout)
                        }
                    } else {
                        AssistantTimeline(message: displayedMessage)
                            .contextMenu {
                                if !displayedMessage.content.isEmpty {
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(displayedMessage.content, forType: .string)
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }
                                if alternateIndex == 0 {
                                    Button {
                                        appModel.regenerate(message)
                                    } label: {
                                        Label("Regenerate", systemImage: "arrow.counterclockwise")
                                    }
                                    .disabled(appModel.isGenerating)
                                    Button {
                                        appModel.continueGenerating(message)
                                    } label: {
                                        Label("Continue Generating", systemImage: "arrow.forward.to.line")
                                    }
                                    .disabled(appModel.isGenerating)
                                }
                                Button {
                                    if let conversation = appModel.activeConversation {
                                        appModel.branchConversation(from: message, in: conversation)
                                    }
                                } label: {
                                    Label("Branch from Here", systemImage: "arrow.triangle.branch")
                                }
                                Button {
                                    appModel.toggleMessagePin(message)
                                } label: {
                                    Label(message.isPinned ? "Unpin" : "Pin", systemImage: message.isPinned ? "pin.slash" : "pin")
                                }
                                Button(role: .destructive) {
                                    appModel.deleteMessage(message)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }

                    if !message.isStreaming {
                        HStack(spacing: 10) {
                            if let summary = appModel.usageByMessage[displayedMessage.id] ?? displayedMessage.usage,
                               let label = summary.label {
                                // Price against the provider that actually
                                // produced this reply (stamped by name at
                                // send time), not whatever is selected now.
                                let costProviderID = appModel.providers.profiles
                                    .first(where: { $0.name == displayedMessage.providerName })?.id
                                    ?? appModel.activeConversation?.providerID
                                    ?? UUID()
                                let cost = summary.costUSD(
                                    for: appModel.providers.modelInfo(
                                        for: costProviderID,
                                        model: displayedMessage.modelID ?? ""
                                    ),
                                    providerKind: appModel.providers.profile(id: costProviderID)?.kind
                                )
                                Text(cost.map { label + String(format: " · $%.4f", $0) } ?? label)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            MessageActionRow(
                                message: message,
                                displayedMessage: displayedMessage,
                                canRegenerate: alternateIndex == 0
                            )
                            if appModel.isHoverTimestampsEnabled {
                                Text(Self.timestampLabel(for: displayedMessage.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.tertiaryText)
                                    .opacity(isHovering ? 1 : 0)
                                    .animation(.easeOut(duration: 0.15), value: isHovering)
                            }
                            Spacer(minLength: 0)
                        }
                        // Persistent, not hover-revealed — dim at rest,
                        // brightening when the pointer arrives.
                        .opacity(isHovering ? 1 : 0.65)
                        .animation(.easeOut(duration: 0.15), value: isHovering)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onHover { isHovering = $0 }
        }
    }

    /// Approve/Reject on a plan, but only where they mean something: the
    /// conversation is actually in planning mode, this is the newest reply,
    /// and it has finished streaming. On an older plan the buttons would be
    /// approving a plan that has since been revised; mid-stream they would
    /// be approving a list still being written.
    private func planDecision(for message: ChatMessage, steps: [ToolCatalog.PlanStep]) -> PlanDecision? {
        guard let conversation = appModel.activeConversation,
              conversation.isPlanning,
              isLastMessage,
              !message.isStreaming,
              !appModel.isGenerating else { return nil }
        return PlanDecision(
            approve: { appModel.approvePlan(steps, for: conversation) },
            reject: { appModel.rejectPlan(feedback: $0, for: conversation) }
        )
    }
}

/// Proof that redaction ran, shown above the message it changed.
///
/// A silent substitution is not acceptable (the whole point of the
/// feature is that the user can tell it worked), so every rule that fired
/// gets a named chip with its match count. The redacted text itself
/// carries an inline `[redacted: <rule>]` marker where the secret was, so
/// the transcript reads honestly on its own too.
struct RedactionChipRow: View {
    let spans: [RedactionSpan]

    /// Rule name → how many times it fired, in first-seen order so the
    /// row doesn't reshuffle between renders.
    private var tallies: [(name: String, count: Int, inAttachment: Bool)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var attachmentOnly: [String: Bool] = [:]
        for span in spans {
            if counts[span.ruleName] == nil {
                order.append(span.ruleName)
                attachmentOnly[span.ruleName] = true
            }
            counts[span.ruleName, default: 0] += 1
            if span.isInMessageBody { attachmentOnly[span.ruleName] = false }
        }
        return order.map { ($0, counts[$0] ?? 0, attachmentOnly[$0] ?? false) }
    }

    private func label(_ tally: (name: String, count: Int, inAttachment: Bool)) -> String {
        var text = tally.name
        if tally.count > 1 { text += " ×\(tally.count)" }
        if tally.inAttachment { text += " (attachment)" }
        return text
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash.fill")
                .font(.caption2)
                .foregroundStyle(Theme.warning)
            ForEach(tallies, id: \.name) { tally in
                Text(label(tally))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.warning.opacity(0.14), in: Capsule())
                    .overlay { Capsule().stroke(Theme.warning.opacity(0.35), lineWidth: 1) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Redacted before sending")
        .accessibilityValue(tallies.map(label).joined(separator: ", "))
        .help("These were replaced with a placeholder before this message left your Mac.")
    }
}

/// Staged attachments in the composer — thumbnail for images, an icon chip
/// with filename/size for everything else, each removable before send.
struct AttachmentChipRow: View {
    @Binding var attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
        }
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if attachment.kind == .image, let nsImage = NSImage(data: attachment.data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.modelAccent)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(attachment.sizeLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.surfaceMid, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous), emphasis: 0.5)
    }

    private var symbol: String {
        switch attachment.kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.text"
        case .git: "arrow.triangle.branch"
        }
    }
}

struct MessageActionRow: View {
    @Environment(AppModel.self) private var appModel
    let message: ChatMessage
    let displayedMessage: ChatMessage
    let canRegenerate: Bool

    var body: some View {
        HStack(spacing: 10) {
            if !displayedMessage.content.isEmpty {
                CopyButton(text: displayedMessage.content)
            }
            if canRegenerate {
                Button {
                    appModel.regenerate(message)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(Theme.tertiaryText)
                .disabled(appModel.isGenerating)
                .help("Regenerate")
                .accessibilityLabel("Regenerate")

                Button {
                    appModel.continueGenerating(message)
                } label: {
                    Image(systemName: "arrow.forward.to.line")
                }
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(Theme.tertiaryText)
                .disabled(appModel.isGenerating)
                .help("Continue generating")
                .accessibilityLabel("Continue generating")
            }
            if !displayedMessage.content.isEmpty {
                Button {
                    appModel.toggleReadAloud(displayedMessage)
                } label: {
                    Image(systemName: appModel.speakingMessageID == displayedMessage.id ? "stop.circle" : "speaker.wave.2")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(appModel.speakingMessageID == displayedMessage.id ? Theme.accent : Theme.tertiaryText)
                .help(appModel.speakingMessageID == displayedMessage.id ? "Stop reading" : "Read aloud")
                .accessibilityLabel(appModel.speakingMessageID == displayedMessage.id ? "Stop reading" : "Read aloud")
                .animation(.easeOut(duration: 0.12), value: appModel.speakingMessageID)

                ShareButton(text: displayedMessage.content)
                    .frame(width: 14, height: 14)
                    .help("Share")
                    .accessibilityLabel("Share")
            }
        }
        .font(.caption)
    }
}

/// A real macOS share sheet (Mail, Messages, Notes, AirDrop, etc.) for the
/// message text — distinct from Copy, which just fills the pasteboard.
struct ShareButton: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSButton {
        // Matched to the sibling SwiftUI icon buttons in this row, which all
        // render at `.font(.caption)` — an AppKit NSButton doesn't inherit
        // that, so its symbol needs the same point size spelled out here.
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let button = NSButton(
            image: (NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share") ?? NSImage())
                .withSymbolConfiguration(symbolConfig) ?? NSImage(),
            target: context.coordinator,
            action: #selector(Coordinator.share)
        )
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .tertiaryLabelColor
        context.coordinator.button = button
        context.coordinator.text = text
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.text = text
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var text = ""
        weak var button: NSButton?

        @objc func share() {
            guard let button else { return }
            NSSharingServicePicker(items: [text]).show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }
}

/// An assistant reply rendered as its real timeline: text runs with dim
/// activity lines and reasoning woven between them exactly where the model
/// paused to act or to think — the Claude-web pattern. Messages from before
/// segments existed fall back to one plain text run.
struct AssistantTimeline: View {
    let message: ChatMessage

    /// Which inline reasoning blocks the reader has opened. Keyed by segment
    /// id so a message with several thinking runs tracks them independently.
    @State private var expandedReasoning: Set<UUID> = []

    private enum Item: Identifiable {
        case text(id: UUID, content: String)
        case reasoning(id: UUID, content: String)
        case activities([ActivityRecord])

        var id: UUID {
            switch self {
            case .text(let id, _): id
            case .reasoning(let id, _): id
            case .activities(let records): records.first?.id ?? UUID()
            }
        }
    }

    private var items: [Item] {
        guard !message.segments.isEmpty else {
            return message.content.isEmpty ? [] : [.text(id: message.id, content: message.content)]
        }
        var items: [Item] = []
        for segment in message.segments {
            switch segment {
            case .text(let id, let content):
                // Whitespace-only runs (blank lines between tool rounds)
                // are invisible — they must not break line aggregation.
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                items.append(.text(id: id, content: content))
            case .reasoning(let id, let content):
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                items.append(.reasoning(id: id, content: content))
            case .activity(let record):
                // Consecutive completed, successful calls aggregate into one
                // line; a running or failed call always stands alone.
                //
                // This aggregation is load-bearing, not cosmetic: a reply
                // that fetched thirty pages used to push thirty separate
                // "Read <url> — failed" rows through the transcript and then
                // collapse them all in one frame at the end — noise plus a
                // visible thirty-row jump on completion. The same rule runs
                // mid-stream and after, so collapsing happens continuously,
                // one call at a time: at most the single in-flight row is
                // ever extra, and the last one folding in when the reply
                // lands moves one row, not the whole stack. Any change here
                // has to keep that.
                if case .activities(let group) = items.last,
                   !record.isRunning, !record.isError,
                   group.allSatisfy({ !$0.isRunning && !$0.isError }) {
                    items[items.count - 1] = .activities(group + [record])
                } else {
                    items.append(.activities([record]))
                }
            }
        }
        return items
    }

    /// Live Markdown without re-parsing the world.
    ///
    /// Handing `Markdown(_:)` the whole growing reply on every reveal tick
    /// was the single biggest source of streaming lag, which is why the tail
    /// used to stay plain `Text` until the reply finished — and why simply
    /// deleting that guard is not the fix. Instead `StreamingMarkdown` peels
    /// off the blocks that can no longer change (everything before the last
    /// blank line outside an open code fence) and only those are parsed,
    /// once each, keyed by position so SwiftUI rebuilds just the block that
    /// newly completed. The still-typing fragment is the only plain `Text`
    /// left, so headings, lists, emphasis, and closed code fences format as
    /// they arrive and the finish-time swap is nearly invisible.
    @ViewBuilder
    private func textRun(_ content: String, isTail: Bool) -> some View {
        if message.isStreaming && isTail {
            let split = StreamingMarkdown.split(content)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(split.blocks.enumerated()), id: \.offset) { _, block in
                    RichMessageText(text: block, isUser: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !split.tail.isEmpty {
                    Text(split.tail)
                        .font(.body)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            RichMessageText(text: content, isUser: false)
        }
    }

    private func reasoningBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedReasoning.contains(id) },
            set: { isOpen in
                if isOpen { expandedReasoning.insert(id) } else { expandedReasoning.remove(id) }
            }
        )
    }

    var body: some View {
        // `items` is rendered in order, which is what `MessageSegment`'s own
        // documentation always promised and what the previous body threw
        // away: it built the interleaved sequence and then rendered one
        // summary activity line pinned above every text run. A reply that
        // searched, wrote a paragraph, then searched again showed both
        // searches above the paragraph — the transcript claimed an order of
        // events that never happened.
        let lastID = items.last?.id
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                switch item {
                case .text(_, let content):
                    textRun(content, isTail: item.id == lastID)
                case .reasoning(_, let content):
                    ReasoningDisclosure(
                        reasoning: content,
                        // Still thinking only while this run is the tail of a
                        // streaming message: the moment text or a tool call
                        // lands after it, the model has demonstrably moved
                        // on, so the timer settles to "Thought for Ns".
                        isThinking: message.isStreaming && item.id == lastID,
                        isExpanded: reasoningBinding(item.id)
                    )
                case .activities(let records):
                    ActivityLine(records: records)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: message.isStreaming)
    }
}

/// One dim, icon-led line — "Searching the web for 'X'" while running
/// (shimmering, never a spinner), a past-tense summary once done, counts
/// emphasized when several calls collapse into one line. Click to unfold
/// the real arguments and results in place.
struct ActivityLine: View {
    @Environment(ArtifactPresenter.self) private var artifactPresenter
    @Environment(AppModel.self) private var appModel
    let records: [ActivityRecord]
    @State private var isExpanded = false
    @State private var isHovering = false

    private var isRunning: Bool { records.contains { $0.isRunning } }

    private var label: String {
        guard records.count > 1 else {
            guard let record = records.first else { return "" }
            if record.isRunning { return record.kind.runningLabel(argument: record.argument) }
            // A single finished call can say how long it took, because both
            // ends of it were actually observed. A group can't — the calls
            // may not have been contiguous in time — so it says nothing
            // rather than implying a total nobody measured.
            let duration = record.durationLabel.map { " · \($0)" } ?? ""
            if record.isError { return record.kind.finishedLabel(argument: record.argument) + " — failed" + duration }
            return record.kind.finishedLabel(argument: record.argument) + duration
        }
        // Aggregate: counts per kind, in order of first appearance —
        // "Ran 3 web searches, read 2 pages".
        var orderedKinds: [ActivityKind] = []
        var counts: [ActivityKind: Int] = [:]
        for record in records {
            if counts[record.kind] == nil { orderedKinds.append(record.kind) }
            counts[record.kind, default: 0] += 1
        }
        var parts: [String] = []
        for (index, kind) in orderedKinds.enumerated() {
            var unit = kind.aggregateUnit(count: counts[kind] ?? 0)
            if index == 0, kind == .webSearch || kind == .conversationSearch || kind == .calculation || kind == .memory {
                unit = "Ran " + unit
            }
            parts.append(unit)
        }
        var sentence = parts.joined(separator: ", ")
        if let first = sentence.first {
            sentence = first.uppercased() + sentence.dropFirst()
        }
        return sentence
    }

    /// Digit runs render slightly brighter and semibold — the Claude Code
    /// aggregated-line look.
    private var emphasizedLabel: Text {
        var result = Text("")
        var run = ""
        var runIsDigit = false
        func flush() {
            guard !run.isEmpty else { return }
            if runIsDigit {
                let piece = Text(run).fontWeight(.semibold).foregroundStyle(Theme.secondaryText)
                result = Text("\(result)\(piece)")
            } else {
                result = Text("\(result)\(Text(run))")
            }
            run = ""
        }
        for character in label {
            let isDigit = character.isNumber
            if isDigit != runIsDigit { flush(); runIsDigit = isDigit }
            run.append(character)
        }
        flush()
        return result
    }

    private var symbol: String {
        records.first?.kind.symbol ?? "circle"
    }

    /// A few blocked pages inside an otherwise fine group shouldn't paint
    /// the whole line as an error — only an all-failed one does. (The
    /// aggregation rule means a group of more than one is always
    /// all-succeeded anyway; this stays honest if that ever loosens.)
    private var showsErrorTint: Bool {
        !records.isEmpty && records.allSatisfy(\.isError)
    }

    /// What VoiceOver reads for the whole row, including its state — the
    /// visual chevron carries the expandability and a shimmer carries the
    /// running state, neither of which is announced on its own.
    private var accessibilityDescription: String {
        if isRunning { return label }
        return "\(label), \(isExpanded ? "expanded" : "collapsed")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: showsErrorTint ? "exclamationmark.triangle" : symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(showsErrorTint ? Theme.danger.opacity(0.85) : Theme.tertiaryText)
                    .frame(width: 16)
                if isRunning {
                    ShimmerText(text: label, font: .callout)
                } else {
                    emphasizedLabel
                        .font(.callout)
                        .foregroundStyle(Theme.tertiaryText)
                }
                if !isRunning {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText.opacity(isHovering ? 0.9 : 0))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                // Without this the HStack sized to icon + label + chevron,
                // so `contentShape` covered only that: clicking anywhere to
                // the right of the text — most of the row — did nothing at
                // all, which read as a dead disclosure. The vertical padding
                // goes with it; a 16pt strip is not a comfortable target.
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isRunning else { return }
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityAddTraits(isRunning ? [] : .isButton)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            if !record.argument.isEmpty {
                                HStack(spacing: 8) {
                                    Text(record.kind.finishedLabel(argument: record.argument))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.secondaryText)
                                    // Files the model wrote or read open in
                                    // the inspector, rendered for real.
                                    if record.kind == .fileWrite || record.kind == .fileRead,
                                       !record.isError,
                                       let conversationID = appModel.activeConversationID {
                                        Button {
                                            artifactPresenter.openWorkspaceFile(conversationID: conversationID, relativePath: record.argument)
                                        } label: {
                                            Label("Open", systemImage: "sidebar.right")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Theme.accent)
                                    }
                                    // Only when both ends were observed.
                                    // A record from a transcript saved
                                    // before timestamps existed prints no
                                    // duration rather than "0.0s".
                                    if let duration = record.durationLabel {
                                        Text("· \(duration)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(Theme.tertiaryText)
                                    }
                                }
                            }
                            if !record.result.isEmpty {
                                Text(record.result)
                                    .font(.caption)
                                    .foregroundStyle(record.isError ? Theme.danger.opacity(0.85) : Theme.tertiaryText)
                                    .textSelection(.enabled)
                                    .lineLimit(14)
                            }
                        }
                    }
                }
                .padding(.leading, 24)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.separator.opacity(0.5))
                        .frame(width: 1)
                        .padding(.leading, 7)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct SearchResultsDisclosure: View {
    let record: WebSearchRecord
    @Binding var isExpanded: Bool

    var body: some View {
        ActivityRow(
            symbol: "globe",
            title: "Searched the web · \(record.results.count) source\(record.results.count == 1 ? "" : "s")",
            tint: Theme.accent,
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("“\(record.query)”")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                ForEach(record.results) { result in
                    // Search-result URLs are model/provider-supplied text —
                    // never force-unwrap them into URL(string:).
                    if let destination = URL(string: result.url) ?? URL(string: "https://\(result.url)") {
                        Link(destination: destination) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "link")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.tertiaryText)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.accent)
                                    .lineLimit(1)
                                Text(result.url)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.tertiaryText)
                                    .lineLimit(1)
                                if !result.snippet.isEmpty {
                                    Text(result.snippet)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceMid, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Reasoning presented as an activity step rather than a "Thinking summary"
/// box: a pulsing icon and live timer while it runs, a settled "Thought for
/// Ns" once it's done, and the raw chain kept behind a disclosure.
struct ReasoningDisclosure: View {
    let reasoning: String
    let isThinking: Bool
    @Binding var isExpanded: Bool
    @State private var startedAt: Date?
    @State private var elapsedWhenFinished: Int?

    var body: some View {
        // Only ticks while actually thinking — once it settles, the label is
        // a fixed string ("Thought for Ns" / "Reasoning") that never changes
        // again, so a periodic TimelineView left running for as long as the
        // message stays on screen was a permanent, pointless once-a-second
        // re-render for every reasoning-bearing message in the transcript.
        // `.onAppear`/`.onChange` sit on this outer `Group`, not inside the
        // conditional branch below, so they keep firing reliably across the
        // isThinking → false transition instead of being torn down with it.
        Group {
            if isThinking {
                TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
                    row(title: label(at: context.date))
                }
            } else {
                row(title: label(at: .now))
            }
        }
        .onAppear {
            if isThinking, startedAt == nil { startedAt = Date() }
        }
        .onChange(of: isThinking) { _, thinking in
            guard !thinking, elapsedWhenFinished == nil else { return }
            if let startedAt {
                elapsedWhenFinished = max(1, Int(Date().timeIntervalSince(startedAt)))
            }
            // Deliberately does NOT collapse here — snapping the disclosure
            // shut while the user reads along was the single most annoying
            // reasoning behavior in the app.
        }
    }

    private func row(title: String) -> some View {
        ActivityRow(
            // "thought.bubble", not "brain" — the brain glyph belongs to the
            // memory activity rows, and reading "memory" onto every reasoning
            // step conflated two different subsystems.
            symbol: "thought.bubble",
            title: title,
            tint: Theme.reasoningAccent,
            isActive: isThinking,
            isExpanded: $isExpanded
        ) {
            Text(reasoning)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(at now: Date) -> String {
        if isThinking {
            let elapsed = Int(now.timeIntervalSince(startedAt ?? now))
            return "Thinking… \(elapsed)s"
        }
        if let elapsedWhenFinished {
            return "Thought for \(elapsedWhenFinished)s"
        }
        return "Reasoning"
    }
}

struct AlternateStepper: View {
    @Binding var index: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            Button {
                index = min(index + 1, total - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index >= total - 1)

            Text("\(total - index)/\(total)")
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
                .monospacedDigit()

            Button {
                index = max(index - 1, 0)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index <= 0)
        }
        .buttonStyle(VelaIconButtonStyle())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.tertiaryText)
    }
}
