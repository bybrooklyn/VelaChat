import XCTest
@testable import VelaCore

/// Persisted "always allow" rules decide what runs on the user's machine
/// without asking, so — like `CommandClassifierTests` — a regression here
/// is a security regression. These cases are the boundary: what a prefix
/// rule covers, what it must never stretch to cover, and the two scopes
/// (sandbox workspaces, and denials) it is not allowed to escape.
final class CommandTrustTests: XCTestCase {
    /// A path that never exists as a real folder — the rules are keyed by
    /// string, and nothing here touches the filesystem.
    private let folder = "/tmp/velachat-tests/project-\(UUID().uuidString)"

    override func tearDown() {
        CommandTrust.forget(folderPath: folder)
        super.tearDown()
    }

    // MARK: - Prefix matching

    func testPrefixRuleMatchesTheSameCommandWithArguments() {
        XCTAssertTrue(CommandTrust.matches(rule: "cargo test", command: "cargo test"))
        XCTAssertTrue(CommandTrust.matches(rule: "cargo test", command: "cargo test --lib"))
        XCTAssertTrue(CommandTrust.matches(rule: "cargo test", command: "cargo test -p core -- --nocapture"))
        XCTAssertTrue(CommandTrust.matches(rule: "swift build", command: "swift build -c release"))
    }

    /// The binary alone is not the subcommand that was trusted: `cargo`
    /// on its own could be `cargo publish`.
    func testPrefixRuleDoesNotMatchAShorterCommand() {
        XCTAssertFalse(CommandTrust.matches(rule: "cargo test", command: "cargo"))
        XCTAssertFalse(CommandTrust.matches(rule: "cargo test", command: "cargo build"))
    }

    /// Token-wise, not character-wise — `cargotest` is a different program
    /// that happens to share a prefix with the trusted one.
    func testPrefixRuleDoesNotMatchAConcatenatedName() {
        XCTAssertFalse(CommandTrust.matches(rule: "cargo test", command: "cargotest"))
        XCTAssertFalse(CommandTrust.matches(rule: "cargo", command: "cargotest --lib"))
    }

    /// The whole point of the classifier's "can I read this statically"
    /// rule: everything after `;` is a different command, so a command
    /// carrying one is never covered by a prefix rule however it starts.
    func testPrefixRuleNeverMatchesChainedOrRedirectedCommands() {
        XCTAssertFalse(CommandTrust.matches(rule: "cargo test", command: "cargo test; rm -rf ~"))
        XCTAssertFalse(CommandTrust.matches(rule: "cargo test", command: "cargo test && rm -rf ~"))
        XCTAssertFalse(CommandTrust.matches(rule: "cargo test", command: "cargo test | sh"))
        XCTAssertFalse(CommandTrust.matches(rule: "cargo test", command: "cargo test > out.txt"))
        XCTAssertFalse(CommandTrust.matches(rule: "cargo test", command: "cargo test\nrm -rf ~"))
    }

    // MARK: - Scope

    func testStoredRuleAllowsTheCommandForThatFolder() {
        CommandTrust.allow(rule: "cargo test", for: folder)
        XCTAssertEqual(CommandTrust.rules(for: folder), ["cargo test"])
        XCTAssertEqual(CommandTrust.decision(for: "cargo test --lib", folderPath: folder), .allowed(rule: "cargo test"))
        XCTAssertEqual(CommandTrust.decision(for: "cargo publish", folderPath: folder), .ask)
    }

    /// A per-conversation UUID sandbox directory is not a folder anyone
    /// chose, so it holds no rules and inherits none: the same command that
    /// runs freely in the attached checkout still has to be approved there.
    func testSandboxWorkspaceIsNeverOfferedAnotherFoldersRules() {
        CommandTrust.allow(rule: "cargo test", for: folder)
        XCTAssertEqual(CommandTrust.decision(for: "cargo test --lib", folderPath: nil), .ask)
        XCTAssertTrue(CommandTrust.rules(for: nil).isEmpty)
        // And nothing can be stored against one either.
        CommandTrust.allow(rule: "swift build", for: nil)
        XCTAssertTrue(CommandTrust.rules(for: nil).isEmpty)
    }

    func testForgettingRulesRemovesThem() {
        CommandTrust.allow(rule: "swift build", for: folder)
        CommandTrust.forget(folderPath: folder)
        XCTAssertTrue(CommandTrust.rules(for: folder).isEmpty)
        XCTAssertEqual(CommandTrust.decision(for: "swift build", folderPath: folder), .ask)
    }

    // MARK: - Deny wins

    /// A rule added afterwards must never quietly re-enable the exact
    /// command the user refused. It goes back to asking rather than
    /// auto-denying: the person who said no once is the person who should
    /// decide the second time, with the command in front of them.
    func testDenialIsNotOverriddenByALaterRule() {
        CommandTrust.noteDenied("cargo test --all-features", for: folder)
        CommandTrust.allow(rule: "cargo test", for: folder)
        XCTAssertEqual(CommandTrust.decision(for: "cargo test --all-features", folderPath: folder), .ask)
        // Only that command is affected — the rule still covers the rest.
        XCTAssertEqual(CommandTrust.decision(for: "cargo test --lib", folderPath: folder), .allowed(rule: "cargo test"))
    }

    // MARK: - Suggested rule

    func testSuggestedRuleIsTheBinaryAndItsSubcommand() {
        XCTAssertEqual(CommandTrust.suggestedRule(for: "cargo test --lib"), "cargo test")
        XCTAssertEqual(CommandTrust.suggestedRule(for: "swift build -c release"), "swift build")
        XCTAssertEqual(CommandTrust.suggestedRule(for: "npm test"), "npm test")
        // No subcommand to name, and nothing to summarize at all.
        XCTAssertEqual(CommandTrust.suggestedRule(for: "make"), "make")
        XCTAssertEqual(CommandTrust.suggestedRule(for: "ls -la"), "ls")
        XCTAssertNil(CommandTrust.suggestedRule(for: "./configure"))
        XCTAssertNil(CommandTrust.suggestedRule(for: "cargo test; rm -rf ~"))
        XCTAssertNil(CommandTrust.suggestedRule(for: "FOO=bar cargo test"))
    }
}
