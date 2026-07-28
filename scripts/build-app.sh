#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="RemoteMic"
DISPLAY_NAME="Remote Mic"
OUTPUT_DIR="$ROOT/dist"
APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app"
SPARKLE_FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

cd "$ROOT"

case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && "$SIGNING_IDENTITY" == "-" ]]; then
  print -u2 "Developer ID Application signing is required"
  exit 1
fi

xcrun swift build -c "$CONFIGURATION" --triple arm64-apple-macosx26.0
BIN_PATH="$(xcrun swift build -c "$CONFIGURATION" --triple arm64-apple-macosx26.0 --show-bin-path)/$APP_NAME"

case "$APP_DIR" in
  "$ROOT/dist/"*.app) ;;
  *) print -u2 "refusing to clean unexpected app path: $APP_DIR"; exit 1 ;;
esac
rm -rf -- "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
test -d "$SPARKLE_FRAMEWORK"
ditto --norsrc --noextattr --noqtn --noacl \
  "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
strip -S -x "$APP_DIR/Contents/MacOS/$APP_NAME"
install_name_tool -add_rpath @executable_path/../Frameworks \
  "$APP_DIR/Contents/MacOS/$APP_NAME"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Frameworks"
ditto --norsrc --noextattr --noqtn --noacl \
  "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/LICENSE.md" "$APP_DIR/Contents/Resources/LICENSE.md"
for document in README TECHNICAL TROUBLESHOOTING COPYRIGHT LOGO-LICENSE; do
  ditto --norsrc --noextattr --noqtn --noacl \
    "$ROOT/$document.en.md" "$APP_DIR/Contents/Resources/$document.md"
done
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/首次安装说明.en.md" \
  "$APP_DIR/Contents/Resources/FirstInstallGuide.md"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/RC003-remote-photo.png" \
  "$APP_DIR/Contents/Resources/RC003-remote-photo.png"
for icon_resource in \
  AppIcon.icns \
  StatusIconTemplate.png \
  StatusIconTemplate@2x.png \
  StatusIconActiveTemplate.png \
  StatusIconActiveTemplate@2x.png; do
  ditto --norsrc --noextattr --noqtn --noacl \
    "$ROOT/Resources/$icon_resource" \
    "$APP_DIR/Contents/Resources/$icon_resource"
done
for localization in en zh-Hans; do
  ditto --norsrc --noextattr --noqtn --noacl \
    "$ROOT/Resources/$localization.lproj" \
    "$APP_DIR/Contents/Resources/$localization.lproj"
done
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$APP_DIR/Contents/Info.plist")"
  codesign \
    --force \
    --deep \
    --timestamp=none \
    --sign - \
    "$APP_DIR"
  codesign \
    --force \
    --timestamp=none \
    --sign - \
    --requirements "=designated => identifier \"$BUNDLE_IDENTIFIER\"" \
    "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

print "$APP_DIR"
print "SIGNING IDENTITY: $SIGNING_IDENTITY"
