#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
if [[ "$#" -gt 1 ]]; then
  print -u2 "usage: $0 [APP]"
  exit 1
fi
APP="${1:-$ROOT/dist/Remote Mic.app}"
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
test -f "$APP/Contents/Resources/TECHNICAL.md"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -f "$APP/Contents/Resources/TROUBLESHOOTING.md"
test -f "$APP/Contents/Resources/COPYRIGHT.md"
test -f "$APP/Contents/Resources/LOGO-LICENSE.md"
test -f "$APP/Contents/Resources/FirstInstallGuide.md"
test -f "$APP/Contents/Resources/RC003-remote-photo.png"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/StatusIconTemplate.png"
test -f "$APP/Contents/Resources/StatusIconTemplate@2x.png"
test -f "$APP/Contents/Resources/StatusIconActiveTemplate.png"
test -f "$APP/Contents/Resources/StatusIconActiveTemplate@2x.png"
for localization in en zh-Hans; do
  RESOURCE_DIR="$APP/Contents/Resources/$localization.lproj"
  test -f "$RESOURCE_DIR/InfoPlist.strings"
  test -f "$RESOURCE_DIR/Localizable.strings"
  test -f "$RESOURCE_DIR/DoubaoInputMethodCompatibility.md"
  test -f "$RESOURCE_DIR/FirstInstallGuide.md"
  plutil -lint "$RESOURCE_DIR/InfoPlist.strings"
  plutil -lint "$RESOURCE_DIR/Localizable.strings"
done
rg -q '^"无线麦" = "Remote Mic";$' "$APP/Contents/Resources/en.lproj/Localizable.strings"
rg -q '^"无线麦" = "无线麦";$' "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"
ZH_KEYS="$(plutil -convert xml1 -o - "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings" | sed -n 's/^[[:space:]]*<key>\(.*\)<\/key>$/\1/p' | LC_ALL=C sort)"
EN_KEYS="$(plutil -convert xml1 -o - "$APP/Contents/Resources/en.lproj/Localizable.strings" | sed -n 's/^[[:space:]]*<key>\(.*\)<\/key>$/\1/p' | LC_ALL=C sort)"
test "$ZH_KEYS" = "$EN_KEYS"

test "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = \
  "com.hd838a.RemoteMic"
test "$(plutil -extract LSUIElement raw -o - "$PLIST")" = "true"
test "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "26.0"
test "$(plutil -extract CFBundleDevelopmentRegion raw -o - "$PLIST")" = "en"
test "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "Remote Mic"
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

EXPECTED_APP_FILES=$'Contents/Info.plist\nContents/MacOS/RemoteMic\nContents/Resources/AppIcon.icns\nContents/Resources/COPYRIGHT.md\nContents/Resources/FirstInstallGuide.md\nContents/Resources/LICENSE.md\nContents/Resources/LOGO-LICENSE.md\nContents/Resources/RC003-remote-photo.png\nContents/Resources/README.md\nContents/Resources/StatusIconActiveTemplate.png\nContents/Resources/StatusIconActiveTemplate@2x.png\nContents/Resources/StatusIconTemplate.png\nContents/Resources/StatusIconTemplate@2x.png\nContents/Resources/TECHNICAL.md\nContents/Resources/THIRD_PARTY_NOTICES.md\nContents/Resources/TROUBLESHOOTING.md\nContents/Resources/en.lproj/DoubaoInputMethodCompatibility.md\nContents/Resources/en.lproj/FirstInstallGuide.md\nContents/Resources/en.lproj/InfoPlist.strings\nContents/Resources/en.lproj/Localizable.strings\nContents/Resources/zh-Hans.lproj/DoubaoInputMethodCompatibility.md\nContents/Resources/zh-Hans.lproj/FirstInstallGuide.md\nContents/Resources/zh-Hans.lproj/InfoPlist.strings\nContents/Resources/zh-Hans.lproj/Localizable.strings\nContents/_CodeSignature/CodeResources'
while IFS= read -r expected_file; do
  test -f "$APP/$expected_file"
done <<< "$EXPECTED_APP_FILES"

if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' "$APP/Contents"; then
  print -u2 "bundle contains a forbidden local path or example device address"
  exit 1
fi

print "APP VERIFY PASS: $APP"
