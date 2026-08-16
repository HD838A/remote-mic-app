#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
OUTPUT_DIR="$RELEASE_OUTPUT_DIR"
DISPLAY_NAME="Remote Mic"
APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
DMG_BASENAME="Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX.dmg"
DMG="$OUTPUT_DIR/$DMG_BASENAME"
INSTALL_PACKAGE="$RELEASE_INSTALL_PACKAGE_NAME"
UNINSTALL_PACKAGE="$RELEASE_UNINSTALL_PACKAGE_NAME"
BUILD_COMPONENTS="${BUILD_COMPONENTS:-1}"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"
RELEASE_STAGE_TIMEOUTS="${RELEASE_STAGE_TIMEOUTS:-0}"
RELEASE_DMG_BUILD_TIMEOUT_SECONDS="${RELEASE_DMG_BUILD_TIMEOUT_SECONDS:-90}"
RELEASE_CODESIGN_TIMEOUT_SECONDS="${RELEASE_CODESIGN_TIMEOUT_SECONDS:-45}"
RELEASE_STAGE_RUNNER="$ROOT/scripts/run-release-stage.sh"

case "$BUILD_COMPONENTS" in
  0|1) ;;
  *) print -u2 "BUILD_COMPONENTS must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
case "$RELEASE_STAGE_TIMEOUTS" in
  0|1) ;;
  *) print -u2 "RELEASE_STAGE_TIMEOUTS must be 0 or 1"; exit 1 ;;
esac
if [[ "$RELEASE_STAGE_TIMEOUTS" == "1" && ! -x "$RELEASE_STAGE_RUNNER" ]]; then
  print -u2 "release stage runner is unavailable"
  exit 1
fi

run_release_stage() {
  local stage="$1"
  local timeout_seconds="$2"
  shift 2
  if [[ "$RELEASE_STAGE_TIMEOUTS" == "1" ]]; then
    "$RELEASE_STAGE_RUNNER" "$RELEASE_VARIANT" "$stage" "$timeout_seconds" -- "$@"
  else
    "$@"
  fi
}
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
  "$OUTPUT_DIR/$INSTALL_PACKAGE" "$STAGING/$INSTALL_PACKAGE"

run_release_stage dmg-hdiutil-create "$RELEASE_DMG_BUILD_TIMEOUT_SECONDS" hdiutil create \
  -volname "$DISPLAY_NAME $VERSION $RELEASE_LABEL" \
  -srcfolder "$STAGING" \
  -fs "HFS+" \
  -format UDZO \
  -ov \
  "$DMG"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  run_release_stage dmg-codesign "$RELEASE_CODESIGN_TIMEOUT_SECONDS" \
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
fi

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_BASENAME" > "$DMG_BASENAME.sha256"
)

print "DMG: $DMG"
print "SHA256: $DMG.sha256"
print "VERSION: $VERSION ($BUILD)"
print "RELEASE VARIANT: $RELEASE_VARIANT"
