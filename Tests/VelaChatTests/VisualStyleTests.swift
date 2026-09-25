import XCTest
import AppKit
@testable import VelaChat
@testable import VelaCore

final class VisualStyleTests: XCTestCase {
    func testEveryPrimaryAccentMeetsTextContrast() throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: DefaultsKey.accentPreset)
        defer {
            if let original {
                defaults.set(original, forKey: DefaultsKey.accentPreset)
            } else {
                defaults.removeObject(forKey: DefaultsKey.accentPreset)
            }
        }

        for preset in AccentPreset.allCases {
            AccentPreset.current = preset
            let ratio = try contrastRatio(
                foreground: NSColor(Theme.accentForeground),
                background: NSColor(Theme.accentStrong)
            )
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(preset.displayName) primary controls need readable text")
        }
    }

    private func contrastRatio(foreground: NSColor, background: NSColor) throws -> Double {
        let foreground = try XCTUnwrap(foreground.usingColorSpace(.sRGB))
        let background = try XCTUnwrap(background.usingColorSpace(.sRGB))
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: NSColor) -> Double {
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    func testRunningConversationUIHasNoLightningAndUsesRowSpinner() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebar = try String(contentsOf: root.appendingPathComponent("Sources/VelaChat/Views/SidebarView.swift"))
        let runs = try String(contentsOf: root.appendingPathComponent("Sources/VelaChat/Views/BackgroundRunsView.swift"))
        XCTAssertFalse(sidebar.contains("bolt.fill"))
        XCTAssertFalse(runs.contains("bolt.fill"))
        XCTAssertTrue(sidebar.contains("ProgressView()"))
        XCTAssertTrue(runs.contains("Running conversations"))
    }
}
