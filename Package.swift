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
        .executableTarget(
            name: "VelaChat",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "HighlightSwift", package: "HighlightSwift"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/VelaChat"
        ),
        .testTarget(
            name: "VelaChatTests",
            dependencies: ["VelaChat"],
            path: "Tests/VelaChatTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
