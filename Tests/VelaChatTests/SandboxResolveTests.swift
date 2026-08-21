import XCTest
@testable import VelaCore

/// `SandboxManager.resolve` is the only thing standing between a
/// model-supplied path and the rest of the disk — there is no process
/// sandbox behind it (see Sandbox.swift). A regression here is a security
/// regression.
final class SandboxResolveTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vela-sandbox-tests-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("creds.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOrdinaryPathsResolve() {
        XCTAssertNotNil(SandboxManager.resolve("notes.txt", in: workspace))
        XCTAssertNotNil(SandboxManager.resolve("sub/deep/new.txt", in: workspace))
    }

    func testEscapesAreRefused() {
        XCTAssertNil(SandboxManager.resolve("../outside/creds.txt", in: workspace))
        XCTAssertNil(SandboxManager.resolve("/etc/passwd", in: workspace))
        XCTAssertNil(SandboxManager.resolve("", in: workspace))
    }

    /// A symlink inside the workspace passed the old textual prefix check —
    /// the base resolved symlinks but the candidate did not, so reads and
    /// writes followed the link straight out. A user-attached project
    /// folder as workspace root makes this an ordinary situation, not an
    /// exotic one.
    func testSymlinkOutOfWorkspaceIsRefused() throws {
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        XCTAssertNil(SandboxManager.resolve("link/creds.txt", in: workspace))
        // Writing a *new* file through the link is the same escape.
        XCTAssertNil(SandboxManager.resolve("link/planted.txt", in: workspace))
    }

    /// A symlink that stays inside the workspace is still usable.
    func testSymlinkWithinWorkspaceIsAllowed() throws {
        let inner = workspace.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("shortcut"),
            withDestinationURL: inner
        )
        XCTAssertNotNil(SandboxManager.resolve("shortcut/file.txt", in: workspace))
    }
}
