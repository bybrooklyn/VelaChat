import XCTest
import AppKit
@testable import VelaCore

/// Every SF Symbol the app names must actually exist.
///
/// A wrong symbol name is invisible to the compiler and silent at runtime:
/// SwiftUI draws an empty box where the glyph should be and carries on. That
/// is exactly how `"thought.bubble"` — not a symbol on any macOS — shipped on
/// the reasoning row, which meant a blank grey square at the top of nearly
/// every reply that involved thinking.
///
/// So the check is a test rather than a convention: the sources are scanned
/// for symbol-name literals and each one is resolved through AppKit.
final class SymbolExistenceTests: XCTestCase {

    /// The argument labels that always take an SF Symbol name in this
    /// codebase: SwiftUI's own two, plus `ActivityRow`'s.
    private let symbolArguments = ["systemName", "systemImage", "symbol"]

    func testEverySymbolNamedInTheSourcesExists() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VelaChatTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(
            pattern: "(?:\(symbolArguments.joined(separator: "|")))\\s*:\\s*\"([a-z0-9][a-z0-9._]*)\""
        )

        var checked: Set<String> = []
        var missing: [String: String] = [:]   // symbol → file it appears in
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[nameRange])
                guard checked.insert(name).inserted else { continue }
                if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
                    missing[name] = url.lastPathComponent
                }
            }
        }

        // A sanity floor: if the scan silently stops matching (a refactor to
        // a different argument label, say), an empty result would pass this
        // test forever while checking nothing.
        XCTAssertGreaterThan(checked.count, 40, "the symbol scan found suspiciously few names — has the call shape changed?")
        XCTAssertTrue(
            missing.isEmpty,
            "These SF Symbols don't exist and will render as empty boxes: "
                + missing.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: ", ")
        )
    }

    /// The activity timeline builds its glyphs in a switch rather than at a
    /// call site, so the scan above cannot see them.
    func testEveryActivityKindGlyphExists() {
        for kind in ActivityKind.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil),
                "\(kind.rawValue) names \"\(kind.symbol)\", which is not an SF Symbol"
            )
        }
    }
}
