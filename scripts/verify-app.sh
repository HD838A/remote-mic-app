#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
if [[ "$#" -gt 1 ]]; then
  print -u2 "usage: $0 [APP]"
  exit 1
fi
APP="${1:-$ROOT/dist/无线麦.app}"
PLIST="$APP/Contents/Info.plist"
BINARY="$APP/Contents/MacOS/RemoteMic"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

test -d "$APP"
test -f "$PLIST"
test -x "$BINARY"
test -d "$SPARKLE_FRAMEWORK"
test -x "$SPARKLE_FRAMEWORK/Versions/B/Sparkle"
test -x "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
test -x "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
test -f "$APP/Contents/Resources/LICENSE.md"
test -f "$APP/Contents/Resources/README.md"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -f "$APP/Contents/Resources/COPYRIGHT.md"
test -f "$APP/Contents/Resources/LOGO-LICENSE.md"
test -f "$APP/Contents/Resources/RC003-remote-photo.png"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/StatusIconTemplate.png"
test -f "$APP/Contents/Resources/StatusIconTemplate@2x.png"
test -f "$APP/Contents/Resources/StatusIconActiveTemplate.png"
test -f "$APP/Contents/Resources/StatusIconActiveTemplate@2x.png"
test -f "$APP/Contents/Resources/豆包输入法兼容说明.md"

test "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = \
  "com.hd838a.RemoteMic"
test "$(plutil -extract LSUIElement raw -o - "$PLIST")" = "true"
test "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "26.0"
test "$(plutil -extract CFBundleIconFile raw -o - "$PLIST")" = "AppIcon"
test -n "$(plutil -extract NSBluetoothAlwaysUsageDescription raw -o - "$PLIST")"
test "$(plutil -extract SUFeedURL raw -o - "$PLIST")" = \
  "https://github.com/HD838A/remote-mic-app/releases/latest/download/appcast.xml"
test "$(plutil -extract SUEnableAutomaticChecks raw -o - "$PLIST")" = "false"
test -n "$(plutil -extract SUPublicEDKey raw -o - "$PLIST")"

codesign --verify --deep --strict "$APP"
file "$BINARY" | rg -q 'Mach-O 64-bit executable'
ARCHS="$(lipo -archs "$BINARY")"
test "$ARCHS" = "arm64"
xcrun vtool -show-build "$BINARY" | rg -q 'minos 26\.0'
otool -l "$BINARY" | rg -A2 'LC_RPATH' | rg -q '@executable_path/\.\./Frameworks'

EXPECTED_APP_FILES=$'Contents/Info.plist\nContents/MacOS/RemoteMic\nContents/Resources/AppIcon.icns\nContents/Resources/COPYRIGHT.md\nContents/Resources/LICENSE.md\nContents/Resources/LOGO-LICENSE.md\nContents/Resources/RC003-remote-photo.png\nContents/Resources/README.md\nContents/Resources/StatusIconActiveTemplate.png\nContents/Resources/StatusIconActiveTemplate@2x.png\nContents/Resources/StatusIconTemplate.png\nContents/Resources/StatusIconTemplate@2x.png\nContents/Resources/THIRD_PARTY_NOTICES.md\nContents/Resources/豆包输入法兼容说明.md\nContents/_CodeSignature/CodeResources'
while IFS= read -r expected_file; do
  test -f "$APP/$expected_file"
done <<< "$EXPECTED_APP_FILES"

if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' "$APP/Contents"; then
  print -u2 "bundle contains a forbidden local path or example device address"
  exit 1
fi

print "APP VERIFY PASS: $APP"
