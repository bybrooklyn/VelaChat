import SwiftUI
import WebKit

/// The ChatGPT provider's editor section: session status, a real
/// login window, and sign-out. The login is an embedded WebKit view on
/// chatgpt.com — a genuine browser context, so Cloudflare and the
/// normal login flow just work; the session cookies are then read from
/// the web view's own cookie store and validated before anything is
/// persisted. No JavaScript injection, no password handling.
struct ChatGPTLoginSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var isLoginShown = false
    @State private var statusText: String?
    @State private var isWorking = false
    @State private var importMessage: String?
    @State private var isPasteShown = false
    @State private var pastedToken = ""

    private var browsers: [BrowserCookieImport.Browser] { BrowserCookieImport.availableBrowsers() }

    var body: some View {
        Section("ChatGPT account") {
            if appModel.providers.chatGPTSessionPresent {
                Label(statusText ?? "Signed in", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("Sign in with your ChatGPT account — models, reasoning levels, and plan usage come straight from it. No API key involved.")
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 10) {
                Button(appModel.providers.chatGPTSessionPresent ? "Sign In Again…" : "Sign In to ChatGPT…") {
                    isLoginShown = true
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                if appModel.providers.chatGPTSessionPresent {
                    Button("Sign Out", role: .destructive) {
                        Task {
                            await ChatGPTWebClient.shared.signOut()
                            appModel.providers.chatGPTSessionPresent = false
                            statusText = nil
                        }
                    }
                    .buttonStyle(.bordered)
                }
                if isWorking {
                    ShimmerText(text: "Checking session…", font: .callout)
                }
            }

            // Google refuses to authenticate inside any embedded web view,
            // so a Google-linked account can never sign in through the
            // window above. Importing the session from a browser you're
            // already logged into is the way in.
            if !browsers.isEmpty {
                LabeledContent("Import from a browser") {
                    HStack(spacing: 8) {
                        ForEach(browsers) { browser in
                            Button(browser.name) { importSession(from: browser) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            Button("Paste a session token instead…") { isPasteShown = true }
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(Theme.accent)
            if let importMessage {
                Text(importMessage)
                    .font(.caption)
                    .foregroundStyle(importMessage.hasPrefix("Signed in") ? Theme.success : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Signing in with Google only works in a real browser — Google blocks embedded windows. Log in to chatgpt.com there, then use Import above.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .sheet(isPresented: $isPasteShown) {
            ChatGPTTokenPasteSheet(token: $pastedToken) { value in
                isPasteShown = false
                adopt(cookieHeader: value, source: "the pasted token")
            } onCancel: {
                isPasteShown = false
            }
        }
        .task { await refreshStatus() }
        .sheet(isPresented: $isLoginShown) {
            ChatGPTLoginSheet { info in
                appModel.providers.chatGPTSessionPresent = true
                statusText = Self.label(for: info)
                isLoginShown = false
                Task { await appModel.providers.refreshModels(id: appModel.providers.profiles.first(where: { $0.kind == .chatGPT })?.id ?? UUID()) }
            } onCancel: {
                isLoginShown = false
            }
        }
    }

    private static func label(for info: ChatGPTWebClient.SessionInfo) -> String {
        var parts: [String] = ["Signed in"]
        if let account = info.accountLabel { parts.append(account) }
        if let plan = info.planName { parts.append("\(plan) plan") }
        return parts.joined(separator: " · ")
    }

    private func importSession(from browser: BrowserCookieImport.Browser) {
        importMessage = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let header = try BrowserCookieImport.cookieHeader(from: browser)
                await ChatGPTWebClient.shared.rememberImportSource(browser.name)
                adopt(cookieHeader: header, source: browser.name)
            } catch {
                importMessage = error.localizedDescription
            }
        }
    }

    /// Every path (web view, import, paste) lands here: the session is
    /// validated against the real endpoint before anything is stored, so a
    /// stale or wrong cookie fails loudly instead of half-working later.
    private func adopt(cookieHeader: String, source: String) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let info = try await ChatGPTWebClient.shared.adoptCookies(cookieHeader)
                await ChatGPTWebClient.shared.startKeepAlive()
                appModel.providers.chatGPTSessionPresent = true
                statusText = Self.label(for: info)
                importMessage = "Signed in using \(source)."
                if let id = appModel.providers.profiles.first(where: { $0.kind == .chatGPT })?.id {
                    await appModel.providers.refreshModels(id: id)
                }
            } catch {
                importMessage = "That session didn't validate: \(error.localizedDescription)"
            }
        }
    }

    private func refreshStatus() async {
        guard appModel.providers.chatGPTSessionPresent else { return }
        isWorking = true
        defer { isWorking = false }
        let info = await ChatGPTWebClient.shared.sessionInfo()
        if info.accountLabel != nil || info.planName != nil {
            statusText = Self.label(for: info)
        }
    }
}

/// Manual escape hatch: paste either a whole Cookie header or just the
/// session token. Accepting both means the user can copy whatever their
/// browser's dev tools made easy to copy.
private struct ChatGPTTokenPasteSheet: View {
    @Binding var token: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    private var normalized: String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // A bare token gets wrapped into the cookie the backend expects;
        // anything already in name=value form is passed through.
        return trimmed.contains("=") ? trimmed : "__Secure-next-auth.session-token=\(trimmed)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste a ChatGPT session")
                .font(.title3.weight(.semibold))
            Text("In a browser where you're logged in to chatgpt.com, open the developer tools, find the cookie named __Secure-next-auth.session-token, and paste its value here. Pasting the entire Cookie header works too.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $token)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .background(Theme.controlBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Use Session") { onSubmit(normalized) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(normalized.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// The embedded login window. Watches the cookie store after every
/// navigation; the moment a ChatGPT session cookie exists, the whole
/// chatgpt.com cookie set is captured, validated with a real session
/// refresh, and adopted. Cancel closes without touching anything.
struct ChatGPTLoginSheet: View {
    let onSuccess: (ChatGPTWebClient.SessionInfo) -> Void
    let onCancel: () -> Void
    @State private var statusMessage = "Log in exactly as you would in a browser."
    @State private var isAdopting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to ChatGPT")
                    .font(.headline)
                Spacer()
                if isAdopting {
                    ShimmerText(text: "Validating session…", font: .callout)
                }
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ChatGPTLoginWebView { cookieHeader in
                guard !isAdopting else { return }
                isAdopting = true
                Task {
                    do {
                        let info = try await ChatGPTWebClient.shared.adoptCookies(cookieHeader)
                        onSuccess(info)
                    } catch {
                        isAdopting = false
                        statusMessage = "That session didn't validate — finish logging in, then it retries automatically."
                    }
                }
            }
            Divider()
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .padding(8)
        }
        .frame(width: 860, height: 640)
    }
}

private struct ChatGPTLoginWebView: NSViewRepresentable {
    /// Called with a full "name=value; …" cookie header once a ChatGPT
    /// session cookie is present. May fire more than once — the caller
    /// de-duplicates.
    let onSessionCookies: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The default (persistent) store: Cloudflare clearance and the
        // login survive closing the sheet, so a re-login is instant.
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = ChatGPTWebClient.userAgent
        context.coordinator.webView = webView
        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSessionCookies: onSessionCookies)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSessionCookies: (String) -> Void
        weak var webView: WKWebView?
        private var pollTask: Task<Void, Never>?

        init(onSessionCookies: @escaping (String) -> Void) {
            self.onSessionCookies = onSessionCookies
        }

        deinit { pollTask?.cancel() }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkForSession()
            // The session cookie can also appear from in-page auth
            // without a full navigation — poll gently while the sheet
            // is open.
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                for _ in 0..<60 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.checkForSession()
                }
            }
        }

        private func checkForSession() {
            guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
            store.getAllCookies { [weak self] cookies in
                let relevant = cookies.filter { cookie in
                    cookie.domain.contains("chatgpt.com") || cookie.domain.contains("openai.com")
                }
                let hasSession = relevant.contains { cookie in
                    cookie.name == "__Secure-next-auth.session-token"
                        || cookie.name == "__Secure-authjs.session-token"
                        || cookie.name.hasPrefix("__Secure-next-auth.session-token.")
                }
                guard hasSession else { return }
                let header = relevant
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                self?.onSessionCookies(header)
            }
        }
    }
}
