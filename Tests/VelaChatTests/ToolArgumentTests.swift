import XCTest
@testable import VelaChat

/// Models emit almost-JSON more often than anyone would like. These are
/// the shapes seen in practice; each one used to fail the call outright.
final class ToolArgumentRepairTests: XCTestCase {
    func testCleanJSONParses() {
        let parsed = ToolCatalog.parseArguments(#"{"query":"hello","count":3}"#)
        XCTAssertEqual(parsed?["query"] as? String, "hello")
        XCTAssertEqual(parsed?["count"] as? Int, 3)
    }

    func testTrailingCommaIsRepaired() {
        let parsed = ToolCatalog.parseArguments(#"{"query":"hello",}"#)
        XCTAssertEqual(parsed?["query"] as? String, "hello")
    }

    func testSmartQuotesAreRepaired() {
        let parsed = ToolCatalog.parseArguments("{\u{201C}query\u{201D}:\u{201C}hello\u{201D}}")
        XCTAssertEqual(parsed?["query"] as? String, "hello")
    }

    func testObjectIsExtractedFromSurroundingProse() {
        let parsed = ToolCatalog.parseArguments("Sure! Here you go:\n{\"path\":\"a.txt\"}\nLet me know.")
        XCTAssertEqual(parsed?["path"] as? String, "a.txt")
    }

    /// Braces inside a string must not end the object early.
    func testBracesInsideStringsDoNotConfuseExtraction() {
        let parsed = ToolCatalog.parseArguments("noise {\"content\":\"func x() { return 1 }\"} more")
        XCTAssertEqual(parsed?["content"] as? String, "func x() { return 1 }")
    }

    func testUnrepairableInputReturnsNil() {
        XCTAssertNil(ToolCatalog.parseArguments("not json at all"))
        XCTAssertNil(ToolCatalog.parseArguments(""))
    }
}

/// `ToolCatalog.execute` races every tool against `Limits.toolTimeout` so
/// one hung tool can't wedge a whole reply — except `ask_user`, which is
/// waiting on a person reading a card, not on a machine. Answering three
/// questions routinely takes more than two minutes, and when it did the
/// model was handed "Error: the ask_user tool timed out after 120 seconds"
/// and carried on without the answer it had just asked for. Tested through
/// the policy predicate rather than by actually waiting 120 seconds.
final class ToolTimeoutPolicyTests: XCTestCase {
    func testAskUserIsExemptFromTheMachineTimeout() {
        XCTAssertFalse(ToolCatalog.isBoundedByTimeout(ToolCatalog.askUser.name))
    }

    func testEveryOtherToolStaysBounded() {
        let bounded = [
            ToolCatalog.webSearch, ToolCatalog.fetchURL, ToolCatalog.runCommand,
            ToolCatalog.calculator, ToolCatalog.searchConversations, ToolCatalog.writeFile,
            ToolCatalog.editFile, ToolCatalog.searchFiles, ToolCatalog.updatePlan,
            ToolCatalog.getSchedule, ToolCatalog.saveMemory, Subagents.definition,
        ]
        for tool in bounded {
            XCTAssertTrue(ToolCatalog.isBoundedByTimeout(tool.name), "\(tool.name) must stay bounded")
        }
        // Unknown names — MCP tools, anything a future provider invents —
        // are bounded too. The exemption is a named allowance, not a default.
        XCTAssertTrue(ToolCatalog.isBoundedByTimeout("mcp_something_slow"))
        XCTAssertTrue(ToolCatalog.isBoundedByTimeout(""))
    }
}

/// Guidance used to be pasted into the system prompt as well as shipped in
/// the tool definition. It ships once now, inside the description.
final class ToolWireDescriptionTests: XCTestCase {
    func testGuidanceTravelsWithTheDescription() {
        let tool = ToolCatalog.editFile
        XCTAssertTrue(tool.wireDescription.hasPrefix(tool.description))
        XCTAssertTrue(tool.wireDescription.contains(tool.guidance))
    }

    /// An MCP server can hand us a tool with no guidance of our own to add;
    /// that must not produce a description with a trailing space.
    func testEmptyGuidanceLeavesTheDescriptionAlone() {
        let tool = ToolCatalog.Definition(
            name: "mcp_example_thing",
            description: "Does a thing.",
            parametersJSON: #"{"type":"object","properties":{}}"#,
            guidance: ""
        )
        XCTAssertEqual(tool.wireDescription, "Does a thing.")
    }
}

/// A five-round tool reply once recorded only its final hop, undercounting
/// usage roughly fivefold.
final class ToolLoopUsageTests: XCTestCase {
    func testAccumulatesAcrossRounds() {
        var usage = ToolLoopUsage()
        var totals = usage.observe(prompt: 100, completion: 20, cached: nil)
        XCTAssertEqual(totals.prompt, 100)
        // Within a round the provider reports cumulative totals: latest wins.
        totals = usage.observe(prompt: 100, completion: 50, cached: nil)
        XCTAssertEqual(totals.completion, 50)
        usage.finishRound()
        totals = usage.observe(prompt: 300, completion: 10, cached: nil)
        XCTAssertEqual(totals.prompt, 400, "round two must add to round one, not replace it")
        XCTAssertEqual(totals.completion, 60)
    }

    /// Unknown must never be reported as zero — a provider that doesn't
    /// report usage should leave the number absent, not claim it was free.
    func testUnreportedStaysNil() {
        var usage = ToolLoopUsage()
        let totals = usage.observe(prompt: nil, completion: nil, cached: nil)
        XCTAssertNil(totals.prompt)
        XCTAssertNil(totals.completion)
        XCTAssertNil(totals.cached)
    }
}

final class QuotaSnapshotTests: XCTestCase {
    func testCodexWindowsParse() {
        let snapshot = QuotaSnapshot(headers: [
            "x-codex-primary-used-percent": "46.5",
            "x-codex-primary-window-minutes": "300",
            "x-codex-secondary-used-percent": "12",
            "x-codex-secondary-window-minutes": "10080",
            "x-codex-plan-type": "pro",
        ])
        XCTAssertEqual(snapshot?.primaryWindow?.usedPercent ?? 0, 46.5, accuracy: 0.01)
        XCTAssertEqual(snapshot?.primaryWindow?.label, "5-hour limit")
        XCTAssertEqual(snapshot?.secondaryWindow?.label, "Weekly limit")
        XCTAssertEqual(snapshot?.planName, "Pro")
    }

    func testAnthropicRateLimitHeaders() {
        let snapshot = QuotaSnapshot(headers: [
            "anthropic-ratelimit-requests-remaining": "42",
            "anthropic-ratelimit-requests-limit": "100",
        ])
        XCTAssertEqual(snapshot?.requestsRemaining, 42)
        XCTAssertEqual(snapshot?.usedFraction ?? 0, 0.58, accuracy: 0.001)
    }

    /// No quota headers at all must produce no snapshot, rather than an
    /// empty one the UI would render as real data.
    func testUnrelatedHeadersProduceNothing() {
        XCTAssertNil(QuotaSnapshot(headers: ["content-type": "application/json"]))
    }
}

final class BrowserCookieTests: XCTestCase {
    func testSessionCookieRecognition() {
        XCTAssertTrue(BrowserCookieImport.isSessionCookie("__Secure-next-auth.session-token"))
        XCTAssertTrue(BrowserCookieImport.isSessionCookie("__Secure-next-auth.session-token.0"))
        XCTAssertTrue(BrowserCookieImport.isSessionCookie("__Secure-authjs.session-token"))
        XCTAssertFalse(BrowserCookieImport.isSessionCookie("cf_clearance"))
        XCTAssertFalse(BrowserCookieImport.isSessionCookie("oai-did"))
    }
}
