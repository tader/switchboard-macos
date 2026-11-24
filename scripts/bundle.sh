#!/bin/sh
set -eu
arch=${1:-arm64}
case "$arch" in arm64|x86_64) ;; *) exit 1;; esac
swift build -c release --arch "$arch"
bin=$(swift build -c release --arch "$arch" --show-bin-path)
version=$(/usr/bin/plutil -extract version raw version.json)
output=".dist/$arch/Switchboard.app"
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources" "$output/Contents/Frameworks"
framework=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
/usr/bin/ditto "$framework" "$output/Contents/Frameworks/Sparkle.framework"
public_key=""
if [ -f Assets/update-public-key.txt ]; then public_key=$(cat Assets/update-public-key.txt); fi
cp "$bin/SwitchboardMenu" "$output/Contents/MacOS/SwitchboardMenu"
cat > "$output/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>nl.tader.Switchboard</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleName</key><string>Switchboard</string>
<key>CFBundleDisplayName</key><string>Switchboard</string>
<key>CFBundleExecutable</key><string>SwitchboardMenu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>SUFeedURL</key><string>https://github.com/tader/switchboard-macos/releases/latest/download/appcast-$arch.xml</string>
<key>SUPublicEDKey</key><string>$public_key</string>
<key>SUAppUpdatesEnabled</key><false/>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUEnableSystemProfiling</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
<key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp Assets/AppIcon.icns "$output/Contents/Resources/AppIcon.icns"
cp README.md "$output/Contents/Resources/README.md"
# No signing identity is assumed. This is explicitly a development build.
/usr/bin/ditto -c -k --keepParent "$output" ".dist/Switchboard-$version-$arch-unsigned.zip"
echo "$output"
