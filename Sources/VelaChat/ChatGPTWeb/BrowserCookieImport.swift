import Foundation
import CommonCrypto
import SQLite3

/// Reads a ChatGPT session out of a browser you're already logged into.
///
/// This exists because Google refuses OAuth inside embedded web views
/// ("this browser or app may not be secure"), so a Google-linked ChatGPT
/// account can never be signed in from VelaChat's own login window. The
/// session has to come from a real browser.
///
/// Only cookies for chatgpt.com / openai.com are ever read, and they go
/// straight to the Keychain — nothing else in the cookie store is touched
/// or retained.
enum BrowserCookieImport {
    struct Browser: Identifiable, Sendable {
        enum Engine: Sendable { case chromium, firefox, safari }
        var id: String { name }
        let name: String
        let engine: Engine
        let path: URL
        /// Keychain service name holding the Chromium profile's AES key.
        let keychainService: String?
    }

    enum ImportError: LocalizedError {
        case notInstalled
        case unreadable(String)
        case needsFullDiskAccess
        case noSession(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "That browser isn't installed, or has no profile yet."
            case .unreadable(let detail):
                "Couldn't read that browser's cookies: \(detail)"
            case .needsFullDiskAccess:
                "macOS blocks reading Safari's cookies until VelaChat has Full Disk Access (System Settings → Privacy & Security → Full Disk Access). Another browser, or pasting the token manually, avoids this."
            case .noSession(let name):
                "No ChatGPT session found in \(name). Log in to chatgpt.com there first, then try again."
            }
        }
    }

    /// Every browser we know how to read, filtered to the ones actually
    /// present on this Mac.
    static func availableBrowsers() -> [Browser] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let candidates: [Browser] = [
            Browser(name: "Chrome", engine: .chromium,
                    path: support.appendingPathComponent("Google/Chrome"), keychainService: "Chrome Safe Storage"),
            Browser(name: "Brave", engine: .chromium,
                    path: support.appendingPathComponent("BraveSoftware/Brave-Browser"), keychainService: "Brave Safe Storage"),
            Browser(name: "Microsoft Edge", engine: .chromium,
                    path: support.appendingPathComponent("Microsoft Edge"), keychainService: "Microsoft Edge Safe Storage"),
            Browser(name: "Vivaldi", engine: .chromium,
                    path: support.appendingPathComponent("Vivaldi"), keychainService: "Vivaldi Safe Storage"),
            Browser(name: "Arc", engine: .chromium,
                    path: support.appendingPathComponent("Arc/User Data"), keychainService: "Arc Safe Storage"),
            Browser(name: "Firefox", engine: .firefox,
                    path: support.appendingPathComponent("Firefox/Profiles"), keychainService: nil),
            Browser(name: "Zen", engine: .firefox,
                    path: support.appendingPathComponent("Zen/Profiles"), keychainService: nil),
            Browser(name: "Safari", engine: .safari,
                    path: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                    keychainService: nil),
        ]
        // Presence of the support folder isn't enough — uninstalled or
        // never-launched browsers leave empty directories behind, and
        // listing them just produces buttons that can only fail.
        return candidates.filter(hasCookieStore)
    }

    private static func hasCookieStore(_ browser: Browser) -> Bool {
        let manager = FileManager.default
        switch browser.engine {
        case .safari:
            return manager.fileExists(atPath: browser.path.path)
        case .chromium:
            return ["Default", "Profile 1", "Profile 2", "Profile 3"].contains {
                manager.fileExists(atPath: browser.path.appendingPathComponent("\($0)/Cookies").path)
            }
        case .firefox:
            let profiles = (try? manager.contentsOfDirectory(at: browser.path, includingPropertiesForKeys: nil)) ?? []
            return profiles.contains {
                manager.fileExists(atPath: $0.appendingPathComponent("cookies.sqlite").path)
            }
        }
    }

    /// Returns a `name=value; …` Cookie header for chatgpt.com, or throws
    /// with a reason the user can act on.
    static func cookieHeader(from browser: Browser) throws -> String {
        let cookies: [(name: String, value: String)]
        switch browser.engine {
        case .chromium: cookies = try chromiumCookies(browser)
        case .firefox: cookies = try firefoxCookies(browser)
        case .safari: cookies = try safariCookies(browser)
        }
        guard cookies.contains(where: { isSessionCookie($0.name) }) else {
            throw ImportError.noSession(browser.name)
        }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func isSessionCookie(_ name: String) -> Bool {
        name == "__Secure-next-auth.session-token"
            || name == "__Secure-authjs.session-token"
            || name.hasPrefix("__Secure-next-auth.session-token.")
            || name.hasPrefix("__Secure-authjs.session-token.")
    }

    private static func isRelevantHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered.contains("chatgpt.com") || lowered.contains("openai.com")
    }

    // MARK: - Chromium

    private static func chromiumCookies(_ browser: Browser) throws -> [(name: String, value: String)] {
        guard let service = browser.keychainService else { throw ImportError.notInstalled }
        let profiles = ["Default", "Profile 1", "Profile 2", "Profile 3"]
        var lastError: Error = ImportError.noSession(browser.name)
        let key = try chromiumKey(service: service)
        for profile in profiles {
            let file = browser.path.appendingPathComponent("\(profile)/Cookies")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                let rows = try readSQLite(
                    file: file,
                    query: "SELECT name, encrypted_value, host_key FROM cookies",
                    columns: 3
                ) { statement, index in
                    // Column 1 is a BLOB; the generic reader hands back Data.
                    index == 1 ? .blob : .text
                }
                var result: [(String, String)] = []
                for row in rows {
                    guard case .text(let name) = row[0],
                          case .blob(let encrypted) = row[1],
                          case .text(let host) = row[2],
                          isRelevantHost(host) else { continue }
                    guard let value = decryptChromium(encrypted, key: key) else { continue }
                    result.append((name, value))
                }
                if !result.isEmpty { return result }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Chromium encrypts cookie values with AES-128-CBC. The passphrase
    /// lives in the login Keychain; the key derivation constants
    /// (salt "saltysalt", 1003 rounds, 16-byte key, all-space IV) are
    /// Chromium's, fixed in its source for over a decade.
    private static func chromiumKey(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let passphrase = String(data: data, encoding: .utf8) else {
            throw ImportError.unreadable("its encryption key wasn't available in the Keychain (status \(status)).")
        }
        var derived = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let result = passphrase.withCString { passwordPointer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordPointer, strlen(passwordPointer),
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1_003,
                &derived, derived.count
            )
        }
        guard result == kCCSuccess else {
            throw ImportError.unreadable("its encryption key could not be derived.")
        }
        return Data(derived)
    }

    private static func decryptChromium(_ blob: Data, key: Data) -> String? {
        // "v10"/"v11" prefix marks an encrypted value; anything else is
        // either plaintext (old profiles) or something we shouldn't touch.
        guard blob.count > 3 else { return nil }
        let prefix = String(data: blob.prefix(3), encoding: .utf8)
        guard prefix == "v10" || prefix == "v11" else {
            return String(data: blob, encoding: .utf8)
        }
        let payload = blob.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            payload.withUnsafeBytes { dataBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                    keyBytes.baseAddress, key.count,
                    iv,
                    dataBytes.baseAddress, payload.count,
                    &output, output.count, &moved
                )
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        var plaintext = Data(output.prefix(moved))
        // PKCS#7 padding, then a 32-byte SHA-256 domain prefix on newer
        // Chromium builds — stripped only when it isn't valid UTF-8 as-is.
        if let pad = plaintext.last, pad > 0, pad <= 16, plaintext.count >= Int(pad) {
            plaintext = plaintext.dropLast(Int(pad))
        }
        if let text = String(data: plaintext, encoding: .utf8) { return text }
        if plaintext.count > 32, let text = String(data: plaintext.dropFirst(32), encoding: .utf8) { return text }
        return nil
    }

    // MARK: - Firefox

    private static func firefoxCookies(_ browser: Browser) throws -> [(name: String, value: String)] {
        let profiles = (try? FileManager.default.contentsOfDirectory(at: browser.path, includingPropertiesForKeys: nil)) ?? []
        for profile in profiles {
            let file = profile.appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let rows = try readSQLite(
                file: file,
                query: "SELECT name, value, host FROM moz_cookies",
                columns: 3
            ) { _, _ in .text }
            var result: [(String, String)] = []
            for row in rows {
                guard case .text(let name) = row[0],
                      case .text(let value) = row[1],
                      case .text(let host) = row[2],
                      isRelevantHost(host) else { continue }
                result.append((name, value))
            }
            if !result.isEmpty { return result }
        }
        throw ImportError.noSession(browser.name)
    }

    // MARK: - Safari

    /// Safari stores cookies in its own `binarycookies` container format:
    /// a page-indexed file of length-prefixed records with big-endian page
    /// headers and little-endian record offsets.
    private static func safariCookies(_ browser: Browser) throws -> [(name: String, value: String)] {
        guard let data = FileManager.default.contents(atPath: browser.path.path) else {
            throw ImportError.needsFullDiskAccess
        }
        guard data.count > 8, data.prefix(4) == Data("cook".utf8) else {
            throw ImportError.unreadable("Safari's cookie file wasn't in the expected format.")
        }
        func u32BE(_ offset: Int) -> Int? {
            guard offset + 4 <= data.count else { return nil }
            return Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        }
        func u32LE(_ offset: Int) -> Int? {
            guard offset + 4 <= data.count else { return nil }
            return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        func cString(at offset: Int) -> String? {
            guard offset < data.count, let end = data[offset...].firstIndex(of: 0) else { return nil }
            return String(data: data[offset..<end], encoding: .utf8)
        }

        guard let pageCount = u32BE(4) else { return [] }
        var pageSizes: [Int] = []
        for index in 0..<pageCount {
            guard let size = u32BE(8 + index * 4) else { return [] }
            pageSizes.append(size)
        }
        var cursor = 8 + pageCount * 4
        var result: [(String, String)] = []
        for size in pageSizes {
            let pageStart = cursor
            cursor += size
            guard pageStart + 12 <= data.count, let cookieCount = u32LE(pageStart + 4) else { continue }
            for index in 0..<cookieCount {
                guard let offset = u32LE(pageStart + 8 + index * 4) else { continue }
                let record = pageStart + offset
                guard record + 40 <= data.count,
                      let domainOffset = u32LE(record + 16),
                      let nameOffset = u32LE(record + 20),
                      let valueOffset = u32LE(record + 28),
                      let domain = cString(at: record + domainOffset),
                      let name = cString(at: record + nameOffset),
                      let value = cString(at: record + valueOffset),
                      isRelevantHost(domain) else { continue }
                result.append((name, value))
            }
        }
        if result.isEmpty { throw ImportError.noSession("Safari") }
        return result
    }

    // MARK: - SQLite helper

    private enum Column { case text, blob }
    private enum Value { case text(String), blob(Data), null }

    /// Reads a locked-or-not cookie DB. The file is copied first: browsers
    /// hold a write lock while running, and a copy is also the only way to
    /// be certain nothing here can modify the user's real profile.
    private static func readSQLite(
        file: URL,
        query: String,
        columns: Int,
        kind: (OpaquePointer?, Int) -> Column
    ) throws -> [[Value]] {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-cookies-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: file, to: temporary)
        } catch {
            throw ImportError.needsFullDiskAccess
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(temporary.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ImportError.unreadable("the cookie database couldn't be opened.")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.unreadable("the cookie database had an unexpected shape.")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[Value]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [Value] = []
            for index in 0..<columns {
                switch kind(statement, index) {
                case .text:
                    if let pointer = sqlite3_column_text(statement, Int32(index)) {
                        row.append(.text(String(cString: pointer)))
                    } else {
                        row.append(.null)
                    }
                case .blob:
                    let length = Int(sqlite3_column_bytes(statement, Int32(index)))
                    if let pointer = sqlite3_column_blob(statement, Int32(index)), length > 0 {
                        row.append(.blob(Data(bytes: pointer, count: length)))
                    } else {
                        row.append(.null)
                    }
                }
            }
            rows.append(row)
        }
        return rows
    }
}
