// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VelaChat",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0"),
        // Vendored locally with two small patches (see Vendor/*/Sources for
        // the exact changes): both packages use Xcode-only SwiftUI macros
        // (@Entry, #Preview) whose plugins aren't available under a Command
        // Line Tools-only toolchain. Swap back to the upstream git URL if
        // building with full Xcode.
        .package(path: "Vendor/HighlightSwift"),
        .package(path: "Vendor/KeyboardShortcuts"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Non-UI logic (protocol layers, pure data models, cost/redaction math, tool
        // dispatch). No SwiftUI/AppKit — testable on the Command-Line-Tools toolchain
        // without XCTest ever touching a view. Extracted subsystem-by-subsystem from
        // VelaChat; see AGENTS.md / velachat-plan-v2.md §1.1 for the extraction plan.
        .target(
            name: "VelaCore",
            path: "Sources/VelaCore"
        ),
        .executableTarget(
            name: "VelaChat",
            dependencies: [
                "VelaCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "HighlightSwift", package: "HighlightSwift"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/VelaChat"
        ),
        .testTarget(
            name: "VelaChatTests",
            dependencies: ["VelaChat", "VelaCore"],
            path: "Tests/VelaChatTests",
            // Read via `#filePath` at runtime, not bundled as resources —
            // excluded so SwiftPM stops warning about unhandled files.
            exclude: ["README.md", "Fixtures"]
        )
    ],
    swiftLanguageModes: [.v5]
)
