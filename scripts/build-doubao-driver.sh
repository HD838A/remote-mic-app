#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BLACKHOLE_TAG="v0.7.1"
BLACKHOLE_COMMIT="e2b22aaaba4e507a097131704bf96dabc004d9cf"
WORK_ROOT="$ROOT/.build/doubao-driver"
SOURCE_ROOT="$WORK_ROOT/BlackHole"
PATCH="$ROOT/third_party/blackhole/blackhole-device-usb.patch"
OUTPUT="$ROOT/dist/MiRemoteV2ch.driver"
PRODUCT_NAME="MiRemoteV2ch"
BUNDLE_ID="com.hd838a.MiRemoteV2ch"
DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS kDriver_Name=\"MiRemoteV\" kPlugIn_BundleID=\"com.hd838a.MiRemoteV2ch\" kNumber_Of_Channels=2'
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"

if ! command -v git >/dev/null 2>&1; then
  print -u2 "Missing required command: git"
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  print -u2 "Missing required command: xcodebuild. Install Xcode before building the Doubao compatibility driver."
  exit 1
fi
case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && "$SIGNING_IDENTITY" == "-" ]]; then
  print -u2 "Developer ID Application signing is required"
  exit 1
fi

case "$WORK_ROOT" in
  "$ROOT"/.build/doubao-driver) ;;
  *) print -u2 "refusing to clean unexpected work path: $WORK_ROOT"; exit 1 ;;
esac
case "$OUTPUT" in
  "$ROOT"/dist/*.driver) ;;
  *) print -u2 "refusing to replace unexpected output path: $OUTPUT"; exit 1 ;;
esac

rm -rf -- "$WORK_ROOT" "$OUTPUT"
mkdir -p "${WORK_ROOT:h}" "${OUTPUT:h}"
git clone --depth 1 --branch "$BLACKHOLE_TAG" \
  https://github.com/ExistentialAudio/BlackHole.git "$SOURCE_ROOT"

if [[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" != "$BLACKHOLE_COMMIT" ]]; then
  print -u2 "Unexpected BlackHole revision; expected $BLACKHOLE_COMMIT"
  exit 1
fi
git -C "$SOURCE_ROOT" apply --check "$PATCH"
git -C "$SOURCE_ROOT" apply "$PATCH"
rg -U -q 'case kAudioDevicePropertyTransportType:(?s:.*?)kAudioDeviceTransportTypeUSB' \
  "$SOURCE_ROOT/BlackHole/BlackHole.c"

xcodebuild \
  -project "$SOURCE_ROOT/BlackHole.xcodeproj" \
  -target BlackHole \
  -configuration Release \
  -sdk macosx \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=14.0 \
  CODE_SIGNING_ALLOWED=NO \
  PRODUCT_NAME="$PRODUCT_NAME" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  GCC_PREPROCESSOR_DEFINITIONS="$DEFINITIONS" \
  build

ditto --norsrc --noextattr --noqtn --noacl \
  "$SOURCE_ROOT/build/Release/$PRODUCT_NAME.driver" "$OUTPUT"
/usr/bin/strip -S "$OUTPUT/Contents/MacOS/$PRODUCT_NAME"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - --timestamp=none "$OUTPUT"
else
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$OUTPUT"
fi
"$ROOT/scripts/verify-doubao-driver.sh" "$OUTPUT"

print "Built: $OUTPUT"
print "SIGNING IDENTITY: $SIGNING_IDENTITY"
print "Next: $ROOT/scripts/build-doubao-driver-pkg.sh"
