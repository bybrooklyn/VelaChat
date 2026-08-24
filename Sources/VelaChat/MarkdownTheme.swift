import SwiftUI
import VelaCore
import AppKit
import MarkdownUI
import HighlightSwift

/// Maps VelaChat's own `Theme` palette onto swift-markdown-ui's `Theme` type,
/// so rendered responses (tables, lists, code blocks, blockquotes) read as
/// part of the app rather than a generic document viewer dropped into it.
extension MarkdownUI.Theme {
    static func vela(isUser: Bool) -> MarkdownUI.Theme {
        let bodyColor = isUser ? Color.white : Theme.text
        let secondaryColor = isUser ? Color.white.opacity(0.75) : Theme.secondaryText

        return MarkdownUI.Theme()
            .text {
                ForegroundColor(bodyColor)
                FontSize(15)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                ForegroundColor(isUser ? Color.white : Theme.accent)
                BackgroundColor(isUser ? Color.white.opacity(0.15) : Theme.controlBackground)
            }
            .strong {
                FontWeight(.semibold)
            }
            .link {
                ForegroundColor(Theme.accent)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.4))
                    }
                    .markdownMargin(top: 12, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.25))
                    }
                    .markdownMargin(top: 12, bottom: 8)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.1))
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.22))
                    .markdownMargin(top: 0, bottom: 10)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(secondaryColor.opacity(0.4))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(secondaryColor) }
                        .relativePadding(.horizontal, length: .em(1))
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 0, bottom: 10)
            }
            .codeBlock { configuration in
                VelaCodeBlock(configuration: configuration, isUser: isUser)
            }
            .listItem { configuration in
                configuration.label.markdownMargin(top: .em(0.25))
            }
            .taskListMarker { configuration in
                Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent, secondaryColor.opacity(0.3))
                    .imageScale(.small)
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: secondaryColor.opacity(0.25)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(Color.clear, secondaryColor.opacity(0.06))
                    )
                    .markdownMargin(top: 0, bottom: 10)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 { FontWeight(.semibold) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
            }
            .thematicBreak {
                Divider()
                    .overlay(secondaryColor.opacity(0.3))
                    .markdownMargin(top: 12, bottom: 12)
            }
    }
}

private struct VelaCodeBlock: View {
    let configuration: CodeBlockConfiguration
    let isUser: Bool
    @Environment(ArtifactPresenter.self) private var artifactPresenter
    @Environment(AppModel.self) private var appModel
    @State private var copied = false
    @State private var savedFilename: String?

    /// A plausible filename for the block, from its language. Code the
    /// model wrote in chat is often worth keeping without asking it to
    /// write the file again.
    private var suggestedFilename: String {
        let language = configuration.language?.lowercased() ?? ""
        let extensions = [
            "swift": "swift", "python": "py", "py": "py", "javascript": "js", "js": "js",
            "typescript": "ts", "ts": "ts", "bash": "sh", "sh": "sh", "zsh": "sh",
            "ruby": "rb", "go": "go", "rust": "rs", "rs": "rs", "java": "java",
            "c": "c", "cpp": "cpp", "html": "html", "css": "css", "json": "json",
            "yaml": "yml", "yml": "yml", "sql": "sql", "markdown": "md", "md": "md",
        ]
        let ext = extensions[language] ?? "txt"
        let stamp = Int(Date().timeIntervalSince1970) % 100_000
        return "snippet-\(stamp).\(ext)"
    }

    private var languageLabel: String {
        guard let language = configuration.language, !language.isEmpty else { return "Code" }
        return language.capitalized
    }

    /// Artifact-worthy: a real HTML/SVG/Mermaid fence past a length where a
    /// live preview is actually more useful than reading the source — not
    /// a new convention taught to the model, since it already writes these
    /// tags unprompted whenever asked for a webpage/diagram/vector graphic.
    private var artifactKind: Artifact.Kind? {
        guard let language = configuration.language?.lowercased(), !language.isEmpty else { return nil }
        switch language {
        case "html" where configuration.content.count > 120: return .html
        case "svg" where configuration.content.count > 120: return .svg
        case "mermaid" where configuration.content.count > 120: return .mermaid
        // Any sizeable markdown or code block opens in the inspector with
        // real rendering/highlighting.
        case "markdown", "md":
            return configuration.content.count > 400 ? .markdown : nil
        default:
            return configuration.content.count > 400 ? .code(language: language) : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(languageLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                if let artifactKind {
                    Button {
                        artifactPresenter.open(kind: artifactKind, content: configuration.content, title: artifactKind.displayName)
                    } label: {
                        Label("Open in Inspector", systemImage: "sidebar.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
                // Not every snippet belongs in a file, so the model is told
                // to keep short one-off code in chat — this is how the user
                // promotes one when they decide it's worth keeping.
                Button {
                    savedFilename = appModel.saveSnippetToWorkspace(
                        configuration.content,
                        filename: suggestedFilename
                    )
                    if savedFilename != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { savedFilename = nil }
                    }
                } label: {
                    Label(savedFilename.map { "Saved \($0)" } ?? "Save", systemImage: savedFilename == nil ? "folder.badge.plus" : "checkmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(savedFilename == nil ? Theme.tertiaryText : Theme.success)
                .help("Save this block into the conversation's workspace")
                .accessibilityLabel("Save this block into the conversation's workspace")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configuration.content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Theme.success : Theme.tertiaryText)
                .help(copied ? "Copied" : "Copy code")
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // A real header strip — darker fill + hairline — instead of
            // labels floating inside the block.
            .background(Theme.background.opacity(0.45))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.controlStroke.opacity(0.5))
                    .frame(height: 1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                CodeText(configuration.content)
                    .codeTextStyle(.plain)
                    .codeTextColors(.theme(.xcode))
                    .highlightMode(configuration.language.map { .languageAlias($0) } ?? .automatic)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous), emphasis: 0.5)
        .markdownMargin(top: 4, bottom: 10)
    }
}
