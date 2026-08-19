# VelaChatTests

These run in CI, not on the development machine.

VelaChat builds with the macOS **Command Line Tools** toolchain (no
Xcode — see the vendored packages in `Vendor/` for the other consequence
of that). XCTest ships with Xcode, so `swift build --build-tests` fails
locally with "no such module 'XCTest'". Plain `swift build` and
`Scripts/build-app.sh` are unaffected: SwiftPM only builds test targets
when asked.

GitHub's macOS runners have full Xcode, so `swift test` runs there and
gates every push and pull request.
