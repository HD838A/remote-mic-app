#!/bin/zsh
set -euo pipefail
umask 022

ROOT="${0:A:h:h}"
SOURCE_APP="$ROOT/dist/SayAll.app"
OUTPUT_DIR="$ROOT/dist/local-dev"
DEV_APP="$OUTPUT_DIR/SayAll Dev.app"
DEV_BUNDLE_ID="com.hd838a.RemoteMic.localdev"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

REMOTE_MIC_BUILD_SCRATCH_PATH="${REMOTE_MIC_BUILD_SCRATCH_PATH:-$ROOT/.build}" \
REMOTE_MIC_BUILD_CACHE_PATH="${REMOTE_MIC_BUILD_CACHE_PATH:-$ROOT/.build/cache}" \
CONFIGURATION="${CONFIGURATION:-debug}" \
CODE_SIGN_IDENTITY=- \
  "$ROOT/scripts/build-app.sh"

case "$DEV_APP" in
  "$ROOT/dist/local-dev/SayAll Dev.app") ;;
  *) print -u2 "refusing to replace unexpected development app path"; exit 1 ;;
esac
rm -rf -- "$DEV_APP"
mkdir -p "$OUTPUT_DIR"
ditto --norsrc --noextattr --noqtn --noacl "$SOURCE_APP" "$DEV_APP"

INFO_PLIST="$DEV_APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "SayAll Dev" "$INFO_PLIST"
plutil -replace CFBundleName -string "SayAll Dev" "$INFO_PLIST"
plutil -replace CFBundleIdentifier -string "$DEV_BUNDLE_ID" "$INFO_PLIST"
plutil -replace SUEnableAutomaticChecks -bool false "$INFO_PLIST"
plutil -replace SUAutomaticallyUpdate -bool false "$INFO_PLIST"
plutil -replace SUAllowsAutomaticUpdates -bool false "$INFO_PLIST"
plutil -replace SUScheduledCheckInterval -integer 0 "$INFO_PLIST"
plutil -remove SayAllDevelopmentBuild "$INFO_PLIST" 2>/dev/null || true
plutil -insert SayAllDevelopmentBuild -bool true "$INFO_PLIST"
plutil -remove SayAllDevelopmentSourceCommit "$INFO_PLIST" 2>/dev/null || true
plutil -insert SayAllDevelopmentSourceCommit -string "$(git -C "$ROOT" rev-parse HEAD)" "$INFO_PLIST"

# System Settings and LaunchServices prefer localized bundle names over the
# values in Info.plist. Keep every local development identity visibly distinct
# from the installed production app so privacy entries cannot look duplicated.
for LOCALIZED_INFO in \
  "$DEV_APP/Contents/Resources/en.lproj/InfoPlist.strings" \
  "$DEV_APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
do
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName SayAll Dev" "$LOCALIZED_INFO"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName SayAll Dev" "$LOCALIZED_INFO"
done

codesign \
  --force \
  --timestamp=none \
  --sign - \
  --requirements "=designated => identifier \"$DEV_BUNDLE_ID\"" \
  "$DEV_APP"
codesign --verify --deep --strict "$DEV_APP"

test "$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")" = "$DEV_BUNDLE_ID"
test "$(plutil -extract CFBundleDisplayName raw -o - "$INFO_PLIST")" = "SayAll Dev"
test "$(plutil -extract SayAllDevelopmentBuild raw -o - "$INFO_PLIST")" = "true"
test "$(plutil -extract SUEnableAutomaticChecks raw -o - "$INFO_PLIST")" = "false"
for LOCALIZED_INFO in \
  "$DEV_APP/Contents/Resources/en.lproj/InfoPlist.strings" \
  "$DEV_APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
do
  test "$(plutil -extract CFBundleDisplayName raw -o - "$LOCALIZED_INFO")" = "SayAll Dev"
  test "$(plutil -extract CFBundleName raw -o - "$LOCALIZED_INFO")" = "SayAll Dev"
done

print "$DEV_APP"
print "LOCAL DEVELOPMENT BUILD: ad-hoc signed, update checks disabled, not for distribution"
