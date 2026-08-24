import SwiftUI
import VelaCore
import WebKit

/// The ChatGPT provider's editor section: session status, sign-in, and
/// sign-out. Cookie import from an already-signed-in browser is the
/// PRIMARY path — Google refuses OAuth inside any embedded web view ("this
/// browser or app may not be secure"), so a large share of accounts can
/// never complete the embedded flow at all. The embedded WebKit window
/// remains as a secondary option for password/email logins, and pasting a
/// session token is the manual fallback.
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
        SettingsPanel(title: "ChatGPT Account", symbol: "person.crop.circle") {
            if appModel.providers.chatGPTSessionPresent {
                Label(statusText ?? "Signed in", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("Sign in with your ChatGPT account — models, reasoning levels, and plan usage come straight from it. No API key involved.")
                    .foregroundStyle(Theme.secondaryText)
            }

            // The primary path: read the session out of a browser the user
            // is already logged into. Works for every account shape,
            // including the Google-linked ones the embedded window cannot
            // serve.
            if !browsers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appModel.providers.chatGPTSessionPresent ? "Import again from a browser" : "Import from a browser you're signed into")
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 8) {
                        ForEach(browsers) { browser in
                            Button(browser.name) { importSession(from: browser) }
                                .buttonStyle(SettingsPrimaryButtonStyle())
                        }
                    }
                    Text("Log in to chatgpt.com there first if needed. Google blocks sign-in inside embedded windows, so this is the path that works for every account.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }

            HStack(spacing: 10) {
                Button(appModel.providers.chatGPTSessionPresent ? "Sign In Again…" : "Sign In to ChatGPT…") {
                    isLoginShown = true
                }
                .buttonStyle(VelaIconButtonStyle())
                .foregroundStyle(browsers.isEmpty ? Theme.accent : Theme.secondaryText)
                if appModel.providers.chatGPTSessionPresent {
                    Button("Sign Out") {
                        Task {
                            await ChatGPTWebClient.shared.signOut()
                            appModel.providers.chatGPTSessionPresent = false
                            statusText = nil
                        }
                    }
                    .buttonStyle(SettingsDestructiveButtonStyle())
                }
                if isWorking {
                    ShimmerText(text: "Checking session…", font: .callout)
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
            if browsers.isEmpty {
                Text("No supported browsers were found for import — use the sign-in window above, or paste a token below.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
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
                .background(Theme.surfaceMid, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
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
