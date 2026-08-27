#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
STAMP="$(date +%Y%m%d-%H%M%S)"
VERSION="${RC003_TEST_VERSION:-1.9.15}"
BUILD="${RC003_TEST_BUILD:-155}"
SCRATCH="${REMOTE_MIC_RC003_SCRATCH_PATH:-/private/tmp/remote-mic-swiftpm/1.9.10-136/apple-silicon-sayall-ai}"
CACHE="${REMOTE_MIC_RC003_CACHE_PATH:-/private/tmp/remote-mic-swiftpm-cache/1.9.10-136/apple-silicon-sayall-ai}"
OUT_ROOT="$ROOT/dist/rc003-voice-extension-$STAMP"
APP="$OUT_ROOT/SayAll-RC003-VoiceExtension-Test.app"
ZIP="$ROOT/dist/SayAll-RC003-VoiceExtension-Test-$VERSION-$BUILD-$STAMP.zip"
NOTARY_PROFILE="${RC003_NOTARY_PROFILE:-RemoteMic-notary}"
NOTARY_ZIP="/private/tmp/SayAll-RC003-VoiceExtension-Test-$VERSION-$BUILD-$STAMP-notarization.zip"
IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application: lei qian (L3QHLDRPAY)}"

mkdir -p "$OUT_ROOT" "$ROOT/dist"
swift build -c debug \
  --scratch-path "$SCRATCH" \
  --cache-path "$CACHE" \
  --triple arm64-apple-macosx14.0
BIN_DIR="$(swift build -c debug \
  --scratch-path "$SCRATCH" \
  --cache-path "$CACHE" \
  --triple arm64-apple-macosx14.0 \
  --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
ditto "$BIN_DIR/RemoteMic" "$APP/Contents/MacOS/RemoteMic"
ditto "$BIN_DIR/SayAllMCP" "$APP/Contents/Helpers/SayAllMCP"
ditto "$ROOT/Resources/." "$APP/Contents/Resources"
ditto "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
SPARKLE="$SCRATCH/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE" ]]; then
  SPARKLE="$(find /private/tmp/remote-mic-swiftpm -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -print -quit)"
fi
test -d "$SPARKLE"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

plutil -replace CFBundleIdentifier -string "com.hd838a.RemoteMic.RC003VoiceExtensionTest" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "SayAll RC003 Voice Extension Test" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "SayAll RC003 长语音测试" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
plutil -insert RC003VoiceExtensionTestEnabled -bool true "$APP/Contents/Info.plist"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/RemoteMic"

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/SayAllMCP"
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

ditto -c -k --norsrc --noextattr --noacl --noqtn --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"

ditto "$ROOT/Testing/launch_rc003_voice_extension_test.command" "$OUT_ROOT/launch_rc003_voice_extension_test.command"
ditto "$ROOT/Testing/RC003VoiceExtensionPreview.md" "$OUT_ROOT/RC003VoiceExtensionPreview.md"
(cd "$ROOT/dist" && zip -qr -y -X "$ZIP" "$(basename "$OUT_ROOT")")
print "APP=$APP"
print "ZIP=$ZIP"
