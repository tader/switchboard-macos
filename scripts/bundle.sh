#!/bin/sh
set -eu
arch=${1:-arm64}
case "$arch" in arm64|x86_64) ;; *) exit 1;; esac
swift build -c release --arch "$arch"
bin=$(swift build -c release --arch "$arch" --show-bin-path)
version=$(/usr/bin/plutil -extract version raw version.json)
output=".dist/$arch/Switchboard.app"
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
cp "$bin/SwitchboardMenu" "$output/Contents/MacOS/SwitchboardMenu"
cat > "$output/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.switchboard.macos</string>
<key>CFBundleName</key><string>Switchboard</string>
<key>CFBundleDisplayName</key><string>Switchboard</string>
<key>CFBundleExecutable</key><string>SwitchboardMenu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp README.md "$output/Contents/Resources/README.md"
# No signing identity is assumed. This is explicitly a development build.
/usr/bin/ditto -c -k --keepParent "$output" ".dist/Switchboard-$version-$arch-unsigned.zip"
echo "$output"
