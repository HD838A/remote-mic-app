#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
UNIVERSAL=0
APP=""
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    *) APP="$arg" ;;
  esac
done
APP="${APP:-$ROOT/dist/无线麦.app}"
PLIST="$APP/Contents/Info.plist"
BINARY="$APP/Contents/MacOS/RemoteMic"

test -d "$APP"
test -f "$PLIST"
test -x "$BINARY"
test -f "$APP/Contents/Resources/LICENSE"
test -f "$APP/Contents/Resources/README.md"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -f "$APP/Contents/Resources/COPYRIGHT"
test -f "$APP/Contents/Resources/RC003-remote-photo.png"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/StatusIconTemplate.png"
test -f "$APP/Contents/Resources/StatusIconTemplate@2x.png"
test -f "$APP/Contents/Resources/StatusIconActiveTemplate.png"
test -f "$APP/Contents/Resources/StatusIconActiveTemplate@2x.png"
test -f "$APP/Contents/Resources/豆包输入法兼容说明.txt"

test "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = \
  "com.hd838a.RemoteMic"
test "$(plutil -extract LSUIElement raw -o - "$PLIST")" = "true"
test "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "11.0"
test "$(plutil -extract CFBundleIconFile raw -o - "$PLIST")" = "AppIcon"
test -n "$(plutil -extract NSBluetoothAlwaysUsageDescription raw -o - "$PLIST")"

codesign --verify --deep --strict "$APP"
file "$BINARY" | rg -q 'Mach-O 64-bit executable'

if [[ "$UNIVERSAL" -eq 1 ]]; then
  ARCHS="$(lipo -archs "$BINARY")"
  print "universal archs: $ARCHS"
  for required in arm64 x86_64; do
    if ! print -r -- "$ARCHS" | tr ' ' '\n' | rg -qx "$required"; then
      print -u2 "missing architecture in universal binary: $required"
      exit 1
    fi
  done
fi

EXPECTED_FILES=$'Contents/Info.plist\nContents/MacOS/RemoteMic\nContents/Resources/AppIcon.icns\nContents/Resources/COPYRIGHT\nContents/Resources/LICENSE\nContents/Resources/RC003-remote-photo.png\nContents/Resources/README.md\nContents/Resources/StatusIconActiveTemplate.png\nContents/Resources/StatusIconActiveTemplate@2x.png\nContents/Resources/StatusIconTemplate.png\nContents/Resources/StatusIconTemplate@2x.png\nContents/Resources/THIRD_PARTY_NOTICES.md\nContents/Resources/豆包输入法兼容说明.txt\nContents/_CodeSignature/CodeResources'
ACTUAL_FILES="$(find "$APP/Contents" -type f | sed "s#^$APP/##" | LC_ALL=C sort)"
test "$ACTUAL_FILES" = "$EXPECTED_FILES"

if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' "$APP/Contents"; then
  print -u2 "bundle contains a forbidden local path or example device address"
  exit 1
fi

print "APP VERIFY PASS: $APP"
