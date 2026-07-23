#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
DISPLAY_NAME="无线麦"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
DMG="${1:-$OUTPUT_DIR/Remote-Mic-$VERSION.dmg}"
CHECKSUM="$DMG.sha256"
VERIFY_ROOT="$(mktemp -d /private/tmp/remote-mic-dmg-verify.XXXXXX)"
MOUNT_POINT="$VERIFY_ROOT/mount"
INSTALL_PACKAGE="$MOUNT_POINT/安装无线麦.pkg"
UNINSTALL_PACKAGE="$MOUNT_POINT/卸载无线麦.pkg"
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

test -f "$DMG"
test -f "$CHECKSUM"
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
  安装无线麦.pkg \
  卸载无线麦.pkg \
  无线麦.app | LC_ALL=C sort)"
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
codesign -dv --verbose=4 "$APP" 2>&1 | rg -q '^Signature=adhoc$'

test "$(sips -g pixelWidth "$APP/Contents/Resources/RC003-remote-photo.png" | tail -n 1 | tr -cd '0-9')" = "508"
test "$(sips -g pixelHeight "$APP/Contents/Resources/RC003-remote-photo.png" | tail -n 1 | tr -cd '0-9')" = "1030"

if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' \
  "$APP/Contents"; then
  print -u2 "DMG payload contains a forbidden local path or example device address"
  exit 1
fi

print "DMG VERIFY PASS: $DMG"
print "VERSION: $VERSION ($BUILD)"
print "SIGNATURE: ad-hoc / not notarized"
