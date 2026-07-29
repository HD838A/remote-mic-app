#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
DISPLAY_NAME="Remote Mic"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
DMG="${1:-$OUTPUT_DIR/Remote-Mic-$VERSION.dmg}"
CHECKSUM="$DMG.sha256"
VERIFY_ROOT="$(mktemp -d /private/tmp/remote-mic-dmg-verify.XXXXXX)"
MOUNT_POINT="$VERIFY_ROOT/mount"
INSTALL_PACKAGE="$MOUNT_POINT/Install Remote Mic.pkg"
UNINSTALL_PACKAGE="$MOUNT_POINT/Uninstall Remote Mic.pkg"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
ATTACHED=0

mkdir -p "$MOUNT_POINT"

cleanup() {
  if [[ "$ATTACHED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  case "$VERIFY_ROOT" in
    /private/tmp/remote-mic-dmg-verify.*) rm -rf -- "$VERIFY_ROOT" ;;
    *) print -u2 "refusing to clean unexpected verification path: $VERIFY_ROOT" ;;
  esac
}
trap cleanup EXIT

case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_NOTARIZATION" in
  0|1) ;;
  *) print -u2 "REQUIRE_NOTARIZATION must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && -z "$EXPECTED_DEVELOPER_TEAM_ID" ]]; then
  print -u2 "EXPECTED_DEVELOPER_TEAM_ID is required for Developer ID verification"
  exit 1
fi
if [[ "$REQUIRE_NOTARIZATION" == "1" && "$REQUIRE_DEVELOPER_ID_SIGNING" != "1" ]]; then
  print -u2 "notarization verification requires Developer ID verification"
  exit 1
fi

test -f "$DMG"
test -f "$CHECKSUM"
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" ]]; then
  codesign --verify --strict "$DMG"
  DMG_SIGNATURE_DETAILS="$(codesign -dvvv "$DMG" 2>&1)"
  print -r -- "$DMG_SIGNATURE_DETAILS" | rg -q '^Authority=Developer ID Application:'
  print -r -- "$DMG_SIGNATURE_DETAILS" | rg -q "^TeamIdentifier=$EXPECTED_DEVELOPER_TEAM_ID$"
fi
if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  xcrun stapler validate "$DMG"
  /usr/sbin/spctl -a -vv -t open --context context:primary-signature "$DMG"
fi
(
  cd "${DMG:h}"
  shasum -a 256 -c "${CHECKSUM:t}"
)
hdiutil verify "$DMG"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG" -quiet
ATTACHED=1

APP="$MOUNT_POINT/$DISPLAY_NAME.app"
EXPECTED_ROOT_ENTRIES="$(printf '%s\n' \
  Applications \
  Install\ Remote\ Mic.pkg \
  Remote\ Mic.app \
  Uninstall\ Remote\ Mic.pkg | LC_ALL=C sort)"
ACTUAL_ROOT_ENTRIES="$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 \
  -exec basename {} \; | LC_ALL=C sort)"

test "$ACTUAL_ROOT_ENTRIES" = "$EXPECTED_ROOT_ENTRIES"
test -L "$MOUNT_POINT/Applications"
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications"
test -f "$INSTALL_PACKAGE"
test -f "$UNINSTALL_PACKAGE"
"$ROOT/scripts/verify-app.sh" "$APP"
"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install
"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall

test "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" = "$VERSION"
test "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" = "$BUILD"
SIGNATURE_DETAILS="$VERIFY_ROOT/signature-details"
codesign -dv --verbose=4 "$APP" > "$SIGNATURE_DETAILS" 2>&1
SIGNATURE="$(awk -F= '
  /^Authority=/ { print $2; exit }
  /^Signature=/ { print $2; exit }
' "$SIGNATURE_DETAILS")"
test -n "$SIGNATURE"

test "$(sips -g pixelWidth "$APP/Contents/Resources/RC003-remote-photo.png" | tail -n 1 | tr -cd '0-9')" = "508"
test "$(sips -g pixelHeight "$APP/Contents/Resources/RC003-remote-photo.png" | tail -n 1 | tr -cd '0-9')" = "1030"

if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' \
  "$APP/Contents"; then
  print -u2 "DMG payload contains a forbidden local path or example device address"
  exit 1
fi

print "DMG VERIFY PASS: $DMG"
print "VERSION: $VERSION ($BUILD)"
print "SIGNATURE: $SIGNATURE"
if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  print "NOTARIZATION: stapled and accepted by Gatekeeper"
fi
