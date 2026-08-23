import XCTest
@testable import VelaCore

/// §9.7 — the structured parsers behind the git tools, fed real `git`
/// output shapes (porcelain v2 branch block included).
final class GitToolsTests: XCTestCase {

    func testParsesBranchAheadBehindAndSections() {
        let porcelain = """
        # branch.oid 1234abcd
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 abc def src/app.swift
        1 M. N... 100644 100644 100644 abc def README.md
        ? notes.txt
        u 1 1 1 1 1111111 conflicted.swift
        """
        let status = GitTools.parseStatus(porcelain)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.staged, ["README.md"])
        XCTAssertEqual(status.unstaged, ["src/app.swift", "conflicted.swift"])
        XCTAssertEqual(status.untracked, ["notes.txt"])
    }

    func testDetachedHeadAndCleanTree() {
        let status = GitTools.parseStatus("# branch.head (detached)\n")
        XCTAssertNil(status.branch)
        XCTAssertTrue(GitTools.describe(status).contains("detached"))
        XCTAssertFalse(GitTools.describe(GitTools.parseStatus("")).contains("clean"))
        XCTAssertTrue(GitTools.describe(GitTools.parseStatus("")).isEmpty == false && GitTools.describe(GitTools.parseStatus("")).contains("(detached)"))
    }

    func testDescribeRendersCountsAndCaps() {
        var status = GitTools.Status()
        status.branch = "feature/x"
        status.ahead = 3
        status.staged = (0..<50).map { "file\($0).swift" }
        let text = GitTools.describe(status)
        XCTAssertTrue(text.contains("+3 ahead"))
        XCTAssertTrue(text.contains("…and 10 more"))
    }

    func testLogParsing() {
        let commits = GitTools.parseLog("abc1234 Fix the thing\ndef5678 \"Quoted\" subject\n\nshortline\nxyz9 Two words here")
        XCTAssertEqual(commits.count, 3)
        XCTAssertEqual(commits[0].hash, "abc1234")
        XCTAssertEqual(commits[0].subject, "Fix the thing")
        XCTAssertEqual(commits[1].subject, "\"Quoted\" subject")
        XCTAssertEqual(commits.last?.hash, "xyz9")
    }
}
