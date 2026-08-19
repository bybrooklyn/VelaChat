import SwiftUI
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
        case workspaceFile(conversationID: UUID, relativePath: String)
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

    /// Opens a file the model wrote into the conversation's private
    /// workspace — the inspector renders it by extension and can save
    /// edits back to the same path.
    func openWorkspaceFile(conversationID: UUID, relativePath: String) {
        let directory = SandboxManager.directory(for: conversationID)
        guard let url = SandboxManager.resolve(relativePath, in: directory),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let ext = (relativePath as NSString).pathExtension
        activeArtifact = Artifact(
            kind: .from(fileExtension: ext),
            title: (relativePath as NSString).lastPathComponent,
            content: text,
            source: .workspaceFile(conversationID: conversationID, relativePath: relativePath)
        )
    }

    /// Saves edited content back to a workspace file. Returns an error
    /// message, or nil on success. Chat-sourced artifacts have no file.
    func save(_ artifact: Artifact, content: String) -> String? {
        guard case .workspaceFile(let conversationID, let relativePath) = artifact.source else {
            return "This artifact isn't a workspace file."
        }
        let directory = SandboxManager.directory(for: conversationID)
        guard let url = SandboxManager.resolve(relativePath, in: directory) else {
            return "The file's path is no longer valid."
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

/// A minimal `WKWebView` wrapper — no navigation delegate needed since
/// artifacts never link anywhere themselves, just `loadHTMLString` once
/// per artifact.
struct ArtifactWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(html, baseURL: nil)
    }
}
