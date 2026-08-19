import Foundation

/// Scoped Swift port of the `chatgpt-web-runtime` direct transport
/// (reference: ~/data/chatgpt-web-runtime-v0.9.0, docs/SWIFT_PORT.md).
/// Only what VelaChat needs: session auth, model discovery with
/// reasoning efforts, usage/entitlement probes, and (in ChatGPTWebChat)
/// streaming conversation turns. Every endpoint and header here was
/// read out of the reference implementation, not guessed.
///
/// ChatGPT Web is a private protocol surface — this client degrades
/// loudly (typed errors, challenge detection) rather than pretending
/// it is stable.
actor ChatGPTWebClient {
    static let shared = ChatGPTWebClient()

    struct SessionInfo: Sendable {
        var accountLabel: String?
        var accountID: String?
        var planName: String?
    }

    enum ClientError: LocalizedError {
        case notAuthenticated
        /// Cloudflare / proof-of-work sentinel — a browserless client
        /// cannot solve these; the login window can.
        case challenge
        case http(Int, String)
        case badPayload(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                "ChatGPT is not signed in. Open the ChatGPT provider in Settings and sign in."
            case .challenge:
                "ChatGPT presented a verification challenge. Open the ChatGPT provider in Settings and sign in again through the login window."
            case .http(let status, let message):
                "ChatGPT request failed (HTTP \(status)): \(message)"
            case .badPayload(let message):
                "ChatGPT returned an unexpected response: \(message)"
            }
        }
    }

    private let baseURL = URL(string: "https://chatgpt.com")!
    private static let cookieAccount = "chatgpt-web-cookie"
    /// Mirrors the reference default — a stable, ordinary browser UA.
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"

    private var cookie: String?
    private var accessToken: String?
    private var tokenExpiresAt: Date?
    private(set) var accountID: String?
    private(set) var accountLabel: String?
    private(set) var planName: String?
    private var refreshTask: Task<String, Error>?
    private var keepAliveTask: Task<Void, Never>?
    private var modelCache: (at: Date, models: [RemoteModel])?
    /// Stable non-secret device identifier — the reference explicitly
    /// warns against generating a fresh one per launch.
    private let deviceID: String

    init() {
        cookie = SecureStore.value(for: Self.cookieAccount)
        if let existing = UserDefaults.standard.string(forKey: "velachat.chatgpt-device-id") {
            deviceID = existing
        } else {
            let fresh = UUID().uuidString.lowercased()
            UserDefaults.standard.set(fresh, forKey: "velachat.chatgpt-device-id")
            deviceID = fresh
        }
    }

    var isConfigured: Bool { cookie != nil }

    /// Synchronous session-presence check for UI caches (primed once per
    /// launch, never per-render — Keychain reads can block).
    nonisolated static var hasStoredSession: Bool {
        SecureStore.value(for: cookieAccount) != nil
    }

    func sessionInfo() -> SessionInfo {
        SessionInfo(accountLabel: accountLabel, accountID: accountID, planName: planName)
    }

    func signOut() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        importedBrowserName = nil
        cookie = nil
        accessToken = nil
        tokenExpiresAt = nil
        accountID = nil
        accountLabel = nil
        planName = nil
        modelCache = nil
        SecureStore.set(nil, for: Self.cookieAccount)
    }

    /// Adopt a cookie-header string captured from the login web view.
    /// Validates by performing a real session refresh; persists only on
    /// success.
    func adoptCookies(_ cookieHeader: String) async throws -> SessionInfo {
        let trimmed = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.notAuthenticated }
        cookie = trimmed
        accessToken = nil
        tokenExpiresAt = nil
        _ = try await refreshAccessToken()
        SecureStore.set(trimmed, for: Self.cookieAccount)
        return sessionInfo()
    }

    // MARK: - Auth

    /// GET /api/auth/session with cookie + UA + device id →
    /// { accessToken, expires, user{email,name}, account_id? }.
    /// Single-flight: concurrent callers share one refresh.
    private func refreshAccessToken() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        guard let cookie else { throw ClientError.notAuthenticated }
        let task = Task<String, Error> {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/session"))
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(deviceID, forHTTPHeaderField: "oai-device-id")
            // URLSession shares cookies by default; this must send exactly
            // the captured session, nothing else.
            request.httpShouldHandleCookies = false
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClientError.badPayload("no HTTP response") }
            if Self.looksLikeChallenge(http, data: data) { throw ClientError.challenge }
            guard http.statusCode == 200,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClientError.http(http.statusCode, "session refresh rejected")
            }
            guard let token = (payload["accessToken"] ?? payload["access_token"]) as? String, !token.isEmpty else {
                // A 200 with no token means the cookie no longer maps to a
                // logged-in session.
                throw ClientError.notAuthenticated
            }
            return try self.applySession(payload: payload, token: token)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func applySession(payload: [String: Any], token: String) throws -> String {
        accessToken = token
        if let expires = payload["expires"] as? String,
           let date = ISO8601DateFormatter().date(from: expires) {
            tokenExpiresAt = date
        } else {
            tokenExpiresAt = Date().addingTimeInterval(30 * 60)
        }
        if let user = payload["user"] as? [String: Any] {
            accountLabel = (user["email"] as? String) ?? (user["name"] as? String) ?? accountLabel
        }
        accountID = (payload["accountId"] as? String) ?? (payload["account_id"] as? String) ?? accountID
        return token
    }

    private func ensureAccessToken() async throws -> String {
        if let accessToken, let tokenExpiresAt, tokenExpiresAt.timeIntervalSinceNow > 60 {
            return accessToken
        }
        return try await refreshAccessToken()
    }

    private static func looksLikeChallenge(_ response: HTTPURLResponse, data: Data) -> Bool {
        if response.value(forHTTPHeaderField: "cf-mitigated") != nil { return true }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if response.statusCode == 403 && contentType.contains("text/html") { return true }
        return false
    }

    /// Which browser the session was imported from, so a rotated cookie
    /// can be picked up again without asking.
    private var importedBrowserName: String? {
        get { UserDefaults.standard.string(forKey: "velachat.chatgpt-import-browser") }
        set { UserDefaults.standard.set(newValue, forKey: "velachat.chatgpt-import-browser") }
    }

    func rememberImportSource(_ name: String) {
        importedBrowserName = name
    }

    private func reimportFromBrowser() async {
        guard let name = importedBrowserName,
              let browser = BrowserCookieImport.availableBrowsers().first(where: { $0.name == name }),
              let header = try? BrowserCookieImport.cookieHeader(from: browser),
              header != cookie else { return }
        cookie = header
        accessToken = nil
        tokenExpiresAt = nil
        SecureStore.set(header, for: Self.cookieAccount)
    }

    /// Periodic refresh so a session rarely expires mid-conversation. Cheap
    /// (one session endpoint call), and silent when it fails — the request
    /// path still recovers on its own.
    func startKeepAlive() {
        guard keepAliveTask == nil, cookie != nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20 * 60 * 1_000_000_000)
                guard let self, await self.isConfigured else { return }
                _ = try? await self.refreshAccessToken()
            }
        }
    }

    // MARK: - Authenticated requests

    /// Headers per the reference authedFetch: Bearer token, UA, device
    /// id, language, the raw cookie, and account id when known. One
    /// automatic refresh-and-retry on 401; simple backoff retry for
    /// idempotent GETs on 429/5xx.
    func authedRequest(
        path: String,
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        accept: String = "application/json"
    ) async throws -> (Data, HTTPURLResponse) {
        var didRefresh = false
        var attempt = 0
        let isIdempotent = method == "GET"
        while true {
            let token = try await ensureAccessToken()
            guard let url = URL(string: path, relativeTo: baseURL) else {
                throw ClientError.badPayload("bad path \(path)")
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 60
            request.httpShouldHandleCookies = false
            request.setValue(accept, forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(deviceID, forHTTPHeaderField: "oai-device-id")
            request.setValue("en-US", forHTTPHeaderField: "oai-language")
            if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if let accountID { request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id") }
            if let jsonBody {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClientError.badPayload("no HTTP response") }
            if Self.looksLikeChallenge(http, data: data) { throw ClientError.challenge }
            if http.statusCode == 401, !didRefresh {
                didRefresh = true
                accessToken = nil
                // The cookie itself may have rotated in the browser the
                // session came from. Re-reading it there is silent and
                // usually enough; only if that fails does the user see a
                // sign-in prompt.
                await reimportFromBrowser()
                continue
            }
            if isIdempotent, [429, 500, 502, 503, 504].contains(http.statusCode), attempt < 2 {
                attempt += 1
                let backoff = min(8.0, 0.25 * pow(2, Double(attempt))) + Double.random(in: 0...0.25)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                continue
            }
            return (data, http)
        }
    }

    /// Streaming variant of `authedRequest` — same header contract, no
    /// retry loop (the caller owns turn-level retry semantics; replaying
    /// an accepted generation could duplicate it).
    func authedStream(
        path: String,
        jsonBody: [String: Any],
        extraHeaders: [String: String] = [:]
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let token = try await ensureAccessToken()
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ClientError.badPayload("bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Idle timeout consistent with the app's other streams.
        request.timeoutInterval = 180
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(deviceID, forHTTPHeaderField: "oai-device-id")
        request.setValue("en-US", forHTTPHeaderField: "oai-language")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badPayload("no HTTP response") }
        return (bytes, http)
    }

    // MARK: - Models

    /// /backend-api/models — account-scoped, standard-chat surface. The
    /// reference walks the raw records for availability booleans and
    /// effort hints; this ports that pragmatically.
    func fetchModels(force: Bool = false) async throws -> [RemoteModel] {
        if !force, let modelCache, Date().timeIntervalSince(modelCache.at) < 60 {
            return modelCache.models
        }
        var lastMessage = "no model records"
        for path in ["backend-api/models?history_and_training_disabled=false", "backend-api/models"] {
            let (data, http) = try await authedRequest(path: path)
            guard http.statusCode == 200 else {
                lastMessage = "HTTP \(http.statusCode)"
                if http.statusCode == 404 { continue }
                throw ClientError.http(http.statusCode, "model discovery failed")
            }
            guard let payload = try? JSONSerialization.jsonObject(with: data) else {
                lastMessage = "unparseable model payload"
                continue
            }
            let models = Self.parseModels(payload: payload)
            if !models.isEmpty {
                modelCache = (Date(), models)
                return models
            }
        }
        throw ClientError.badPayload(lastMessage)
    }

    private static func parseModels(payload: Any) -> [RemoteModel] {
        var candidates: [[String: Any]] = []
        if let array = payload as? [[String: Any]] {
            candidates = array
        } else if let dict = payload as? [String: Any] {
            if let models = dict["models"] as? [[String: Any]] {
                candidates = models
            } else if let data = dict["data"] as? [String: Any], let models = data["models"] as? [[String: Any]] {
                candidates = models
            } else if let data = dict["data"] as? [[String: Any]] {
                candidates = data
            }
        }
        struct Record {
            let slug: String
            let title: String?
            let description: String?
            let raw: [String: Any]
        }
        let records: [Record] = candidates.compactMap { item in
            guard let slug = (item["slug"] ?? item["id"] ?? item["model_slug"] ?? item["model"]) as? String, !slug.isEmpty else { return nil }
            return Record(
                slug: slug,
                title: (item["title"] ?? item["name"] ?? item["display_name"]) as? String,
                description: (item["description"] ?? item["short_description"]) as? String,
                raw: item
            )
        }
        // Which records carry a usable Pro reasoning route (e.g. Sol Pro)
        // — presented as an effort on the base model, per the reference.
        let hasProRoute = records.contains { record in
            "\(record.slug) \(record.title ?? "")".lowercased().replacingOccurrences(of: " ", with: "-").contains("pro")
                && !recordUnusable(record.raw)
        }
        var result: [RemoteModel] = []
        for record in records {
            if recordUnusable(record.raw) { continue }
            let name = "\(record.slug) \(record.title ?? "")".lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
            // Pro routes are internal — selected via effort, never listed.
            if name.contains("-pro") || name.hasSuffix("pro") { continue }
            // Records scoped to non-chat surfaces are excluded.
            if surfacesExcludeChat(record.raw) { continue }
            var efforts = effortHints(record.raw, slug: record.slug, title: record.title)
            if hasProRoute { efforts.insert("pro") }
            let ordered = ["instant", "medium", "high", "extra_high", "pro"].filter { efforts.contains($0) }
            result.append(RemoteModel(
                id: record.slug,
                ownedBy: "openai",
                name: record.title,
                description: record.description,
                supportsReasoning: ordered.contains { $0 != "instant" },
                // Vision and tools arrive with the upload/tool-emulation
                // phases — advertising them before then would be a lie.
                supportsVision: false,
                supportsTools: false,
                supportedEfforts: ordered
            ))
        }
        return result
    }

    /// Recursively walks a raw model record collecting normalized
    /// key/value signals — the reference's modelSignals().
    private static func signals(in value: Any, depth: Int = 0) -> [(key: String, value: Any)] {
        guard depth <= 5, let dict = value as? [String: Any] else { return [] }
        var out: [(String, Any)] = []
        for (key, item) in dict {
            let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
            out.append((normalized, item))
            out.append(contentsOf: signals(in: item, depth: depth + 1))
        }
        return out
    }

    private static func recordUnusable(_ raw: [String: Any]) -> Bool {
        let all = signals(in: raw)
        func bools(_ keys: Set<String>) -> [Bool] {
            all.filter { keys.contains($0.key) }.compactMap { $0.value as? Bool }
        }
        if bools(["hidden", "ishidden"]).contains(true) { return true }
        if bools(["visible", "isvisible"]).contains(false) { return true }
        if bools(["selectable", "isselectable", "canselect", "userselectable"]).contains(false) { return true }
        if bools(["fallbackonly", "isfallback", "ratefallback", "fallbackmodel"]).contains(true) { return true }
        if bools(["enabled", "isenabled"]).contains(false) { return true }
        if bools(["disabled", "isdisabled"]).contains(true) { return true }
        if bools(["available", "isavailable"]).contains(false) { return true }
        return false
    }

    private static func strings(in value: Any, depth: Int = 0) -> [String] {
        if let string = value as? String { return [string.lowercased()] }
        guard depth <= 5 else { return [] }
        if let array = value as? [Any] { return array.flatMap { strings(in: $0, depth: depth + 1) } }
        if let dict = value as? [String: Any] { return dict.values.flatMap { strings(in: $0, depth: depth + 1) } }
        return []
    }

    private static func surfacesExcludeChat(_ raw: [String: Any]) -> Bool {
        let surfaceKeys: Set<String> = ["products", "supportedproducts", "surfaces", "supportedsurfaces", "contexts", "availabilitycontexts"]
        let values = signals(in: raw)
            .filter { surfaceKeys.contains($0.key) }
            .flatMap { strings(in: $0.value) }
            .map { $0.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-") }
        guard !values.isEmpty else { return false }
        let chatLike = values.contains { $0.range(of: "(^|[-/])(chat|chatgpt|conversation|standard-chat|standard)([-/]|$)", options: .regularExpression) != nil }
        let allOther = values.allSatisfy { $0.range(of: "(^|[-/])(work|codex|api|developer)([-/]|$)", options: .regularExpression) != nil }
        return !chatLike && allOther
    }

    private static func effortHints(_ raw: [String: Any], slug: String, title: String?) -> Set<String> {
        let embedded = strings(in: raw)
        let hay = "\(slug) \(title ?? "") \(embedded.joined(separator: " "))".lowercased()
        var efforts = Set<String>()
        if embedded.contains(where: { $0.range(of: "(^|[^a-z])instant([^a-z]|$)|fast", options: .regularExpression) != nil }) { efforts.insert("instant") }
        if embedded.contains(where: { $0.range(of: "(^|[^a-z])medium([^a-z]|$)|standard reasoning", options: .regularExpression) != nil }) { efforts.insert("medium") }
        if embedded.contains(where: { $0.range(of: "(^|[^a-z])high([^a-z]|$)|extended reasoning", options: .regularExpression) != nil }) { efforts.insert("high") }
        if embedded.contains(where: { $0.range(of: "xhigh|extra high|extra-high|maximum reasoning", options: .regularExpression) != nil }) { efforts.insert("extra_high") }
        if hay.range(of: "\\bpro\\b", options: .regularExpression) != nil { efforts.insert("pro") }
        if efforts.isEmpty { efforts.insert("instant") }
        return efforts
    }

    // MARK: - Usage

    /// Plan + quota probe: accounts/check gives the plan type; the
    /// conversation-init probe exposes feature-level limits_progress.
    /// Only observed values land in the snapshot.
    func usageQuota() async throws -> QuotaSnapshot? {
        var snapshot = QuotaSnapshot()
        let timezoneOffset = -TimeZone.current.secondsFromGMT() / 60
        if let (data, http) = try? await authedRequest(path: "backend-api/accounts/check/v4-2023-04-27?timezone_offset_min=\(timezoneOffset)"),
           http.statusCode == 200,
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let plan = Self.planName(in: payload, accountID: accountID) {
                snapshot.planName = plan.capitalized
                planName = plan.capitalized
            }
        }
        return snapshot.planName == nil ? nil : snapshot
    }

    private static func planName(in payload: [String: Any], accountID: String?) -> String? {
        var root: [String: Any] = payload
        if let accounts = payload["accounts"] as? [String: [String: Any]] {
            let match = accountID.flatMap { wanted in
                accounts.values.first { candidate in
                    let account = candidate["account"] as? [String: Any] ?? candidate
                    return (account["id"] as? String) == wanted || (account["account_id"] as? String) == wanted
                }
            }
            root = match ?? accounts["default"] ?? accounts.values.first ?? payload
        }
        let account = root["account"] as? [String: Any] ?? root
        return (account["plan_type"] as? String)
            ?? (account["plan"] as? String)
            ?? (root["plan_type"] as? String)
            ?? (root["plan"] as? String)
    }
}

extension QuotaSnapshot {
    /// Empty snapshot for programmatic (non-header) sources like the
    /// ChatGPT usage probe.
    init() {}
}
