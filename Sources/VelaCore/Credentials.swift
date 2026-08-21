import Foundation
import Security

// MARK: - Keychain

public enum SecureStore {
    /// Deliberately a new service name.
    ///
    /// Items under the old `com.velachat.credentials` service were written
    /// while the app was ad-hoc signed, so their Keychain ACL is bound to a
    /// binary hash that changed on every rebuild. Reading them now that the
    /// app has a stable signing identity makes macOS put up an "allow access"
    /// password prompt — the exact thing that must never happen. Those items
    /// are therefore abandoned rather than migrated: nothing reads them, so
    /// nothing can prompt. Keys written from here on are created *by* the
    /// stable identity, so they are readable forever without a prompt.
    private static let service = "com.velachat.credentials.v2"

    public static func value(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func set(_ value: String?, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Codex auth

public struct CodexCredential {
    public let token: String
    public let isAPIKey: Bool
    public let accountID: String?
    public let fileURL: URL

    public var kindLabel: String { isAPIKey ? "API key" : "OAuth session" }
}

public enum CodexAuth {
    public static var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    public static func discover() -> CodexCredential? {
        guard let data = try? Data(contentsOf: authFileURL),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let apiKey = findString(in: object, keys: ["OPENAI_API_KEY", "openai_api_key", "api_key"])
        let accessToken = findString(in: object, keys: ["access_token", "accessToken"])
        let token = apiKey ?? accessToken
        guard let token, !token.isEmpty else { return nil }

        let accountID = findString(in: object, keys: ["account_id", "accountId", "chatgpt_account_id"])
        return CodexCredential(token: token, isAPIKey: apiKey != nil, accountID: accountID, fileURL: authFileURL)
    }

    /// Launches the official Codex CLI login flow without exposing credentials
    /// to the app. Once it completes, `discover()` reads the CLI's auth file.
    public static func launchLogin() throws {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            "/usr/bin/codex",
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexError.cliMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["login"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
    }

    private static func findString(in value: Any, keys: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let string = dictionary[key] as? String, !string.isEmpty { return string }
            }
            for nested in dictionary.values {
                if let found = findString(in: nested, keys: keys) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = findString(in: nested, keys: keys) { return found }
            }
        }
        return nil
    }
}

public enum CodexError: Error, LocalizedError {
    case cliMissing

    public var errorDescription: String? {
        switch self {
        case .cliMissing:
            "Codex CLI was not found. Install it, then run `codex login` once."
        }
    }
}
