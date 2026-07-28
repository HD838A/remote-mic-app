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
BUILD_COMPONENTS="${BUILD_COMPONENTS:-1}"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"

case "$BUILD_COMPONENTS" in
  0|1) ;;
  *) print -u2 "BUILD_COMPONENTS must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && "$SIGNING_IDENTITY" == "-" ]]; then
  print -u2 "Developer ID Application signing is required"
  exit 1
fi

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

if [[ "$BUILD_COMPONENTS" == "1" ]]; then
  "$ROOT/scripts/build-app.sh"
  "$ROOT/scripts/build-doubao-driver.sh"
  "$ROOT/scripts/build-doubao-driver-pkg.sh"
else
  "$ROOT/scripts/verify-app.sh" "$APP_DIR"
  "$ROOT/scripts/verify-doubao-driver.sh" "$OUTPUT_DIR/MiRemoteV2ch.driver"
  "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$OUTPUT_DIR/$INSTALL_PACKAGE" install
  "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$OUTPUT_DIR/$UNINSTALL_PACKAGE" uninstall
fi

ditto --norsrc --noqtn --noacl \
  "$APP_DIR" "$STAGING/$DISPLAY_NAME.app"
ln -s /Applications "$STAGING/Applications"
ditto --norsrc --noqtn --noacl \
  "$OUTPUT_DIR/$INSTALL_PACKAGE" "$STAGING/$INSTALL_PACKAGE"
ditto --norsrc --noqtn --noacl \
  "$OUTPUT_DIR/$UNINSTALL_PACKAGE" "$STAGING/$UNINSTALL_PACKAGE"

hdiutil create \
  -volname "$DISPLAY_NAME $VERSION" \
  -srcfolder "$STAGING" \
  -fs "HFS+" \
  -format UDZO \
  -ov \
  "$DMG"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
fi

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_BASENAME" > "$DMG_BASENAME.sha256"
)

print "DMG: $DMG"
print "SHA256: $DMG.sha256"
print "VERSION: $VERSION ($BUILD)"
