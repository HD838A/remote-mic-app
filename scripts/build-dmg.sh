#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
DISPLAY_NAME="Remote Mic"
APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
DMG_BASENAME="Remote-Mic-$VERSION.dmg"
DMG="$OUTPUT_DIR/$DMG_BASENAME"
INSTALL_PACKAGE="Install Remote Mic.pkg"
UNINSTALL_PACKAGE="Uninstall Remote Mic.pkg"

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.package-work.XXXXXX")"
STAGING="$WORK_DIR/dmg"

cleanup() {
  case "$WORK_DIR" in
    "$OUTPUT_DIR/.package-work."*) rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

mkdir -p "$STAGING"

"$ROOT/scripts/build-app.sh"
"$ROOT/scripts/verify-app.sh" "$APP_DIR"
"$ROOT/scripts/build-doubao-driver.sh"
"$ROOT/scripts/build-doubao-driver-pkg.sh"

ditto --norsrc --noextattr --noqtn --noacl \
  "$APP_DIR" "$STAGING/$DISPLAY_NAME.app"
ln -s /Applications "$STAGING/Applications"
ditto --norsrc --noextattr --noqtn --noacl \
  "$OUTPUT_DIR/$INSTALL_PACKAGE" "$STAGING/$INSTALL_PACKAGE"
ditto --norsrc --noextattr --noqtn --noacl \
  "$OUTPUT_DIR/$UNINSTALL_PACKAGE" "$STAGING/$UNINSTALL_PACKAGE"

hdiutil create \
  -volname "$DISPLAY_NAME $VERSION" \
  -srcfolder "$STAGING" \
  -fs "HFS+" \
  -format UDZO \
  -ov \
  "$DMG"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_BASENAME" > "$DMG_BASENAME.sha256"
)

print "DMG: $DMG"
print "SHA256: $DMG.sha256"
print "VERSION: $VERSION ($BUILD)"
