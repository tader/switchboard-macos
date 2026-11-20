#!/bin/bash
set -euo pipefail
umask 077
arch=${1:?architecture}
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture" >&2; exit 1;; esac
: "${CERTIFICATE:?Developer ID certificate required}"
: "${CERTIFICATE_PASSWORD:?Certificate export password required}"
: "${NOTARY_KEY_ID:?App Store Connect API key ID required}"
: "${NOTARY_ISSUER:?App Store Connect team API issuer ID required}"
: "${SIGNING_IDENTITY:?Developer ID identity required}"
: "${NOTARY_KEY:?Notarization API key required}"
work=$(mktemp -d)
keychain="$work/signing.keychain-db"
password=$(uuidgen)
security list-keychains -d user > "$work/search-list"
cleanup() {
  # Restore the original search list before removing our temporary keychain.
  python3 - "$work/search-list" <<'RESTORE' || true
import shlex, subprocess, sys
subprocess.run(["security", "list-keychains", "-d", "user", "-s", *shlex.split(open(sys.argv[1]).read())], check=True)
RESTORE
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
printf '%s' "$CERTIFICATE" | base64 --decode > "$work/certificate.p12"
printf '%s' "$NOTARY_KEY" > "$work/key.p8"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/certificate.p12" -k "$keychain" -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain"
python3 - "$work/search-list" "$keychain" <<'SEARCH'
import shlex, subprocess, sys
subprocess.run(["security", "list-keychains", "-d", "user", "-s", sys.argv[2], *shlex.split(open(sys.argv[1]).read())], check=True)
SEARCH
app=".dist/$arch/Switchboard.app"
codesign --force --options runtime --timestamp --keychain "$keychain" --sign "$SIGNING_IDENTITY" "$app"
version=$(/usr/bin/plutil -extract version raw version.json)
zip=".dist/Switchboard-$version-$arch.zip"
ditto -c -k --keepParent "$app" "$zip"
# A completed submission can still be Invalid. Require explicit acceptance.
xcrun notarytool submit "$zip" --key "$work/key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait --timeout 60m --output-format json > "$work/notary-result.json"
python3 - "$work/notary-result.json" <<'RESULT'
import json, sys
result = json.load(open(sys.argv[1]))
print("Notarization submission:", result.get("id", "unknown"), "status:", result.get("status", "unknown"))
if result.get("status") != "Accepted":
    sys.exit("Apple did not accept this build. Retrieve the submission log with xcrun notarytool log <id> using the same API credentials.")
RESULT
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --strict "$app"
spctl --assess --type execute "$app"
ditto -c -k --keepParent "$app" "$zip"
rm .dist/*-unsigned.zip
