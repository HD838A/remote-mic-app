#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="RemoteMic"
DISPLAY_NAME="无线麦"
OUTPUT_DIR="$ROOT/dist"
APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app"
SPARKLE_FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
SIGNING_IDENTITY_WAS_EXPLICIT=0
if [[ -n "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY_WAS_EXPLICIT=1
fi

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

cd "$ROOT"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  DEFAULT_KEYCHAIN="$(security default-keychain -d user | tr -d ' \"')"
  GIT_EMAIL="$(git config --get user.email || true)"
  if [[ -n "$GIT_EMAIL" ]] && security show-keychain-info "$DEFAULT_KEYCHAIN" >/dev/null 2>&1; then
    SIGNING_IDENTITY="$(
      security find-identity -p codesigning -v | awk -v email="$GIT_EMAIL" '
        index($0, email) {
          match($0, /"[^"]+"/)
          if (RSTART > 0) print substr($0, RSTART + 1, RLENGTH - 2)
          exit
        }
      '
    )"
  fi
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
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/README.md" "$APP_DIR/Contents/Resources/README.md"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/COPYRIGHT.md" "$APP_DIR/Contents/Resources/COPYRIGHT.md"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/LOGO-LICENSE.md" "$APP_DIR/Contents/Resources/LOGO-LICENSE.md"
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
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/豆包输入法兼容说明.md" \
  "$APP_DIR/Contents/Resources/豆包输入法兼容说明.md"
if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]]; then
  if ! codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_DIR"; then
    if [[ "$SIGNING_IDENTITY_WAS_EXPLICIT" -eq 1 ]]; then
      print -u2 "unable to use CODE_SIGN_IDENTITY: $SIGNING_IDENTITY"
      exit 1
    fi
    print -u2 "warning: matched signing identity is unavailable; using stable ad-hoc requirement"
    SIGNING_IDENTITY="-"
  fi
fi
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
  SIGNING_IDENTITY="-"
  BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$APP_DIR/Contents/Info.plist")"
  codesign \
    --force \
    --deep \
    --timestamp=none \
    --sign - \
    --requirements "=designated => identifier \"$BUNDLE_IDENTIFIER\"" \
    "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

print "$APP_DIR"
print "SIGNING IDENTITY: $SIGNING_IDENTITY"
