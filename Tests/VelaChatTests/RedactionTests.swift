import XCTest
@testable import VelaCore

/// Redaction is an egress control: a rule that silently stops matching is
/// a leak, not a cosmetic bug. These tests pin each built-in shape and the
/// overlap resolution that decides which rule wins when two match the same
/// text.
final class RedactionTests: XCTestCase {

    /// Sample credentials are assembled from fragments rather than written
    /// as literals. A literal here is shaped exactly like the real thing,
    /// which is the point of the test — and is also exactly what GitHub's
    /// push protection blocks, and what a future secret scanner would keep
    /// re-flagging. Concatenation keeps the runtime string identical while
    /// leaving no key-shaped text in the file.
    private func sample(_ prefix: String, _ body: String) -> String { prefix + body }

    private func redactor(_ names: String...) -> Redactor {
        let wanted = Set(names)
        var rules = RedactionRule.builtIns().filter { wanted.contains($0.name) }
        // Built-ins that ship disabled still need to be testable.
        for index in rules.indices { rules[index].isEnabled = true }
        XCTAssertEqual(rules.count, wanted.count, "a built-in rule was renamed or removed")
        return Redactor(rules: rules)
    }

    private func allBuiltIns() -> Redactor {
        var rules = RedactionRule.builtIns()
        for index in rules.indices { rules[index].isEnabled = true }
        return Redactor(rules: rules)
    }

    // MARK: Every built-in rule

    func testAnthropicKey() {
        let key = sample("sk-ant-", "api03-AbCdEfGhIjKlMnOpQrSt")
        let result = redactor("Anthropic API key").redact("key: \(key)")
        XCTAssertFalse(result.text.contains(key))
        XCTAssertEqual(result.spans.map(\.ruleName), ["Anthropic API key"])
    }

    func testOpenAIKey() {
        let key = sample("sk-", "proj-abcdefghijklmnopqrstuvwx")
        let result = redactor("OpenAI API key").redact("OPENAI_API_KEY=\(key)")
        XCTAssertFalse(result.text.contains(key))
        XCTAssertTrue(result.text.contains("[redacted: OpenAI API key]"))
    }

    func testGitHubToken() {
        let token = sample("ghp", "_abcdefghijklmnopqrstuvwxyz0123456789")
        let result = redactor("GitHub token").redact(token)
        XCTAssertFalse(result.text.contains(token))
        XCTAssertTrue(result.didRedact)
    }

    func testSlackToken() {
        let token = sample("xox", "b-123456789012-abcdefghijkl")
        let result = redactor("Slack token").redact(token)
        XCTAssertFalse(result.text.contains(token))
    }

    func testGoogleKey() {
        let key = sample("AIz", "a") + String(repeating: "a", count: 35)
        let result = redactor("Google API key").redact("k=\(key)")
        XCTAssertFalse(result.text.contains(key))
    }

    func testAWSAccessKeyID() {
        let long = sample("AKI", "AIOSFODNN7EXAMPLE")
        let temporary = sample("ASI", "AIOSFODNN7EXAMPLE")
        let result = redactor("AWS access key ID").redact("\(long) and \(temporary)")
        XCTAssertFalse(result.text.contains(long))
        XCTAssertFalse(result.text.contains(temporary))
        XCTAssertEqual(result.spans.count, 2)
    }

    func testAWSSecretKey() {
        let secret = String(repeating: "A", count: 40)
        let result = redactor("AWS secret key").redact("aws_secret_access_key = \(secret)")
        XCTAssertFalse(result.text.contains(secret))
    }

    func testBearerToken() {
        let result = redactor("Bearer token").redact("Authorization: Bearer abcdefghijklmnopqrstuvwxyz")
        XCTAssertFalse(result.text.contains("abcdefghijklmnopqrstuvwxyz"))
    }

    func testPrivateKeyBlock() {
        let block = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAxyz
        morelines
        -----END RSA PRIVATE KEY-----
        """
        let result = redactor("Private key block").redact("here it is:\n\(block)\ndone")
        XCTAssertFalse(result.text.contains("MIIEowIBAAKCAQEAxyz"))
        XCTAssertTrue(result.text.hasPrefix("here it is:\n"))
        XCTAssertTrue(result.text.hasSuffix("\ndone"))
    }

    func testEmailRuleMatchesWhenEnabled() {
        let result = redactor("Email address").redact("write to brooklyn@example.com please")
        XCTAssertFalse(result.text.contains("brooklyn@example.com"))
        XCTAssertTrue(result.text.contains("please"))
    }

    /// Addresses are frequently the actual subject of a message, so this
    /// one ships off. If that default flips, it should be a decision, not
    /// an accident.
    func testEmailRuleIsDisabledByDefault() {
        let email = RedactionRule.builtIns().first { $0.name == "Email address" }
        XCTAssertEqual(email?.isEnabled, false)
        let asShipped = Redactor(rules: RedactionRule.builtIns())
        XCTAssertFalse(asShipped.redact("brooklyn@example.com").didRedact)
    }

    // MARK: Overlap behavior

    /// "Bearer sk-ant-…" matches both the bearer rule and the key rule.
    /// The longer match must win, and the text must be rewritten exactly
    /// once — nested markers would mean the second pass ran over text the
    /// first had already replaced.
    func testOverlappingMatchesCollapseToOne() {
        let key = sample("sk-ant-", "api03-AbCdEfGhIjKlMnOpQrSt")
        let result = allBuiltIns().redact("Authorization: Bearer \(key)")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertFalse(result.text.contains(key))
        XCTAssertFalse(result.text.contains("[redacted: [redacted:"))
    }

    func testAdjacentMatchesAreBothRedacted() {
        let first = sample("AKI", "AIOSFODNN7EXAMPLE")
        let second = sample("AKI", "AIOSFODNN7EXAMPLB")
        let result = redactor("AWS access key ID").redact("\(first) \(second)")
        XCTAssertEqual(result.spans.count, 2)
        XCTAssertFalse(result.text.contains(first))
        XCTAssertFalse(result.text.contains(second))
    }

    /// The recorded span must actually point at the marker in the redacted
    /// string — the transcript uses these offsets.
    func testSpanOffsetsPointAtTheMarker() {
        let token = sample("ghp", "_abcdefghijklmnopqrstuvwxyz0123456789")
        let result = redactor("GitHub token").redact("token \(token) end")
        let span = try? XCTUnwrap(result.spans.first)
        guard let span else { return }
        let ns = result.text as NSString
        XCTAssertEqual(
            ns.substring(with: NSRange(location: span.location, length: span.length)),
            "[redacted: GitHub token]"
        )
    }

    // MARK: Non-matches and edge cases

    func testCleanTextIsUntouched() {
        let text = "Just an ordinary sentence about sk and keys."
        let result = allBuiltIns().redact(text)
        XCTAssertEqual(result.text, text)
        XCTAssertFalse(result.didRedact)
    }

    func testEmptyInput() {
        XCTAssertFalse(allBuiltIns().redact("").didRedact)
    }

    func testDisabledRuleDoesNotMatch() {
        var rule = RedactionRule.builtIns().first { $0.name == "GitHub token" }!
        rule.isEnabled = false
        let result = Redactor(rules: [rule]).redact(sample("ghp", "_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(result.didRedact)
    }

    /// A pattern that cannot compile matches nothing, which looks exactly
    /// like a pattern that found nothing. It must be reportable.
    func testInvalidPatternIsReportedNotSwallowed() {
        let broken = RedactionRule(name: "Broken", pattern: "([unclosed")
        XCTAssertTrue(Redactor.invalidRuleIDs(in: [broken]).contains(broken.id))
        XCTAssertFalse(Redactor(rules: [broken]).redact("anything at all").didRedact)
    }

    func testRedactionIsIdempotent() {
        let once = allBuiltIns().redact(sample("ghp", "_abcdefghijklmnopqrstuvwxyz0123456789"))
        let twice = allBuiltIns().redact(once.text)
        XCTAssertEqual(twice.text, once.text)
        XCTAssertFalse(twice.didRedact)
    }

    // MARK: Local-only mode

    func testLoopbackDetection() {
        XCTAssertTrue(EgressPolicy.isLoopback("localhost"))
        XCTAssertTrue(EgressPolicy.isLoopback("127.0.0.1"))
        XCTAssertTrue(EgressPolicy.isLoopback("127.1.2.3"))
        XCTAssertTrue(EgressPolicy.isLoopback("::1"))
        XCTAssertFalse(EgressPolicy.isLoopback("api.anthropic.com"))
        // A LAN host is still a network egress.
        XCTAssertFalse(EgressPolicy.isLoopback("192.168.1.20"))
        XCTAssertFalse(EgressPolicy.isLoopback("10.0.0.5"))
        // Not fooled by a hostname that merely contains a loopback string.
        XCTAssertFalse(EgressPolicy.isLoopback("localhost.evil.com"))
        XCTAssertFalse(EgressPolicy.isLoopback("127.0.0.1.evil.com"))
    }

    func testLocalOnlyBlocksRemoteAndAllowsLoopback() throws {
        let wasOn = EgressPolicy.isLocalOnly
        defer { EgressPolicy.isLocalOnly = wasOn }

        EgressPolicy.isLocalOnly = false
        XCTAssertNoThrow(try EgressPolicy.check(URL(string: "https://api.anthropic.com/v1/messages")!))

        EgressPolicy.isLocalOnly = true
        XCTAssertThrowsError(try EgressPolicy.check(URL(string: "https://api.anthropic.com/v1/messages")!))
        XCTAssertNoThrow(try EgressPolicy.check(URL(string: "http://127.0.0.1:11434/api/chat")!))
        XCTAssertNoThrow(try EgressPolicy.check(URL(string: "http://localhost:1234/v1/chat/completions")!))
    }
}
