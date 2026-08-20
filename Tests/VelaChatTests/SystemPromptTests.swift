import XCTest
@testable import VelaChat

/// The prompt is assembled per request, and the gating is the point:
/// telling a model about capabilities it doesn't have is how it ends up
/// promising work it can't do.
@MainActor
final class SystemPromptTests: XCTestCase {
    private func compose(_ mutate: (inout SystemPrompt.Context) -> Void) -> String {
        var context = SystemPrompt.Context()
        context.modelID = "test-model"
        context.providerName = "TestProvider"
        mutate(&context)
        return SystemPrompt.compose(context)
    }

    func testEnvironmentIsAlwaysPresent() {
        let prompt = compose { _ in }
        XCTAssertTrue(prompt.contains("# Environment"))
        XCTAssertTrue(prompt.contains("test-model"))
        XCTAssertTrue(prompt.contains("TestProvider"))
    }

    func testToolSectionOnlyWithTools() {
        XCTAssertFalse(compose { _ in }.contains("# Tools"))
        let withTools = compose { $0.tools = [ToolCatalog.calculator] }
        XCTAssertTrue(withTools.contains("# Tools"))
        XCTAssertTrue(withTools.contains(ToolCatalog.calculator.name))
    }

    func testAgentGuidanceOnlyWithAgentTools() {
        XCTAssertFalse(compose { $0.tools = [ToolCatalog.calculator] }.contains("# Working autonomously"))
        let withShell = compose { $0.tools = [ToolCatalog.runCommand] }
        XCTAssertTrue(withShell.contains("# Working autonomously"))
        XCTAssertTrue(withShell.contains("exit code"))
    }

    func testWorkspaceGuidanceOnlyWithFileTools() {
        XCTAssertFalse(compose { $0.tools = [ToolCatalog.calculator] }.contains("# Files and code"))
        let withFiles = compose { $0.tools = [ToolCatalog.writeFile] }
        XCTAssertTrue(withFiles.contains("# Files and code"))
        // The rule that stops the model dumping a file it just wrote.
        XCTAssertTrue(withFiles.contains("do NOT paste its contents back"))
    }

    func testAttachedFolderAddsCareInstruction() {
        let synthetic = compose { $0.tools = [ToolCatalog.writeFile] }
        XCTAssertFalse(synthetic.contains("real folder of the user's"))
        let attached = compose {
            $0.tools = [ToolCatalog.writeFile]
            $0.hasAttachedFolder = true
        }
        XCTAssertTrue(attached.contains("real folder of the user's"))
    }

    func testMemoryDutiesOnlyWithMemory() {
        XCTAssertFalse(compose { _ in }.contains("# Memory"))
        XCTAssertTrue(compose { $0.hasMemories = true }.contains("# Memory"))
    }

    /// A small window must not be filled with our own preamble, and what
    /// survives has to be the load-bearing part, not a random subset.
    func testSmallContextWindowDropsLowPrioritySections() {
        let full = compose {
            $0.tools = [ToolCatalog.writeFile, ToolCatalog.runCommand]
            $0.hasMemories = true
        }
        let squeezed = compose {
            $0.tools = [ToolCatalog.writeFile, ToolCatalog.runCommand]
            $0.hasMemories = true
            $0.contextWindow = 4_000
        }
        XCTAssertLessThan(squeezed.count, full.count)
        XCTAssertTrue(squeezed.contains("# Environment"))
        XCTAssertTrue(squeezed.contains("# Tools"))
        XCTAssertFalse(squeezed.contains("# Artifacts"))
    }

    /// The budget used `continue`, so a section that didn't fit was skipped
    /// and smaller, lower-priority sections could still slip in behind it —
    /// producing a squeezed prompt that had lost its tool inventory but
    /// still carried the artifacts guidance. Pin both halves of the fix:
    /// the required sections survive any budget, and nothing below the
    /// first section that doesn't fit sneaks in.
    func testRequiredSectionsSurviveAnAbsurdlySmallWindow() {
        let squeezed = compose {
            $0.tools = [ToolCatalog.writeFile, ToolCatalog.runCommand]
            $0.hasMemories = true
            $0.contextWindow = 1
        }
        XCTAssertTrue(squeezed.contains("# Environment"), "environment is not droppable")
        XCTAssertTrue(squeezed.contains("# Tools"), "the tool inventory is not droppable")
        XCTAssertTrue(squeezed.contains(ToolCatalog.runCommand.name), "a listed tool must survive with its section")
    }

    func testNothingLeapfrogsADroppedSection() {
        let squeezed = compose {
            $0.tools = [ToolCatalog.writeFile, ToolCatalog.runCommand]
            $0.hasMemories = true
            $0.contextWindow = 4_000
        }
        // Artifacts is the lowest-priority section. If it appears while a
        // higher-priority optional section was dropped, ordering was not
        // honoured.
        let keptArtifacts = squeezed.contains("# Artifacts")
        let keptMemory = squeezed.contains("# Memory")
        XCTAssertFalse(keptArtifacts && !keptMemory, "a lower-priority section outranked a dropped higher-priority one")
    }

    func testLargeWindowKeepsEverything() {
        let prompt = compose {
            $0.tools = [ToolCatalog.writeFile]
            $0.hasMemories = true
            $0.contextWindow = 200_000
        }
        XCTAssertTrue(prompt.contains("# Artifacts"))
        XCTAssertTrue(prompt.contains("# Memory"))
    }
}
