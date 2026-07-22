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
for required in arm64 x86_64; do
  print -r -- "$ARCHS" | tr ' ' '\n' | rg -qx "$required"
done
strings "$BINARY" | rg -qx 'MiRemoteV %ich'
strings "$BINARY" | rg -qx 'MiRemoteV%ich_UID'

print "DOUBAO DRIVER VERIFY PASS: $DRIVER"
