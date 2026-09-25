import SwiftUI
import VelaCore
import WebKit

/// HTML/SVG/Mermaid code blocks the model writes become real, live-rendered
/// artifacts in a side panel — the same idea as Claude web's artifacts,
/// scoped to what's actually buildable in one pass: live preview + copy +
/// download for these three renderable types. Detection is automatic
/// (any fenced block tagged `html`/`svg`/`mermaid` past a minimum length
/// gets the "Open in Artifact" affordance — see `VelaCodeBlock`,
/// MarkdownTheme.swift) rather than a new convention taught to the model,
/// since models already naturally use these language tags unprompted.
/// Version history and diffing are NOT built — there's no reliable way to
/// know two artifacts across different messages are "the same" one without
/// the model explicitly signaling that, which isn't attempted here.
struct Artifact: Identifiable, Equatable {
    enum Kind: Equatable {
        case html, svg, mermaid
        case markdown
        case code(language: String?)

        var displayName: String {
            switch self {
            case .html: "HTML"
            case .svg: "SVG"
            case .mermaid: "Diagram"
            case .markdown: "Markdown"
            case .code(let language): language?.capitalized ?? "Code"
            }
        }

        var fileExtension: String {
            switch self {
            case .html: "html"
            case .svg: "svg"
            case .mermaid: "mmd"
            case .markdown: "md"
            case .code(let language): language ?? "txt"
            }
        }

        /// Rendered natively (MarkdownUI / HighlightSwift) — no WKWebView.
        var rendersNatively: Bool {
            switch self {
            case .markdown, .code: true
            default: false
            }
        }

        static func from(fileExtension ext: String) -> Kind {
            switch ext.lowercased() {
            case "html", "htm": .html
            case "svg": .svg
            case "mmd", "mermaid": .mermaid
            case "md", "markdown": .markdown
            case "txt", "": .code(language: nil)
            default: .code(language: ext.lowercased())
            }
        }
    }

    /// Where the content came from — workspace files are editable and
    /// savable back to disk; chat blocks are read-only views of the
    /// message text.
    enum Source: Equatable {
        case chat
        /// The resolved URL travels with the artifact rather than being
        /// rebuilt from a conversation id on save: a conversation with an
        /// attached project folder does not live under the sandbox
        /// directory, and rebuilding the path from the id alone wrote to
        /// (or failed to find) the wrong place.
        case workspaceFile(url: URL, relativePath: String)
    }

    let id = UUID()
    let kind: Kind
    var title: String
    var content: String
    var source: Source = .chat

    static func == (lhs: Artifact, rhs: Artifact) -> Bool { lhs.id == rhs.id }

    /// Self-contained HTML the preview `WKWebView` actually loads — SVG and
    /// raw HTML render as-is; Mermaid source gets wrapped with mermaid.js
    /// (loaded from its own CDN, not bundled — simpler and lower-risk than
    /// shipping a vendored copy of the library for this one preview case).
    var previewHTML: String {
        switch kind {
        case .markdown, .code:
            return ""  // rendered natively, never loaded into a web view
        case .html:
            return content
        case .svg:
            return "<!doctype html><html><head><meta charset=\"utf-8\"><style>body{margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#fff}</style></head><body>\(content)</body></html>"
        case .mermaid:
            let escaped = content
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            // Mermaid is the one artifact kind with an external network
            // dependency (mermaid.js from a CDN, not bundled). A script-tag
            // fetch failure never reaches WKNavigationDelegate — that only
            // sees the top-level `loadHTMLString` navigation, which always
            // "succeeds" regardless of a subresource failing — so without
            // this, an unreachable CDN just showed a blank white panel with
            // no explanation. `onerror` plus a `window.load` fallback check
            // (for failures that don't trigger `onerror`, e.g. some CORS
            // cases) both funnel into the same visible status message.
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <style>
              body{margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#fff;font-family:-apple-system}
              #vela-status{color:#888;font-size:14px;text-align:center;padding:20px}
            </style>
            </head><body>
            <div id="vela-status">Loading diagram…</div>
            <pre class="mermaid" style="display:none">\(escaped)</pre>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"
                    onerror="document.getElementById('vela-status').textContent='Couldn\\'t load the diagram renderer — check your internet connection.'"></script>
            <script>
              window.addEventListener('load', function() {
                var status = document.getElementById('vela-status');
                if (typeof mermaid === 'undefined') {
                  status.textContent = "Couldn't load the diagram renderer — check your internet connection.";
                  return;
                }
                status.style.display = 'none';
                document.querySelector('pre.mermaid').style.display = 'block';
                mermaid.initialize({startOnLoad:true});
              });
            </script>
            </body></html>
            """
        }
    }
}

/// Injected once at the top of the view hierarchy (`VelaChatApp.swift`) so
/// any nested view — including `VelaCodeBlock`, deep inside the Markdown
/// rendering tree — can open an artifact without threading a binding
/// through every intermediate view.
@MainActor
@Observable
final class ArtifactPresenter {
    var activeArtifact: Artifact?

    func open(kind: Artifact.Kind, content: String, title: String) {
        activeArtifact = Artifact(kind: kind, title: title, content: content)
    }

    /// Opens a file the model produced.
    ///
    /// Two outcomes, because a workspace now holds two kinds of file: text
    /// renders in the inspector (and can be edited and saved back), while
    /// a real .xlsx/.docx/.pptx/.pdf goes to whichever app owns that
    /// format. The previous version read UTF-8 or gave up silently, so
    /// clicking a generated spreadsheet did nothing at all — no panel, no
    /// error, no hint that anything had been asked of it.
    ///
    /// `root` is the conversation's `workspaceRoot`, which already resolves
    /// an attached project folder; it is not rebuilt from the id here.
    @discardableResult
    func openWorkspaceFile(named relativePath: String, in root: URL) -> Bool {
        guard let url = SandboxManager.resolve(relativePath, in: root),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        // Huge text files open externally rather than stalling the panel:
        // a 50 MB model-written log is real, and no one reads it in a
        // side panel anyway.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
           size > Limits.artifactMaxPanelBytes {
            return NSWorkspace.shared.open(url)
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            activeArtifact = Artifact(
                kind: .from(fileExtension: (relativePath as NSString).pathExtension),
                title: (relativePath as NSString).lastPathComponent,
                content: text,
                source: .workspaceFile(url: url, relativePath: relativePath)
            )
            return true
        }
        return NSWorkspace.shared.open(url)
    }

    /// Shows the file in Finder — the escape hatch for anything the panel
    /// can't render and no app claims.
    func revealInFinder(named relativePath: String, in root: URL) {
        guard let url = SandboxManager.resolve(relativePath, in: root) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Saves edited content back to a workspace file. Returns an error
    /// message, or nil on success. Chat-sourced artifacts have no file.
    func save(_ artifact: Artifact, content: String) -> String? {
        guard case .workspaceFile(let url, _) = artifact.source else {
            return "This artifact isn't a workspace file."
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            if activeArtifact?.id == artifact.id {
                activeArtifact?.content = content
            }
            return nil
        } catch {
            return "Couldn't save: \(error.localizedDescription)"
        }
    }

    func close() {
        activeArtifact = nil
    }
}

/// A minimal `WKWebView` wrapper with two deliberate properties:
///
/// - The load is skipped when neither the HTML nor the reload token
///   changed. SwiftUI calls `updateNSView` on any state change anywhere
///   near the panel, and a bare `loadHTMLString` on every pass reset
///   scroll position, re-ran scripts, and re-fetched the mermaid CDN.
/// - There is intentionally no navigation delegate and no content
///   blocking: artifact HTML is model-authored content the user asked to
///   preview, rendered as-is. The one network dependency is mermaid.js
///   from its CDN (see `previewHTML`); everything else is local.
struct ArtifactWebView: NSViewRepresentable {
    let html: String
    /// Bumped by the panel's Reload button for CDN failures and stale
    /// script state. Part of the load identity, not the content.
    let reloadToken: Int

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html || context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastHTML = html
        context.coordinator.lastToken = reloadToken
        nsView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var lastHTML: String?
        var lastToken: Int = -1
    }
}
