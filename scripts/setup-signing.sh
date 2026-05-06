#!/usr/bin/env bash
# setup-signing.sh — create a stable self-signed code-signing identity
# in the user's login keychain. With ad-hoc signing (CODE_SIGN_IDENTITY=-)
# every rebuild gets a fresh code hash, which makes macOS Keychain reject
# the existing OAuth-token entry's ACL — the app then shows "Token
# rejected" until you re-paste. A stable identity keeps the ACL valid
# across rebuilds.
#
# Idempotent: a second run is a no-op once the identity exists.
# Run once after cloning the repo, then `./scripts/build.sh` picks it up
# automatically.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY_NAME:-CCUsageStats Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Identity '$IDENTITY' already present in login keychain — nothing to do."
    echo "Run 'security delete-certificate -c \"$IDENTITY\"' to remove it."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating 2048-bit RSA private key"
openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null

# OpenSSL config with the codeSigning extended-key-usage extension —
# without it, codesign(1) rejects the cert as not usable for signing.
cat > "$TMP/cnf" <<EOF
[req]
distinguished_name=dn
prompt=no
[dn]
CN=$IDENTITY
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF

echo "==> Self-signing 10-year certificate"
openssl req -x509 -new -key "$TMP/key.pem" -days 3650 \
    -out "$TMP/cert.pem" -config "$TMP/cnf" -extensions v3 2>/dev/null

echo "==> Packaging as PKCS#12"
# Force legacy SHA1-3DES PBE — macOS `security import` can't verify the
# modern AES-256/SHA-256 MAC that openssl ≥3.0 uses by default.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -password pass:cc \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> Importing into login keychain"
# -A allows any app to use the key without per-app ACL prompts; -T whitelists
# /usr/bin/codesign explicitly so codesign can read the private key.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "cc" -A -T /usr/bin/codesign

echo "==> Marking certificate as trusted for code signing"
echo "    (macOS will prompt once for your login password to update trust settings)"
# Without this step `security find-identity` and codesign(1) report the
# cert as CSSMERR_TP_NOT_TRUSTED and refuse to use it. The trust setting
# is added to the user domain only — no admin / sudo required.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

cat <<EOF

✅ Created code-signing identity '$IDENTITY' in your login keychain.

Next time you run scripts/build.sh, macOS may show a one-time prompt
asking codesign for permission to use the new key — click "Always Allow".
After that, all future rebuilds reuse the same signature and your OAuth
token entry in Keychain stays accessible across builds.
EOF
