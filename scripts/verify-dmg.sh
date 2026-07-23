#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
DISPLAY_NAME="小米遥控器桥接"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
DMG="${1:-$OUTPUT_DIR/XiaomiRemoteBridgeMac-$VERSION-doubao-preview.dmg}"
CHECKSUM="$DMG.sha256"
SOURCE_ROOT="xiaomi-remote-bridge-mac-$VERSION-source"
SOURCE_ARCHIVE="$DISPLAY_NAME-$VERSION-对应源码.zip"
VERIFY_ROOT="$(mktemp -d /private/tmp/xrbm-dmg-verify.XXXXXX)"
MOUNT_POINT="$VERIFY_ROOT/mount"
SOURCE_EXTRACT="$VERIFY_ROOT/source"
ZIP_LIST="$VERIFY_ROOT/zip-entries.txt"
INSTALL_PACKAGE="$MOUNT_POINT/安装小米遥控器桥接.pkg"
UNINSTALL_PACKAGE="$MOUNT_POINT/卸载豆包兼容麦克风.pkg"
ATTACHED=0

mkdir -p "$MOUNT_POINT" "$SOURCE_EXTRACT"

cleanup() {
  if [[ "$ATTACHED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  case "$VERIFY_ROOT" in
    /private/tmp/xrbm-dmg-verify.*) rm -rf -- "$VERIFY_ROOT" ;;
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
GUIDE="$MOUNT_POINT/首次安装说明.txt"
DOUBAO_GUIDE="$MOUNT_POINT/豆包输入法兼容说明.txt"
SOURCE_ZIP="$MOUNT_POINT/$SOURCE_ARCHIVE"

test -L "$MOUNT_POINT/Applications"
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications"
test -f "$GUIDE"
test -f "$DOUBAO_GUIDE"
test -f "$SOURCE_ZIP"
test -f "$INSTALL_PACKAGE"
test -f "$UNINSTALL_PACKAGE"
"$ROOT/scripts/verify-app.sh" --universal "$APP"
"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install
"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall

test "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" = "$VERSION"
test "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" = "$BUILD"
codesign -dv --verbose=4 "$APP" 2>&1 | rg -q '^Signature=adhoc$'

test "$(sips -g pixelWidth "$APP/Contents/Resources/RC003-remote-photo.png" | tail -n 1 | tr -cd '0-9')" = "508"
test "$(sips -g pixelHeight "$APP/Contents/Resources/RC003-remote-photo.png" | tail -n 1 | tr -cd '0-9')" = "1030"

unzip -Z1 "$SOURCE_ZIP" > "$ZIP_LIST"
for required in \
  "$SOURCE_ROOT/Package.swift" \
  "$SOURCE_ROOT/Sources/XiaomiRemoteBridgeMac/SettingsView.swift" \
  "$SOURCE_ROOT/Tests/SelfTest/main.swift" \
  "$SOURCE_ROOT/script/build_and_run.sh" \
  "$SOURCE_ROOT/.gitattributes" \
  "$SOURCE_ROOT/scripts/build-dmg.sh" \
  "$SOURCE_ROOT/scripts/build-doubao-driver.sh" \
  "$SOURCE_ROOT/scripts/build-doubao-driver-pkg.sh" \
  "$SOURCE_ROOT/scripts/verify-doubao-driver-pkg.sh" \
  "$SOURCE_ROOT/packaging/doubao-driver/install/preinstall" \
  "$SOURCE_ROOT/packaging/doubao-driver/install/postinstall" \
  "$SOURCE_ROOT/packaging/doubao-driver/uninstall/postinstall" \
  "$SOURCE_ROOT/third_party/blackhole/blackhole-device-usb.patch" \
  "$SOURCE_ROOT/Resources/RC003-remote-photo.png" \
  "$SOURCE_ROOT/LICENSE"; do
  rg -qx "$required" "$ZIP_LIST"
done

if rg -q '(^|/)(\.build|dist|logs?|\.DS_Store)(/|$)|(^|/)__MACOSX(/|$)' "$ZIP_LIST"; then
  print -u2 "source archive contains a forbidden build, log, or metadata path"
  exit 1
fi

unzip -qq "$SOURCE_ZIP" -d "$SOURCE_EXTRACT"
if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/Sources" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/Tests" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/Resources" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/Package.swift" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/README.md" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/LICENSE" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/COPYRIGHT" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/THIRD_PARTY_NOTICES.md"; then
  print -u2 "source archive contains a forbidden local path or example device address"
  exit 1
fi

if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' \
  "$APP/Contents" "$GUIDE" "$DOUBAO_GUIDE" "$MOUNT_POINT/THIRD_PARTY_NOTICES.md"; then
  print -u2 "DMG payload contains a forbidden local path or example device address"
  exit 1
fi

print "DMG VERIFY PASS: $DMG"
print "VERSION: $VERSION ($BUILD)"
print "SIGNATURE: ad-hoc / not notarized"
