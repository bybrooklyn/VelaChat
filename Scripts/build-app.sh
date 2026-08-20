#!/usr/bin/env bash
# Build a runnable VelaChat.app bundle with SwiftPM and the macOS Command Line
# Tools. Xcode is not required.
#
#   ./Scripts/build-app.sh            # debug build
#   ./Scripts/build-app.sh --release  # release build

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Marketing version from the newest tag, build number from the commit count —
# Sparkle compares CFBundleVersion, so it must increase monotonically.
SHORT_VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
SHORT_VERSION="${SHORT_VERSION:-1.0.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
# VelaChat's Sparkle update-signing public key. The matching private
# key exists only as the SPARKLE_PRIVATE_KEY GitHub secret, so only CI
# can publish an update this app will accept.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-sYsviqSat9JcwnMdI6EWW50orQ9wZpsTeiRlxzeMVUE=}"
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
    <string>__BUILD_NUMBER__</string>
    <key>CFBundleShortVersionString</key>
    <string>__SHORT_VERSION__</string>
    <key>CFBundleExecutable</key>
    <string>VelaChat</string>
    <key>CFBundleIconFile</key>
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
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/bybrooklyn/VelaChat/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>__SPARKLE_PUBLIC_KEY__</string>
    <key>SUEnableInstallerLauncherService</key>
    <false/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# Placeholders filled after the heredoc so the plist stays a literal block.
/usr/bin/sed -i '' \
  -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|" \
  -e "s|__SHORT_VERSION__|$SHORT_VERSION|" \
  -e "s|__SPARKLE_PUBLIC_KEY__|$SPARKLE_PUBLIC_KEY|" \
  "$CONTENTS/Info.plist"

# The dock icon is generated from the same marque the app draws in-app
# (Scripts/make-icon.swift reads its colors from Theme.swift's teal family),
# so the two cannot drift apart. iconutil needs the .iconset laid out with
# Apple's exact filenames, which the generator produces.
# The .icns is committed rather than generated here on purpose. Building it
# needs AppKit to rasterize an SF Symbol, and doing that on a CI runner with
# no window server is exactly the kind of thing that works locally and fails
# in the cloud. Regenerate deliberately with `just icon` after changing the
# marque or the theme colors.
if [[ ! -f "$ROOT/Resources/VelaChat.icns" ]]; then
  echo "✗ Resources/VelaChat.icns is missing — run \`just icon\` to rebuild it." >&2
  exit 1
fi
cp "$ROOT/Resources/VelaChat.icns" "$RESOURCES/VelaChat.icns"

# Sparkle is a dynamic framework: it has to travel inside the bundle AND
# the binary needs an rpath pointing at it. Without the rpath the app dies
# at launch with "Library not loaded: @rpath/Sparkle.framework" — a failure
# that never shows up in a `swift build`, only in the shipped bundle.
SPARKLE_FRAMEWORK="$(find "$ROOT/.build" -maxdepth 6 -name "Sparkle.framework" -type d 2>/dev/null | head -1)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$CONTENTS/Frameworks"
  cp -R "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/VelaChat" 2>/dev/null || true
fi

# Every @rpath dependency must resolve inside the bundle. This is the check
# that would have caught the missing rpath above, so it runs on every build
# rather than living in a comment.
MISSING=0
while read -r dep; do
  case "$dep" in
    @rpath/*)
      framework_path="$CONTENTS/Frameworks/${dep#@rpath/}"
      loader_path="$MACOS/${dep#@rpath/}"
      if [[ ! -f "$framework_path" && ! -f "$loader_path" ]]; then
        echo "✗ Unresolved dependency: $dep" >&2
        MISSING=1
      fi
      ;;
  esac
done < <(otool -L "$MACOS/VelaChat" | awk 'NR>1 {print $1}')
if [[ "$MISSING" -eq 1 ]]; then
  echo "✗ The bundle would crash at launch — fix the framework copy/rpath above." >&2
  exit 1
fi

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
