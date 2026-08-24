import XCTest
@testable import VelaCore

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

    /// The "# Tools" section body, so an assertion about it can't be
    /// satisfied (or broken) by wording that lives in another section.
    private func toolSection(_ prompt: String) -> String? {
        guard let start = prompt.range(of: "# Tools") else { return nil }
        let rest = prompt[start.lowerBound...]
        guard let next = rest.range(of: "\n\n# ") else { return String(rest) }
        return String(rest[..<next.lowerBound])
    }

    func testToolSectionOnlyWithTools() {
        XCTAssertNil(toolSection(compose { _ in }))
        let section = toolSection(compose { $0.tools = [ToolCatalog.calculator] })
        XCTAssertNotNil(section)
        // The directive half is the load-bearing part: it names *when* to
        // reach for a tool, which is what stopped the model answering from
        // training data with tools sitting attached and unused.
        XCTAssertTrue(section?.contains("Reach for a tool on your own initiative") == true)
        XCTAssertTrue(section?.contains("never fake a call in plain text") == true)
    }

    /// The section used to list every attached tool as
    /// "- name: summary. guidance" — the same information the real tool
    /// schemas already carry, in a form the model could read back. It did:
    /// asked "what can you do?", it recited its own tooling as a
    /// categorized brochure. Descriptions live in the tool definitions
    /// (`ToolCatalog.Definition.wireDescription`) now, and nothing in the
    /// prompt enumerates them.
    func testToolSectionDoesNotListIndividualTools() {
        // Tools no other section mentions by name, so a hit here can only
        // have come from an inventory.
        let tools = [ToolCatalog.calculator, ToolCatalog.webSearch, ToolCatalog.getSchedule]
        let section = toolSection(compose { $0.tools = tools })
        XCTAssertNotNil(section)
        for tool in tools {
            XCTAssertFalse(section?.contains(tool.name) == true, "\(tool.name) is listed in the prompt")
            XCTAssertFalse(section?.contains(tool.guidance) == true, "\(tool.name)'s guidance is duplicated into the prompt")
        }
    }

    /// "What are you?" must get prose about outcomes, not a capability
    /// inventory — the replacement for the deleted list.
    func testToolSectionAnswersCapabilityQuestionsInProse() {
        let section = toolSection(compose { $0.tools = [ToolCatalog.calculator] })
        XCTAssertTrue(section?.contains("Asked what you are or what you can do") == true)
        XCTAssertTrue(section?.contains("never a list of tool names") == true)
    }

    func testNativeSearchIsAnnouncedOnlyWhenPresent() {
        let without = toolSection(compose { $0.tools = [ToolCatalog.calculator] })
        XCTAssertFalse(without?.contains("natively") == true)
        let with = toolSection(compose {
            $0.tools = [ToolCatalog.calculator]
            $0.nativeSearch = true
        })
        XCTAssertTrue(with?.contains("natively") == true)
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
        XCTAssertTrue(squeezed.contains("# Tools"), "the tool guidance is not droppable")
        // It used to be enough to look for a listed tool name here. The
        // section no longer lists them, so pin the rule that actually has
        // to survive: when to reach for a tool at all.
        XCTAssertTrue(squeezed.contains("Reach for a tool on your own initiative"), "the when-to-use rule must survive with its section")
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
