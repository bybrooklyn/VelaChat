import XCTest
@testable import VelaChat

/// Planning mode is only worth anything if it is a real constraint, so
/// these pin both halves of it: what never reaches the wire, and — just as
/// important — what still does. A test that only checked the blocked list
/// would pass just as happily if planning mode accidentally withheld
/// everything, leaving a model that can neither act nor look.
final class PlanModeTests: XCTestCase {
    /// Roughly the fullest tool set a request ever carries.
    private var everyTool: [ToolCatalog.Definition] {
        [
            ToolCatalog.searchConversations,
            ToolCatalog.webSearch,
            ToolCatalog.fetchURL,
            ToolCatalog.calculator,
            ToolCatalog.readAttachment,
            ToolCatalog.writeFile,
            ToolCatalog.readFile,
            ToolCatalog.listWorkspaceFiles,
            ToolCatalog.editFile,
            ToolCatalog.searchFiles,
            ToolCatalog.runCommand,
            ToolCatalog.askUser,
            ToolCatalog.updatePlan,
            ToolCatalog.getSchedule,
            ToolCatalog.systemStatus,
            ToolCatalog.readClipboard,
            ToolCatalog.saveMemory,
            ToolCatalog.searchMemory,
            ToolCatalog.editMemory,
        ]
    }

    func testPlanModeWithholdsExactlyTheWriteTools() {
        let names = Set(PlanMode.filter(everyTool).map(\.name))
        for withheld in [ToolCatalog.writeFile, ToolCatalog.editFile, ToolCatalog.saveMemory, ToolCatalog.editMemory] {
            XCTAssertFalse(names.contains(withheld.name), "\(withheld.name) must not be attached while planning")
        }
    }

    /// The other direction: a plan written without looking at the code is
    /// the failure this mode exists to prevent, so every read, search, and
    /// asking tool has to survive the filter.
    func testPlanModeKeepsTheReadAndExploreTools() {
        let names = Set(PlanMode.filter(everyTool).map(\.name))
        let mustSurvive = [
            ToolCatalog.readFile,
            ToolCatalog.searchFiles,
            ToolCatalog.listWorkspaceFiles,
            ToolCatalog.searchConversations,
            ToolCatalog.searchMemory,
            ToolCatalog.webSearch,
            ToolCatalog.fetchURL,
            ToolCatalog.readAttachment,
            ToolCatalog.calculator,
            ToolCatalog.runCommand,
            ToolCatalog.askUser,
            ToolCatalog.updatePlan,
            ToolCatalog.getSchedule,
            ToolCatalog.systemStatus,
            ToolCatalog.readClipboard,
        ]
        for tool in mustSurvive {
            XCTAssertTrue(names.contains(tool.name), "\(tool.name) must stay attached while planning")
        }
        // And nothing else went missing along the way.
        XCTAssertEqual(names.count, everyTool.count - 4)
    }

    /// run_command stays attached (exploration is most of what informs a
    /// plan) and is gated per call instead — so the refusal is where the
    /// constraint actually lives.
    func testPlanModeRefusesCommandsThatAreNotReadOnly() {
        for command in ["cargo build", "swift build", "rm -rf build", "npm install", "git commit -m x"] {
            XCTAssertNotNil(PlanMode.commandRefusal(for: command), "\(command) must be refused while planning")
        }
    }

    func testPlanModeStillRunsReadOnlyCommands() {
        for command in ["ls -la", "cat README.md", "rg TODO", "git status", "git log --oneline -5"] {
            XCTAssertNil(PlanMode.commandRefusal(for: command), "\(command) should still run while planning")
        }
    }

    /// The one-time offer is capped per conversation, so a false positive
    /// spends the user's only chance to be asked. Short asks never qualify.
    func testSubstantialHeuristicIgnoresOrdinaryMessages() {
        XCTAssertFalse(PlanMode.looksSubstantial("what does this function do?"))
        XCTAssertFalse(PlanMode.looksSubstantial("thanks!"))
        XCTAssertFalse(PlanMode.looksSubstantial("implement it"))
    }

    func testSubstantialHeuristicCatchesMultiStepWork() {
        XCTAssertTrue(PlanMode.looksSubstantial("""
        Please refactor the provider layer so Anthropic and Codex stop \
        sharing the OpenAI request path, then update the tests that \
        assumed one shared encoder, and make sure the cached catalogs \
        still decode.
        """))
        XCTAssertTrue(PlanMode.looksSubstantial("""
        1. read the current settings screen and note what each toggle does
        2. pull the related toggles into one card
        3. wire the new default through the model
        4. update the footer copy so it matches what it actually does
        """))
    }
}
