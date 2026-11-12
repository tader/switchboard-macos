#!/bin/bash
set -euo pipefail
arch=${1:?architecture}
: "${CERTIFICATE:?Developer ID certificate required}"
: "${SIGNING_IDENTITY:?Developer ID identity required}"
: "${NOTARY_KEY:?Notarization API key required}"
work=$(mktemp -d)
keychain="$work/signing.keychain-db"
password=$(uuidgen)
trap 'security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
printf '%s' "$CERTIFICATE" | base64 --decode > "$work/certificate.p12"
printf '%s' "$NOTARY_KEY" > "$work/key.p8"
security create-keychain -p "$password" "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/certificate.p12" -k "$keychain" -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain"
app=".dist/$arch/Switchboard.app"
codesign --force --options runtime --timestamp --keychain "$keychain" --sign "$SIGNING_IDENTITY" "$app"
version=$(/usr/bin/plutil -extract version raw version.json)
zip=".dist/Switchboard-$version-$arch.zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --key "$work/key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
xcrun stapler staple "$app"
codesign --verify --strict "$app"
spctl --assess --type execute "$app"
ditto -c -k --keepParent "$app" "$zip"
rm .dist/*-unsigned.zip
