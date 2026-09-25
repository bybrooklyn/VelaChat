import Foundation

/// Server-side Claude subscription usage for the claudeCode provider.
///
/// The same read-only endpoint that powers Claude Code's own `/usage`
/// view, used identically by the community monitors (ccusage,
/// claude-monitor): `GET https://api.anthropic.com/api/oauth/usage` with
/// the CLI's OAuth token and the `anthropic-beta: oauth-2025-04-20`
/// header. Response shape (confirmed across three independent
/// implementations):
///
///     {"five_hour": {"utilization": 33, "resets_at": "ISO-8601"},
///      "seven_day": {...}, "seven_day_sonnet": {...}|null,
///      "seven_day_opus": {...}|null,
///      "limits": [{"kind": "session"|"weekly_all"|"weekly_scoped",
///                  "percent": n, "resets_at": "ISO-8601",
///                  "scope": {"model": {"display_name": ...}}}]}
///
/// Older servers send only the flat keys; newer ones moved the live data
/// into the `limits` array. Both are parsed.
///
/// Stats-only boundary: the token is read from the CLI's own credentials
/// file and used for this endpoint alone — never for inference (see the
/// stance documented in `ClaudeExecutableLocator`). Local-first polling:
/// only called from the gauge's debounced refresh path, never on a timer.
/// Everything is fail-soft: any unreadable file, expired token, HTTP
/// error, or unrecognized shape yields nil rather than a wrong number.
public enum ClaudeUsageProbe {
    public static func snapshot() async -> QuotaSnapshot? {
        guard let token = oauthToken(), !token.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(UsageResponse.self, from: data) else { return nil }
        return payload.quotaSnapshot()
    }

    /// The CLI's stored OAuth token, or nil when absent/expired. Never
    /// refreshed here — refreshing is the CLI's own sign-in flow.
    static func oauthToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expiresAt = oauth["expiresAt"] as? Double,
           // `expiresAt` is epoch milliseconds in the CLI's file.
           expiresAt > 0, Date(timeIntervalSince1970: expiresAt / 1_000) <= Date() {
            return nil
        }
        return token
    }

    struct UsageResponse: Decodable {
        struct WindowState: Decodable {
            let utilization: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
        struct ScopedLimit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable {
                    let displayName: String?
                    enum CodingKeys: String, CodingKey {
                        case displayName = "display_name"
                    }
                }
                let model: Model?
            }
            let kind: String?
            let percent: Double?
            let resetsAt: String?
            let scope: Scope?
            enum CodingKeys: String, CodingKey {
                case kind, percent, scope
                case resetsAt = "resets_at"
            }
        }
        let fiveHour: WindowState?
        let sevenDay: WindowState?
        let sevenDaySonnet: WindowState?
        let extraUsage: ExtraUsage?
        let limits: [ScopedLimit]?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDaySonnet = "seven_day_sonnet"
            case extraUsage = "extra_usage"
            case limits
        }
        struct ExtraUsage: Decodable {
            let isEnabled: Bool?
            enum CodingKeys: String, CodingKey {
                case isEnabled = "is_enabled"
            }
        }

        func quotaSnapshot() -> QuotaSnapshot? {
            // Prefer the structured limits array when present; fall back
            // to the legacy flat keys.
            var primary: QuotaSnapshot.Window?
            var secondary: QuotaSnapshot.Window?
            if let limits = limits, !limits.isEmpty {
                for entry in limits {
                    guard let percent = entry.percent else { continue }
                    let window = QuotaSnapshot.Window(
                        usedPercent: percent,
                        windowMinutes: Self.minutes(for: entry.kind),
                        resetAt: Self.date(entry.resetsAt)
                    )
                    switch entry.kind {
                    case "session": primary = primary ?? window
                    case "weekly_all": secondary = secondary ?? window
                    default: continue
                    }
                }
            }
            if primary == nil, let state = fiveHour, let used = state.utilization {
                primary = QuotaSnapshot.Window(usedPercent: used, windowMinutes: 300, resetAt: Self.date(state.resetsAt))
            }
            if secondary == nil, let state = sevenDay, let used = state.utilization {
                secondary = QuotaSnapshot.Window(usedPercent: used, windowMinutes: 10_080, resetAt: Self.date(state.resetsAt))
            }
            guard primary != nil || secondary != nil else { return nil }
            return QuotaSnapshot(primaryWindow: primary, secondaryWindow: secondary)
        }

        private static func minutes(for kind: String?) -> Int? {
            switch kind {
            case "session": 300
            case "weekly_all", "weekly_scoped": 10_080
            default: nil
            }
        }

        private static func date(_ raw: String?) -> Date? {
            guard let raw, !raw.isEmpty else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            return ISO8601DateFormatter().date(from: raw)
        }
    }
}
