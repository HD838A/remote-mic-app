#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
OUTPUT_DIR="$RELEASE_OUTPUT_DIR"
DISPLAY_NAME="SayAll"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
DMG="${1:-$OUTPUT_DIR/Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX.dmg}"
CHECKSUM="$DMG.sha256"
VERIFY_ROOT="$(mktemp -d /private/tmp/remote-mic-dmg-verify.XXXXXX)"
MOUNT_POINT="$VERIFY_ROOT/mount"
INSTALL_PACKAGE="$MOUNT_POINT/$RELEASE_INSTALL_PACKAGE_NAME"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
ATTACHED=0

mkdir -p "$MOUNT_POINT"

cleanup() {
  local console_user user_home trash_root trash_destination counter=0
  if [[ "$ATTACHED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  case "$VERIFY_ROOT" in
    /private/tmp/remote-mic-dmg-verify.*) ;;
    *) print -u2 "refusing to clean unexpected verification path: $VERIFY_ROOT"; return ;;
  esac
  [[ -d "$VERIFY_ROOT" ]] || return
  console_user="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
  if [[ -z "$console_user" || "$console_user" == "root" || "$console_user" == "loginwindow" ]]; then
    print -u2 "DMG verification workspace retained because no desktop Trash is available: $VERIFY_ROOT"
    return
  fi
  user_home="$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory \
    2>/dev/null | /usr/bin/sed -n 's/^NFSHomeDirectory: //p')"
  if [[ "$user_home" != /* || "$user_home" == "/" || "$user_home" == *'/../'* || \
        "$user_home" == *'/..' ]]; then
    print -u2 "DMG verification workspace retained because the desktop Trash path is invalid: $VERIFY_ROOT"
    return
  fi
  trash_root="$user_home/.Trash"
  [[ -d "$trash_root" ]] || {
    print -u2 "DMG verification workspace retained because Trash is unavailable: $VERIFY_ROOT"
    return
  }
  trash_destination="$trash_root/${VERIFY_ROOT:t}"
  while [[ -e "$trash_destination" || -L "$trash_destination" ]]; do
    counter=$((counter + 1))
    trash_destination="$trash_root/${VERIFY_ROOT:t}-$counter"
  done
  if /bin/mv -n -- "$VERIFY_ROOT" "$trash_destination"; then
    print "DMG verification workspace moved to Trash: $trash_destination"
  else
    print -u2 "DMG verification workspace retained after Trash move failed: $VERIFY_ROOT"
  fi
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

EXPECTED_ROOT_ENTRIES="$RELEASE_INSTALL_PACKAGE_NAME"
ACTUAL_ROOT_ENTRIES="$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 \
  -exec basename {} \; | LC_ALL=C sort)"

test "$ACTUAL_ROOT_ENTRIES" = "$EXPECTED_ROOT_ENTRIES"
test -f "$INSTALL_PACKAGE"
"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install

print "DMG VERIFY PASS: $DMG"
print "VERSION: $VERSION ($BUILD)"
print "RELEASE VARIANT: $RELEASE_VARIANT"
if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  print "NOTARIZATION: stapled and accepted by Gatekeeper"
fi
