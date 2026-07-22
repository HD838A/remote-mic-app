#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
DISPLAY_NAME="小米遥控器桥接"
APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
DMG_BASENAME="$DISPLAY_NAME-$VERSION-测试版.dmg"
DMG="$OUTPUT_DIR/$DMG_BASENAME"
SOURCE_ROOT="xiaomi-remote-bridge-mac-$VERSION-source"
SOURCE_ARCHIVE="$DISPLAY_NAME-$VERSION-对应源码.zip"

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.package-work.XXXXXX")"
STAGING="$WORK_DIR/dmg"
SOURCE_DIR="$WORK_DIR/$SOURCE_ROOT"

cleanup() {
  case "$WORK_DIR" in
    "$OUTPUT_DIR/.package-work."*) rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

mkdir -p "$STAGING" "$SOURCE_DIR"

"$ROOT/scripts/build-app.sh" --universal
"$ROOT/scripts/verify-app.sh" --universal "$APP_DIR"

ditto --norsrc --noextattr --noqtn --noacl \
  "$APP_DIR" "$STAGING/$DISPLAY_NAME.app"
ln -s /Applications "$STAGING/Applications"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/首次安装说明.txt" "$STAGING/首次安装说明.txt"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/LICENSE" "$STAGING/LICENSE"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/COPYRIGHT" "$STAGING/COPYRIGHT"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGING/THIRD_PARTY_NOTICES.md"

for item in Package.swift Sources Tests script scripts Resources third_party .codex .gitattributes README.md LICENSE COPYRIGHT THIRD_PARTY_NOTICES.md; do
  ditto --norsrc --noextattr --noqtn --noacl \
    "$ROOT/$item" "$SOURCE_DIR/$item"
done

ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "$SOURCE_DIR" "$STAGING/$SOURCE_ARCHIVE"

hdiutil create \
  -volname "$DISPLAY_NAME $VERSION 测试版" \
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
