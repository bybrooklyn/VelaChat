#!/usr/bin/env bash
# One-time setup: creates a stable, locally-trusted code-signing certificate
# in your login keychain so VelaChat.app keeps the same signing identity
# across every rebuild.
#
# Without this, `build-app.sh` ad-hoc signs the app (`codesign --sign -`),
# which hashes the binary itself into the signature — so every rebuild
# produces a *different* identity. Keychain ties a stored item's access
# control to the exact identity that created it, so after any rebuild macOS
# no longer recognizes VelaChat as "the same app" and prompts for your
# password to allow it access again. A stable identity fixes that.
#
# Safe to re-run: skips creation if the certificate already exists.

set -euo pipefail

IDENTITY="VelaChat Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "✅ '$IDENTITY' certificate already exists in the login keychain. Nothing to do."
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

CONFIG="$WORKDIR/codesign.cnf"
cat > "$CONFIG" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $IDENTITY

[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

echo "▶ Generating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -days 3650 -config "$CONFIG" -extensions ext


# macOS's PKCS#12 importer only understands the legacy RC2/3DES+SHA1
# encryption OpenSSL used to default to — OpenSSL 3's new AES-256/SHA-256
# default fails to import with "MAC verification failed", so it's pinned
# explicitly here.
openssl pkcs12 -export \
  -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
  -out "$WORKDIR/identity.p12" -passout pass:velachat \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1

echo "▶ Importing it into your login keychain…"
security import "$WORKDIR/identity.p12" -k "$KEYCHAIN" -P velachat -A -T /usr/bin/codesign

echo "▶ Trusting it for code signing…"
security add-trusted-cert -d -p codeSign -k "$KEYCHAIN" "$WORKDIR/cert.pem"

echo "✅ Created and trusted '$IDENTITY'. Future builds (\`just app\`) will sign"
echo "   with this stable identity instead of ad-hoc signing, so Keychain"
echo "   stops re-prompting for a password after every rebuild."
