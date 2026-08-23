import XCTest
@testable import VelaCore

/// §6 folder attach: the .gitignore subset's parse/match behavior, the
/// project-workspace resolution chain (bookmark → path → nil), and the
/// saved-history migration that lets pre-bookmark attachments keep working.
final class FolderAttachTests: XCTestCase {

    // MARK: - .gitignore parsing

    func testCommentsAndBlankLinesAreSkipped() {
        let rules = GitIgnore.parse("# a comment\n\n  \nbuild/\n")
        XCTAssertEqual(rules.count, 1)
    }

    func testNegationAndDirectoryOnlyFlags() {
        let rules = GitIgnore.parse("!keep.txt\ndir/\n")
        XCTAssertEqual(rules[0].negated, true)
        XCTAssertEqual(rules[1].directoryOnly, true)
    }

    func testAnchoringRules() {
        let rules = GitIgnore.parse("/top.txt\nsub/thing.txt\nanyname.txt")
        XCTAssertEqual(rules[0].anchored, true)
        XCTAssertEqual(rules[1].anchored, true)
        XCTAssertEqual(rules[2].anchored, false)
    }

    // MARK: - .gitignore matching

    private func ignores(_ text: String, _ path: String) -> Bool {
        GitIgnore.ignores(GitIgnore.parse(text), relativePath: path)
    }

    func testBareNameMatchesAtAnyDepth() {
        let gitignore = "secret.env"
        XCTAssertTrue(ignores(gitignore, "secret.env"))
        XCTAssertTrue(ignores(gitignore, "config/secret.env"))
        XCTAssertFalse(ignores(gitignore, "environment.txt"))
    }

    func testStarDoesNotCrossDirectoriesButDoubleStarDoes() {
        XCTAssertTrue(ignores("/*.txt", "root.txt"))
        XCTAssertFalse(ignores("/*.txt", "sub/root.txt"))
        XCTAssertTrue(ignores("**/logs", "a/b/logs"))
        XCTAssertTrue(ignores("**/logs", "logs"))
    }

    func testDirectoryOnlyMatchesThroughAncestors() {
        let gitignore = "build/"
        XCTAssertTrue(ignores(gitignore, "build/out.o"))
        XCTAssertTrue(ignores(gitignore, "build"))
        XCTAssertFalse(ignores(gitignore, "src/buildhelper.o"))
    }

    func testLastMatchingRuleWinsIncludingNegation() {
        let gitignore = """
        *.log
        !important.log
        """
        XCTAssertTrue(ignores(gitignore, "debug.log"))
        XCTAssertFalse(ignores(gitignore, "important.log"))
    }

    func testAnchoredPatternDoesNotMatchDeeper() {
        let gitignore = "/node_modules/"
        XCTAssertTrue(ignores(gitignore, "node_modules/x.js"))
        XCTAssertFalse(ignores(gitignore, "packages/node_modules/x.js"))
    }

    func testQuestionMarkStaysWithinOneSegment() {
        XCTAssertTrue(ignores("file?.txt", "fileA.txt"))
        XCTAssertFalse(ignores("file?.txt", "fileA/B.txt"))
    }

    // MARK: - Project workspace resolution chain

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-folder-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testResolvesByPathWhenBookmarkAbsent() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = ProjectWorkspace.resolve(ProjectWorkspace(bookmark: nil, path: dir.path))
        XCTAssertEqual(resolved?.standardizedFileURL.path, dir.standardizedFileURL.path)
    }

    func testMissingFolderResolvesToNil() {
        let missing = NSTemporaryDirectory() + "vela-does-not-exist-\(UUID().uuidString)"
        XCTAssertNil(ProjectWorkspace.resolve(ProjectWorkspace(bookmark: nil, path: missing)))
    }

    func testBookmarkRoundTripResolvesToTheSameFolder() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try dir.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let resolved = ProjectWorkspace.resolve(ProjectWorkspace(bookmark: bookmark, path: "/definitely/not/here"))
        XCTAssertEqual(resolved?.standardizedFileURL.path, dir.standardizedFileURL.path)
    }

    // MARK: - Saved history migration

    func testLegacyPathHistoryDecodesIntoProjectWorkspace() throws {
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "title": "t",
          "messages": [],
          "model": "",
          "createdAt": 700000000.0,
          "updatedAt": 700000000.0,
          "workspaceRootPath": "/tmp/some-project"
        }
        """
        let saved = try JSONDecoder().decode(SavedConversation.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(saved.projectWorkspace?.path, "/tmp/some-project")
        XCTAssertNil(saved.projectWorkspace?.bookmark)
    }

    func testNewShapeEncodesProjectWorkspaceNotLegacyKey() throws {
        let saved = SavedConversation(
            id: UUID(), title: "t", messages: [], providerID: nil, model: "",
            createdAt: Date(timeIntervalSince1970: 700_000_000),
            updatedAt: Date(timeIntervalSince1970: 700_000_000),
            projectWorkspace: ProjectWorkspace(bookmark: Data("bm".utf8), path: "/tmp/p")
        )
        let data = try JSONEncoder().encode(saved)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["workspaceRootPath"], "the legacy key must never be written again")
        let workspace = try XCTUnwrap(object["projectWorkspace"] as? [String: Any])
        XCTAssertEqual(workspace["path"] as? String, "/tmp/p")
    }
}
