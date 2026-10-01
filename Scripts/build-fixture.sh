#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
fixture="$task_root/build/QbarFixture.app"
mkdir -p "$fixture/Contents/MacOS"
fixture_arch=$(uname -m)
swiftc -parse-as-library -target "$fixture_arch-apple-macos14.4" "$task_root/Scripts/Fixture.swift" \
  -o "$fixture/Contents/MacOS/QbarFixture.next" -framework AppKit
mv "$fixture/Contents/MacOS/QbarFixture.next" "$fixture/Contents/MacOS/QbarFixture"
cat > "$fixture/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>QbarFixture</string>
<key>CFBundleIdentifier</key><string>studio.qbar.fixture</string>
<key>CFBundleName</key><string>QbarFixture</string>
<key>CFBundleDisplayName</key><string>Qbar 功能测试</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSUIElement</key><false/>
</dict></plist>
PLIST
fixture_signing_identity="${QBAR_FIXTURE_SIGNING_IDENTITY:-${QBAR_SIGNING_IDENTITY:--}}"
codesign --force --sign "$fixture_signing_identity" "$fixture"
codesign --verify --deep --strict "$fixture"
plutil -lint "$fixture/Contents/Info.plist"
