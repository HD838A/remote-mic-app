#!/bin/zsh
set -euo pipefail
umask 022

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="RemoteMic"
DISPLAY_NAME="Remote Mic"
OUTPUT_DIR="$RELEASE_OUTPUT_DIR"
APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"
REQUIRE_WEB_REMOTE_CONFIGURATION="${REQUIRE_WEB_REMOTE_CONFIGURATION:-0}"
REQUIRE_EARLY_ACCESS_CONFIGURATION="${REQUIRE_EARLY_ACCESS_CONFIGURATION:-0}"
REQUIRE_SAYALL_AI_PACKAGE="${REQUIRE_SAYALL_AI_PACKAGE:-0}"
REQUIRE_SAYALL_MACRO_PLATFORM="${REQUIRE_SAYALL_MACRO_PLATFORM:-0}"
SAYALL_AI_PACKAGE_PATH="${SAYALL_AI_PACKAGE_PATH:-}"
SAYALL_MACRO_PLATFORM_PATH="${SAYALL_MACRO_PLATFORM_PATH:-}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

cd "$ROOT"

case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_WEB_REMOTE_CONFIGURATION" in
  0|1) ;;
  *) print -u2 "REQUIRE_WEB_REMOTE_CONFIGURATION must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_EARLY_ACCESS_CONFIGURATION" in
  0|1) ;;
  *) print -u2 "REQUIRE_EARLY_ACCESS_CONFIGURATION must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_SAYALL_AI_PACKAGE" in
  0|1) ;;
  *) print -u2 "REQUIRE_SAYALL_AI_PACKAGE must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_SAYALL_MACRO_PLATFORM" in
  0|1) ;;
  *) print -u2 "REQUIRE_SAYALL_MACRO_PLATFORM must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && "$SIGNING_IDENTITY" == "-" ]]; then
  print -u2 "Developer ID Application signing is required"
  exit 1
fi

if [[ -z "$SAYALL_AI_PACKAGE_PATH" && -f "$ROOT/../sayall-ai/Package.swift" ]]; then
  SAYALL_AI_PACKAGE_PATH="$ROOT/../sayall-ai"
fi
if [[ -n "$SAYALL_AI_PACKAGE_PATH" ]]; then
  if [[ ! -f "$SAYALL_AI_PACKAGE_PATH/Package.swift" ]]; then
    print -u2 "SAYALL_AI_PACKAGE_PATH must contain Package.swift"
    exit 1
  fi
  SAYALL_AI_PACKAGE_PATH="${SAYALL_AI_PACKAGE_PATH:A}"
  export SAYALL_AI_PACKAGE_PATH
  SAYALL_AI_INCLUDED=true
else
  SAYALL_AI_INCLUDED=false
fi
if [[ "$REQUIRE_SAYALL_AI_PACKAGE" == "1" && "$SAYALL_AI_INCLUDED" != "true" ]]; then
  print -u2 "A SayAllAI package is required for this build"
  exit 1
fi

if [[ -n "$SAYALL_MACRO_PLATFORM_PATH" ]]; then
  if [[ ! -f "$SAYALL_MACRO_PLATFORM_PATH/Package.swift" ]]; then
    print -u2 "SAYALL_MACRO_PLATFORM_PATH must contain Package.swift"
    exit 1
  fi
  SAYALL_MACRO_PLATFORM_PATH="${SAYALL_MACRO_PLATFORM_PATH:A}"
  MACRO_PAGE_SOURCE="$SAYALL_MACRO_PLATFORM_PATH/Sources/SayAllMacroRemoteMic/RemoteMicMacroView.swift"
  if [[ ! -f "$MACRO_PAGE_SOURCE" ]] || \
      /usr/bin/grep -Eq 'bundle:[[:space:]]*\.module' "$MACRO_PAGE_SOURCE"; then
    print -u2 "SayAll macro page bypasses the packaged resource resolver"
    exit 1
  fi
  export SAYALL_MACRO_PLATFORM_PATH
  SAYALL_MACRO_PLATFORM_INCLUDED=true
else
  SAYALL_MACRO_PLATFORM_INCLUDED=false
fi
if [[ "$REQUIRE_SAYALL_MACRO_PLATFORM" == "1" && "$SAYALL_MACRO_PLATFORM_INCLUDED" != "true" ]]; then
  print -u2 "A SayAll macro platform package is required for this build"
  exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
if [[ "$SAYALL_AI_INCLUDED" == "true" && "$SAYALL_MACRO_PLATFORM_INCLUDED" == "true" ]]; then
  SCRATCH_FLAVOR="sayall-ai-macro-platform"
elif [[ "$SAYALL_AI_INCLUDED" == "true" ]]; then
  SCRATCH_FLAVOR="sayall-ai"
elif [[ "$SAYALL_MACRO_PLATFORM_INCLUDED" == "true" ]]; then
  SCRATCH_FLAVOR="macro-platform"
else
  SCRATCH_FLAVOR="public"
fi
DEFAULT_SCRATCH_PATH="/private/tmp/remote-mic-swiftpm/$VERSION-$BUILD/$RELEASE_VARIANT-$SCRATCH_FLAVOR"
BUILD_SCRATCH_PATH="${REMOTE_MIC_BUILD_SCRATCH_PATH:-$DEFAULT_SCRATCH_PATH}"
SPARKLE_FRAMEWORK="$BUILD_SCRATCH_PATH/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

xcrun swift build \
  --scratch-path "$BUILD_SCRATCH_PATH" \
  -c "$CONFIGURATION" \
  --triple "$RELEASE_TRIPLE"
BIN_DIR="$(xcrun swift build \
  --scratch-path "$BUILD_SCRATCH_PATH" \
  -c "$CONFIGURATION" \
  --triple "$RELEASE_TRIPLE" \
  --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"

case "$APP_DIR" in
  "$ROOT/dist/"*.app|"$ROOT/dist/intel/"*.app) ;;
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
plutil -remove SayAllAIIncluded "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
plutil -insert SayAllAIIncluded -bool "$SAYALL_AI_INCLUDED" \
  "$APP_DIR/Contents/Info.plist"
plutil -remove SayAllMacroPlatformIncluded "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
plutil -insert SayAllMacroPlatformIncluded -bool "$SAYALL_MACRO_PLATFORM_INCLUDED" \
  "$APP_DIR/Contents/Info.plist"
if [[ "$RELEASE_VARIANT" == "intel" ]]; then
  plutil -replace LSMinimumSystemVersion -string "$RELEASE_MIN_SYSTEM_VERSION" \
    "$APP_DIR/Contents/Info.plist"
  plutil -replace SUFeedURL -string "$RELEASE_FEED_URL" \
    "$APP_DIR/Contents/Info.plist"
fi
if [[ -n "${REMOTE_WEB_RELAY_URL:-}" ]]; then
  plutil -remove RemoteWebRelayURL "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
  plutil -insert RemoteWebRelayURL -string "$REMOTE_WEB_RELAY_URL" \
    "$APP_DIR/Contents/Info.plist"
fi
if [[ -n "${EARLY_ACCESS_SERVICE_URL:-}" ]]; then
  if ! print -r -- "$EARLY_ACCESS_SERVICE_URL" | rg -q '^https://[^/?#]+/?$'; then
    print -u2 "EARLY_ACCESS_SERVICE_URL must be a root HTTPS URL"
    exit 1
  fi
  plutil -remove EarlyAccessServiceURL "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
  plutil -insert EarlyAccessServiceURL -string "$EARLY_ACCESS_SERVICE_URL" \
    "$APP_DIR/Contents/Info.plist"
fi
if [[ -n "${REMOTE_MIC_SENTRY_DSN:-}" ]]; then
  if ! print -r -- "$REMOTE_MIC_SENTRY_DSN" | rg -q '^https://[^[:space:]@]+@[^[:space:]/]+/.+$'; then
    print -u2 "REMOTE_MIC_SENTRY_DSN must be a valid HTTPS Sentry DSN"
    exit 1
  fi
  plutil -remove RemoteMicSentryDSN "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
  plutil -insert RemoteMicSentryDSN -string "$REMOTE_MIC_SENTRY_DSN" \
    "$APP_DIR/Contents/Info.plist"
else
  plutil -remove RemoteMicSentryDSN "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi
if [[ "$REQUIRE_WEB_REMOTE_CONFIGURATION" == "1" ]]; then
  RELAY_URL="$(plutil -extract RemoteWebRelayURL raw -o - \
    "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$RELAY_URL" != wss://?*/ws ]]; then
    print -u2 "A production wss:// relay URL ending in /ws is required"
    exit 1
  fi
fi
if [[ "$REQUIRE_EARLY_ACCESS_CONFIGURATION" == "1" ]]; then
  EARLY_ACCESS_URL="$(plutil -extract EarlyAccessServiceURL raw -o - \
    "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
  if ! print -r -- "$EARLY_ACCESS_URL" | rg -q '^https://[^/?#]+/?$'; then
    print -u2 "A production root HTTPS Early Access URL is required"
    exit 1
  fi
fi
mkdir -p "$APP_DIR/Contents/Frameworks"
ditto --norsrc --noextattr --noqtn --noacl \
  "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
if [[ "$RELEASE_VARIANT" == "intel" ]]; then
  for sparkle_binary in \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
    thin_binary="$sparkle_binary.thin"
    /usr/bin/lipo "$sparkle_binary" -thin "$RELEASE_ARCH" -output "$thin_binary"
    /bin/chmod 755 "$thin_binary"
    /bin/mv "$thin_binary" "$sparkle_binary"
  done
fi
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
LOCALIZATION_DIRS=("$ROOT"/Resources/*.lproj(N))
if (( ${#LOCALIZATION_DIRS} == 0 )); then
  print -u2 "no localization resources found"
  exit 1
fi
for localization_dir in "${LOCALIZATION_DIRS[@]}"; do
  localization="${localization_dir:t}"
  ditto --norsrc --noextattr --noqtn --noacl \
    "$localization_dir" \
    "$APP_DIR/Contents/Resources/$localization"
done
if [[ "$SAYALL_AI_INCLUDED" == "true" ]]; then
  SAYALL_AI_RESOURCE_BUNDLE="$BIN_DIR/SayAllAI_SayAllAI.bundle"
  if [[ ! -d "$SAYALL_AI_RESOURCE_BUNDLE" ]]; then
    print -u2 "SayAllAI resource bundle is missing from the Swift build"
    exit 1
  fi
  ditto --norsrc --noextattr --noqtn --noacl \
    "$SAYALL_AI_RESOURCE_BUNDLE" \
    "$APP_DIR/Contents/Resources/SayAllAI_SayAllAI.bundle"
fi
if [[ "$SAYALL_MACRO_PLATFORM_INCLUDED" == "true" ]]; then
  SAYALL_MACRO_RESOURCE_BUNDLE="$BIN_DIR/SayAllMacroPlatform_SayAllMacroRemoteMic.bundle"
  if [[ ! -d "$SAYALL_MACRO_RESOURCE_BUNDLE" ]]; then
    print -u2 "SayAll macro platform resource bundle is missing from the Swift build"
    exit 1
  fi
  ditto --norsrc --noextattr --noqtn --noacl \
    "$SAYALL_MACRO_RESOURCE_BUNDLE" \
    "$APP_DIR/Contents/Resources/SayAllMacroPlatform_SayAllMacroRemoteMic.bundle"
fi
SPARKLE_VERSION_DIR="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --preserve-metadata=entitlements \
    --sign "$SIGNING_IDENTITY" \
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$SPARKLE_VERSION_DIR/Autoupdate"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$SPARKLE_VERSION_DIR/Updater.app"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$APP_DIR/Contents/Info.plist")"
  codesign \
    --force \
    --timestamp=none \
    --sign - \
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
  codesign \
    --force \
    --timestamp=none \
    --preserve-metadata=entitlements \
    --sign - \
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
  codesign \
    --force \
    --timestamp=none \
    --sign - \
    "$SPARKLE_VERSION_DIR/Autoupdate"
  codesign \
    --force \
    --timestamp=none \
    --sign - \
    "$SPARKLE_VERSION_DIR/Updater.app"
  codesign \
    --force \
    --timestamp=none \
    --sign - \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework"
  codesign \
    --force \
    --timestamp=none \
    --sign - \
    --requirements "=designated => identifier \"$BUNDLE_IDENTIFIER\"" \
    "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

print "$APP_DIR"
print "RELEASE VARIANT: $RELEASE_VARIANT"
print "SIGNING IDENTITY: $SIGNING_IDENTITY"
