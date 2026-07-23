#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="RemoteMic"
DISPLAY_NAME="无线麦"
OUTPUT_DIR="$ROOT/dist"
APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app"

UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    *) print -u2 "unknown argument: $arg"; exit 1 ;;
  esac
done

cd "$ROOT"

if [[ "$UNIVERSAL" -eq 1 ]]; then
  xcrun swift build -c "$CONFIGURATION" --triple arm64-apple-macosx11.0
  ARM64_BIN_DIR="$(xcrun swift build -c "$CONFIGURATION" --triple arm64-apple-macosx11.0 --show-bin-path)"
  xcrun swift build -c "$CONFIGURATION" --triple x86_64-apple-macosx11.0
  X86_64_BIN_DIR="$(xcrun swift build -c "$CONFIGURATION" --triple x86_64-apple-macosx11.0 --show-bin-path)"

  UNIVERSAL_BIN="$ROOT/.build/universal-$CONFIGURATION/$APP_NAME"
  mkdir -p "${UNIVERSAL_BIN:h}"
  lipo -create -output "$UNIVERSAL_BIN" \
    "$ARM64_BIN_DIR/$APP_NAME" \
    "$X86_64_BIN_DIR/$APP_NAME"
  BIN_PATH="$UNIVERSAL_BIN"
else
  xcrun swift build -c "$CONFIGURATION"
  BIN_PATH="$(xcrun swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
fi

case "$APP_DIR" in
  "$ROOT/dist/"*.app) ;;
  *) print -u2 "refusing to clean unexpected app path: $APP_DIR"; exit 1 ;;
esac
rm -rf -- "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
ditto --norsrc --noextattr --noqtn --noacl \
  "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
strip -S -x "$APP_DIR/Contents/MacOS/$APP_NAME"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/README.md" "$APP_DIR/Contents/Resources/README.md"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/COPYRIGHT" "$APP_DIR/Contents/Resources/COPYRIGHT"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/RC003-remote-photo.png" \
  "$APP_DIR/Contents/Resources/RC003-remote-photo.png"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/豆包输入法兼容说明.txt" \
  "$APP_DIR/Contents/Resources/豆包输入法兼容说明.txt"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

print "$APP_DIR"
