#!/usr/bin/env bash
# Sign a built VelaChat.zip with Sparkle's EdDSA key and write/refresh
# appcast.xml.
#
# VelaChat has no Apple Developer ID, so the app itself is ad-hoc signed and
# Gatekeeper will ask for a right-click → Open on first launch. Update
# integrity does NOT rely on that signature: Sparkle verifies each update
# against the EdDSA public key baked into Info.plist (SUPublicEDKey), and
# only whoever holds the private key can publish a valid one.
#
#   SPARKLE_PRIVATE_KEY=... ./Scripts/sign-update.sh VelaChat.zip
#
# Generate the keypair once with Sparkle's generate_keys tool, then:
#   gh secret set SPARKLE_PRIVATE_KEY < private.key

set -euo pipefail

ARCHIVE="${1:-VelaChat.zip}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST="$ROOT/appcast.xml"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "✗ $ARCHIVE not found — build it first (Scripts/build-app.sh --release)." >&2
  exit 1
fi

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "⚠ SPARKLE_PRIVATE_KEY is not set — skipping update signing." >&2
  echo "  The release will still publish; it just won't be offered as an" >&2
  echo "  automatic update until a signed appcast entry exists." >&2
  exit 0
fi

# Sparkle's signing tool ships in its release archive rather than the SwiftPM
# checkout, so fetch it on demand and cache it under .build.
TOOLS_DIR="$ROOT/.build/sparkle-tools"
SIGN_UPDATE="$TOOLS_DIR/bin/sign_update"
if [[ ! -x "$SIGN_UPDATE" ]]; then
  SPARKLE_VERSION="${SPARKLE_VERSION:-2.6.4}"
  echo "▶ Fetching Sparkle $SPARKLE_VERSION tools…"
  mkdir -p "$TOOLS_DIR"
  curl -sSfL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
    | tar -xJ -C "$TOOLS_DIR"
fi

SIGNATURE_LINE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" "$ARCHIVE" --ed-key-file -)"
# sign_update prints: sparkle:edSignature="…" length="…"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNATURE_LINE")"
LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIGNATURE_LINE")"
if [[ -z "$SIGNATURE" ]]; then
  echo "✗ Could not sign the update — sign_update said: $SIGNATURE_LINE" >&2
  exit 1
fi

VERSION="${GITHUB_REF_NAME:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)}"
SHORT_VERSION="${VERSION#v}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
REPO="${GITHUB_REPOSITORY:-bybrooklyn/VelaChat}"
URL="https://github.com/${REPO}/releases/download/${VERSION}/VelaChat.zip"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>VelaChat</title>
    <description>Updates for VelaChat</description>
    <language>en</language>
    <item>
      <title>${SHORT_VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="${URL}"
                 sparkle:edSignature="${SIGNATURE}"
                 length="${LENGTH}"
                 type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

echo "✅ Signed $ARCHIVE and wrote $APPCAST for $VERSION"
