// swift-tools-version: 5.9

import PackageDescription

// Vendored from https://github.com/weichsel/ZIPFoundation at tag 0.9.20.
// Unmodified sources; the upstream test target is dropped (its fixtures
// are large and VelaChat's own tests cover what we use), and the privacy
// manifest is declared explicitly so SwiftPM bundles it.
let package = Package(
    name: "ZIPFoundation",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ZIPFoundation", targets: ["ZIPFoundation"])
    ],
    targets: [
        .target(
            name: "ZIPFoundation",
            resources: [.process("Resources")]
        )
    ]
)
