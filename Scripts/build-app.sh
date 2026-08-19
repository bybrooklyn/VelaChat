#!/usr/bin/env bash
# Build a runnable VelaChat.app bundle with SwiftPM and the macOS Command Line
# Tools. Xcode is not required.
#
#   ./Scripts/build-app.sh            # debug build
#   ./Scripts/build-app.sh --release  # release build

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="debug"
if [[ "${1:-}" == "--release" ]]; then
  CONFIG="release"
fi

echo "▶ Building VelaChat ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$ROOT/.build/$CONFIG/VelaChat"
APP="$ROOT/build/VelaChat.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/VelaChat"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VelaChat</string>
    <key>CFBundleDisplayName</key>
    <string>VelaChat</string>
    <key>CFBundleIdentifier</key>
    <string>com.velachat.desktop</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>VelaChat</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>VelaChat reads your upcoming events, and creates events you ask for, only when the AI uses its schedule tool at your request.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>VelaChat reads open reminders, and creates reminders you ask for, only when the AI uses its schedule tool at your request.</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 VelaChat contributors</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

IDENTITY="VelaChat Local Dev"
if security find-certificate -c "$IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  # A stable local identity keeps the signature identical across rebuilds,
  # so Keychain items stay trusted for VelaChat instead of re-prompting for
  # a password every time. Run Scripts/setup-signing.sh once to create it.
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || true
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "✅ Built $APP"
echo "   Launch with: open \"$APP\""
