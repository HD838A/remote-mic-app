#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DRIVER="${1:-$ROOT/dist/MiRemoteV2ch.driver}"
PLIST="$DRIVER/Contents/Info.plist"
BINARY="$DRIVER/Contents/MacOS/MiRemoteV2ch"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"

case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && -z "$EXPECTED_DEVELOPER_TEAM_ID" ]]; then
  print -u2 "EXPECTED_DEVELOPER_TEAM_ID is required for Developer ID verification"
  exit 1
fi

test -d "$DRIVER"
test -f "$PLIST"
test -x "$BINARY"
test "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = "com.hd838a.MiRemoteV2ch"
test "$(plutil -extract CFBundleName raw -o - "$PLIST")" = "MiRemoteV2ch"
codesign --verify --deep --strict "$DRIVER"
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" ]]; then
  SIGNATURE_DETAILS="$(codesign -dvvv "$DRIVER" 2>&1)"
  print -r -- "$SIGNATURE_DETAILS" | rg -q '^Authority=Developer ID Application:'
  print -r -- "$SIGNATURE_DETAILS" | rg -q "^TeamIdentifier=$EXPECTED_DEVELOPER_TEAM_ID$"
  print -r -- "$SIGNATURE_DETAILS" | rg -q '^CodeDirectory .*flags=.*runtime'
fi
ARCHS="$(lipo -archs "$BINARY")"
test "$ARCHS" = "arm64"
xcrun vtool -show-build "$BINARY" | rg -q 'minos 26\.0'
strings "$BINARY" | rg -qx 'MiRemoteV %ich'
strings "$BINARY" | rg -qx 'MiRemoteV%ich_UID'

print "DOUBAO DRIVER VERIFY PASS: $DRIVER"
