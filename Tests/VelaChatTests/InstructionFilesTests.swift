import XCTest
@testable import VelaCore

/// All four resolution cases plus the symlink. The symlink case is the
/// one that matters: VelaChat's own repo ships `CLAUDE.md` as a symlink to
/// `AGENTS.md`, so getting it wrong duplicates the entire instruction set
/// into the model's context.
final class InstructionFilesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vela-instructions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func names(_ resolution: InstructionFiles.Resolution) -> [String] {
        resolution.files.map(\.lastPathComponent)
    }

    // MARK: The four cases

    func testNeitherFileExists() {
        let resolution = InstructionFiles.resolve(in: directory)
        XCTAssertTrue(resolution.isEmpty)
        XCTAssertFalse(resolution.collapsedSymlink)
    }

    func testOnlyAgentsExists() throws {
        try write("AGENTS.md", "agents rules")
        XCTAssertEqual(names(InstructionFiles.resolve(in: directory)), ["AGENTS.md"])
    }

    func testOnlyClaudeExists() throws {
        try write("CLAUDE.md", "claude rules")
        XCTAssertEqual(names(InstructionFiles.resolve(in: directory)), ["CLAUDE.md"])
    }

    /// Two genuinely different files: both are real instructions and both
    /// must be delivered.
    func testBothExistAsDistinctFiles() throws {
        try write("AGENTS.md", "agents rules")
        try write("CLAUDE.md", "different claude rules")
        let resolution = InstructionFiles.resolve(in: directory)
        XCTAssertEqual(names(resolution), ["AGENTS.md", "CLAUDE.md"])
        XCTAssertFalse(resolution.collapsedSymlink)
    }

    // MARK: The symlink case

    func testClaudeSymlinkedToAgentsCollapsesToOne() throws {
        try write("AGENTS.md", "agents rules")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("CLAUDE.md"),
            withDestinationURL: directory.appendingPathComponent("AGENTS.md")
        )
        let resolution = InstructionFiles.resolve(in: directory)
        XCTAssertEqual(names(resolution), ["AGENTS.md"])
        XCTAssertTrue(resolution.collapsedSymlink)
    }

    /// A relative symlink is the form `ln -s AGENTS.md CLAUDE.md` actually
    /// creates, and is what VelaChat's own repo has.
    func testRelativeSymlinkAlsoCollapses() throws {
        try write("AGENTS.md", "agents rules")
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("CLAUDE.md").path,
            withDestinationPath: "AGENTS.md"
        )
        let resolution = InstructionFiles.resolve(in: directory)
        XCTAssertEqual(names(resolution), ["AGENTS.md"])
        XCTAssertTrue(resolution.collapsedSymlink)
    }

    /// A hard link is the same file too, even though neither path is a
    /// symlink.
    func testHardLinkCollapses() throws {
        try write("AGENTS.md", "agents rules")
        try FileManager.default.linkItem(
            at: directory.appendingPathComponent("AGENTS.md"),
            to: directory.appendingPathComponent("CLAUDE.md")
        )
        XCTAssertEqual(names(InstructionFiles.resolve(in: directory)), ["AGENTS.md"])
    }

    /// A symlink pointing nowhere is not readable by Claude Code either,
    /// so it must not be treated as present.
    func testBrokenSymlinkIsIgnored() throws {
        try write("AGENTS.md", "agents rules")
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("CLAUDE.md").path,
            withDestinationPath: "NOT_THERE.md"
        )
        let resolution = InstructionFiles.resolve(in: directory)
        XCTAssertEqual(names(resolution), ["AGENTS.md"])
        XCTAssertFalse(resolution.collapsedSymlink)
    }

    // MARK: Materializing

    func testMaterializeWritesRealContentNotSymlinks() throws {
        try write("AGENTS.md", "the rules")
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("CLAUDE.md").path,
            withDestinationPath: "AGENTS.md"
        )
        let sandbox = directory.appendingPathComponent("sandbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let written = try InstructionFiles.materialize(from: directory, into: sandbox)
        XCTAssertEqual(written, ["AGENTS.md"])

        let copied = sandbox.appendingPathComponent("AGENTS.md")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "the rules")
        // Must be a real file — a symlink here would let the sandbox write
        // back into the user's actual project.
        let type = try FileManager.default.attributesOfItem(atPath: copied.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
    }

    func testMaterializeWithNothingToCopyIsNotAnError() throws {
        let sandbox = directory.appendingPathComponent("sandbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        XCTAssertEqual(try InstructionFiles.materialize(from: directory, into: sandbox), [])
    }
}
