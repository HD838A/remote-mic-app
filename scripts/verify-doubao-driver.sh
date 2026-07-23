#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DRIVER="${1:-$ROOT/dist/MiRemoteV2ch.driver}"
PLIST="$DRIVER/Contents/Info.plist"
BINARY="$DRIVER/Contents/MacOS/MiRemoteV2ch"

test -d "$DRIVER"
test -f "$PLIST"
test -x "$BINARY"
test "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = "com.hd838a.MiRemoteV2ch"
test "$(plutil -extract CFBundleName raw -o - "$PLIST")" = "MiRemoteV2ch"
codesign --verify --deep --strict "$DRIVER"
ARCHS="$(lipo -archs "$BINARY")"
test "$ARCHS" = "arm64"
xcrun vtool -show-build "$BINARY" | rg -q 'minos 26\.0'
strings "$BINARY" | rg -qx 'MiRemoteV %ich'
strings "$BINARY" | rg -qx 'MiRemoteV%ich_UID'

print "DOUBAO DRIVER VERIFY PASS: $DRIVER"
