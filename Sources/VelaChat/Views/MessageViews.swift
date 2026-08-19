import SwiftUI
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
                        PlanCard(steps: steps, isWorking: message.isStreaming)
                    }

                    if alternateIndex == 0, let recalled = appModel.recallByMessage[message.id], !recalled.isEmpty {
                        RecallLine(recalls: recalled)
                    }

                    if let reasoning = displayedMessage.reasoning, !reasoning.isEmpty {
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
                                let cost = summary.costUSD(for: appModel.providers.modelInfo(
                                    for: costProviderID,
                                    model: displayedMessage.modelID ?? ""
                                ))
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
/// activity lines woven between them exactly where the model paused to act
/// — the Claude-web pattern. Messages from before segments existed fall
/// back to one plain text run.
struct AssistantTimeline: View {
    let message: ChatMessage

    private enum Item: Identifiable {
        case text(id: UUID, content: String)
        case activities([ActivityRecord])

        var id: UUID {
            switch self {
            case .text(let id, _): id
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
            case .activity(let record):
                // Consecutive completed, successful calls aggregate into one
                // line; a running or failed call always stands alone.
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

    private var allActivities: [ActivityRecord] {
        message.segments.compactMap {
            if case .activity(let record) = $0 { return record }
            return nil
        }
    }

    /// Markdown parsing of the whole growing reply on every reveal tick was
    /// the single biggest source of streaming lag — the still-growing tail
    /// renders as plain text and becomes real Markdown when the reply
    /// finishes.
    @ViewBuilder
    private func textRun(_ content: String, isTail: Bool) -> some View {
        if message.isStreaming && isTail {
            Text(content)
                .font(.body)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            RichMessageText(text: content, isUser: false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.isStreaming, !allActivities.isEmpty {
                // Finished: the whole streamed stack settles into one dim
                // summary line on top — the response owns the screen, the
                // full per-call record stays one click away.
                ActivityLine(records: allActivities, style: .summary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                ForEach(items) { item in
                    if case .text(_, let content) = item {
                        RichMessageText(text: content, isUser: false)
                    }
                }
            } else {
                let lastID = items.last?.id
                ForEach(items) { item in
                    switch item {
                    case .text(_, let content):
                        textRun(content, isTail: item.id == lastID)
                    case .activities(let records):
                        ActivityLine(records: records)
                    }
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
    enum Style { case interleaved, summary }

    @Environment(ArtifactPresenter.self) private var artifactPresenter
    @Environment(AppModel.self) private var appModel
    let records: [ActivityRecord]
    var style: Style = .interleaved
    @State private var isExpanded = false
    @State private var isHovering = false

    private var isRunning: Bool { records.contains { $0.isRunning } }
    private var isError: Bool { records.contains { $0.isError } }

    private var label: String {
        if style == .summary { return summaryLabel }
        guard records.count > 1 else {
            guard let record = records.first else { return "" }
            if record.isRunning { return record.kind.runningLabel(argument: record.argument) }
            if record.isError { return record.kind.finishedLabel(argument: record.argument) + " — failed" }
            return record.kind.finishedLabel(argument: record.argument)
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

    /// The one-line settle of a finished reply's whole activity stack:
    /// successes aggregated per kind, failures counted as "blocked" —
    /// "Browsed the web · read 2 pages, 8 blocked".
    private var summaryLabel: String {
        let succeeded = records.filter { !$0.isError && !$0.isRunning }
        let failed = records.filter { $0.isError }
        guard records.count > 1 else {
            guard let record = records.first else { return "" }
            if record.isError { return record.kind.finishedLabel(argument: record.argument) + " — failed" }
            return record.kind.finishedLabel(argument: record.argument)
        }
        var orderedKinds: [ActivityKind] = []
        var counts: [ActivityKind: Int] = [:]
        for record in succeeded {
            if counts[record.kind] == nil { orderedKinds.append(record.kind) }
            counts[record.kind, default: 0] += 1
        }
        var parts = orderedKinds.map { ($0, counts[$0] ?? 0) }.map { $0.0.aggregateUnit(count: $0.1) }
        if !failed.isEmpty {
            parts.append("\(failed.count) blocked")
        }
        let browsed = records.contains { $0.kind == .webSearch || $0.kind == .fetchURL }
        var sentence = parts.joined(separator: ", ")
        if browsed {
            sentence = "Browsed the web · " + sentence
        } else if let first = sentence.first {
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
        if style == .summary, records.contains(where: { $0.kind == .webSearch || $0.kind == .fetchURL }) {
            return "globe"
        }
        return records.first?.kind.symbol ?? "circle"
    }

    /// In summary style a few blocked pages shouldn't paint the whole line
    /// as an error — only an all-failed stack does.
    private var showsErrorTint: Bool {
        style == .summary ? records.allSatisfy(\.isError) : isError
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
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isRunning else { return }
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)

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
            symbol: "brain",
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
