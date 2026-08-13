#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
if [[ "$#" -gt 1 ]]; then
  print -u2 "usage: $0 [APP]"
  exit 1
fi
APP="${1:-$RELEASE_OUTPUT_DIR/Remote Mic.app}"
PLIST="$APP/Contents/Info.plist"
BINARY="$APP/Contents/MacOS/RemoteMic"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
REQUIRE_SAYALL_AI_PACKAGE="${REQUIRE_SAYALL_AI_PACKAGE:-0}"
REQUIRE_SAYALL_MACRO_PLATFORM="${REQUIRE_SAYALL_MACRO_PLATFORM:-0}"

case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_NOTARIZATION" in
  0|1) ;;
  *) print -u2 "REQUIRE_NOTARIZATION must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_SAYALL_AI_PACKAGE" in
  0|1) ;;
  *) print -u2 "REQUIRE_SAYALL_AI_PACKAGE must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_SAYALL_MACRO_PLATFORM" in
  0|1) ;;
  *) print -u2 "REQUIRE_SAYALL_MACRO_PLATFORM must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && -z "$EXPECTED_DEVELOPER_TEAM_ID" ]]; then
  print -u2 "EXPECTED_DEVELOPER_TEAM_ID is required for Developer ID verification"
  exit 1
fi
if [[ "$REQUIRE_NOTARIZATION" == "1" && "$REQUIRE_DEVELOPER_ID_SIGNING" != "1" ]]; then
  print -u2 "notarization verification requires Developer ID verification"
  exit 1
fi

test -d "$APP"
test -f "$PLIST"
test -x "$BINARY"
test -d "$SPARKLE_FRAMEWORK"
test -x "$SPARKLE_FRAMEWORK/Versions/B/Sparkle"
test -x "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
test -x "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
if [[ -n "$(find "$APP" -type d ! -perm 0755 -print -quit)" ]]; then
  print -u2 "app bundle contains a directory without 0755 permissions"
  exit 1
fi
if [[ -n "$(find "$APP" -type f ! -perm 0644 ! -perm 0755 -print -quit)" ]]; then
  print -u2 "app bundle contains a file without 0644 or 0755 permissions"
  exit 1
fi
test -f "$APP/Contents/Resources/LICENSE.md"
test -f "$APP/Contents/Resources/README.md"
test -f "$APP/Contents/Resources/TECHNICAL.md"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -f "$APP/Contents/Resources/TROUBLESHOOTING.md"
test -f "$APP/Contents/Resources/COPYRIGHT.md"
test -f "$APP/Contents/Resources/LOGO-LICENSE.md"
test -f "$APP/Contents/Resources/FirstInstallGuide.md"
test -f "$APP/Contents/Resources/RC003-remote-photo.png"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/StatusIconTemplate.png"
test -f "$APP/Contents/Resources/StatusIconTemplate@2x.png"
test -f "$APP/Contents/Resources/StatusIconActiveTemplate.png"
test -f "$APP/Contents/Resources/StatusIconActiveTemplate@2x.png"
LOCALIZATION_DIRS=("$APP"/Contents/Resources/*.lproj(N))
if (( ${#LOCALIZATION_DIRS} == 0 )); then
  print -u2 "app bundle contains no localization resources"
  exit 1
fi
test -d "$APP/Contents/Resources/en.lproj"
test -f "$APP/Contents/Resources/en.lproj/Glossary.md"
for RESOURCE_DIR in "${LOCALIZATION_DIRS[@]}"; do
  test -f "$RESOURCE_DIR/InfoPlist.strings"
  test -f "$RESOURCE_DIR/Localizable.strings"
  plutil -lint "$RESOURCE_DIR/InfoPlist.strings"
  plutil -lint "$RESOURCE_DIR/Localizable.strings"
done
rg -q '^"app.name" = "Remote Mic";$' "$APP/Contents/Resources/en.lproj/Localizable.strings"
/usr/bin/ruby - "${LOCALIZATION_DIRS[@]}" <<'RUBY'
def strings(path)
  result = {}
  File.foreach(path, encoding: "UTF-8") do |line|
    match = line.match(/^"([^"]+)" = "(.*)";$/)
    result[match[1]] = match[2] if match
  end
  result
end

directories = ARGV
english_directory = directories.find { |path| File.basename(path) == "en.lproj" }
abort "English localization is required" unless english_directory
english = strings(File.join(english_directory, "Localizable.strings"))
abort "English localization is empty" if english.empty?
semantic_key = /\A[a-z0-9]+(?:[._][a-z0-9]+)*\z/
invalid_keys = english.keys.reject { |key| semantic_key.match?(key) }
abort "Invalid localization keys: #{invalid_keys.join(", ")}" unless invalid_keys.empty?

format_pattern = /%(?:[0-9]+\$)?[a-zA-Z@]/
restricted_terms = /RC003|ATVV|\bHID\b|\bUUID\b|virtual[ -]transport/i
directories.each do |directory|
  localized = strings(File.join(directory, "Localizable.strings"))
  missing = english.keys - localized.keys
  extra = localized.keys - english.keys
  abort "#{directory} has missing keys: #{missing.join(", ")}" unless missing.empty?
  abort "#{directory} has extra keys: #{extra.join(", ")}" unless extra.empty?
  localized.each do |key, value|
    abort "#{directory} has an empty value for #{key}" if value.empty?
    expected_formats = english.fetch(key).scan(format_pattern).sort
    actual_formats = value.scan(format_pattern).sort
    abort "#{directory} has mismatched formats for #{key}" unless actual_formats == expected_formats
    abort "#{directory} exposes a restricted term in #{key}" if value.match?(restricted_terms)
  end

  english_info = strings(File.join(english_directory, "InfoPlist.strings"))
  localized_info = strings(File.join(directory, "InfoPlist.strings"))
  abort "#{directory} has incomplete InfoPlist.strings" unless localized_info.keys.sort == english_info.keys.sort
end
RUBY

test "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = \
  "com.hd838a.RemoteMic"
test "$(plutil -extract LSUIElement raw -o - "$PLIST")" = "true"
test "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = \
  "$RELEASE_MIN_SYSTEM_VERSION"
test "$(plutil -extract CFBundleDevelopmentRegion raw -o - "$PLIST")" = "en"
test "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "Remote Mic"
test "$(plutil -extract CFBundleIconFile raw -o - "$PLIST")" = "AppIcon"
test -n "$(plutil -extract NSBluetoothAlwaysUsageDescription raw -o - "$PLIST")"
test "$(plutil -extract SUFeedURL raw -o - "$PLIST")" = "$RELEASE_FEED_URL"
test "$(plutil -extract SUEnableAutomaticChecks raw -o - "$PLIST")" = "true"
test "$(plutil -extract SUScheduledCheckInterval raw -o - "$PLIST")" = "86400"
test "$(plutil -extract SUAutomaticallyUpdate raw -o - "$PLIST")" = "false"
test "$(plutil -extract SUAllowsAutomaticUpdates raw -o - "$PLIST")" = "false"
test -n "$(plutil -extract SUPublicEDKey raw -o - "$PLIST")"
SAYALL_AI_INCLUDED="$(plutil -extract SayAllAIIncluded raw -o - "$PLIST" 2>/dev/null || true)"
if [[ "$SAYALL_AI_INCLUDED" == "true" ]]; then
  test -d "$APP/Contents/Resources/SayAllAI_SayAllAI.bundle"
  test -f "$APP/Contents/Resources/SayAllAI_SayAllAI.bundle/en.lproj/Localizable.strings"
  test -f "$APP/Contents/Resources/SayAllAI_SayAllAI.bundle/zh-Hans.lproj/Localizable.strings"
elif [[ -e "$APP/Contents/Resources/SayAllAI_SayAllAI.bundle" ]]; then
  print -u2 "SayAllAI resource bundle exists without the inclusion marker"
  exit 1
fi
if [[ "$REQUIRE_SAYALL_AI_PACKAGE" == "1" && "$SAYALL_AI_INCLUDED" != "true" ]]; then
  print -u2 "App is missing the required SayAllAI package marker"
  exit 1
fi
SAYALL_MACRO_PLATFORM_INCLUDED="$(plutil -extract SayAllMacroPlatformIncluded raw -o - "$PLIST" 2>/dev/null || true)"
SAYALL_MACRO_RESOURCE_BUNDLE="$APP/Contents/Resources/SayAllMacroPlatform_SayAllMacroRemoteMic.bundle"
if [[ "$SAYALL_MACRO_PLATFORM_INCLUDED" == "true" ]]; then
  test -d "$SAYALL_MACRO_RESOURCE_BUNDLE"
  test -f "$SAYALL_MACRO_RESOURCE_BUNDLE/en.lproj/Localizable.strings"
  if [[ ! -f "$SAYALL_MACRO_RESOURCE_BUNDLE/zh-Hans.lproj/Localizable.strings" && \
        ! -f "$SAYALL_MACRO_RESOURCE_BUNDLE/zh-hans.lproj/Localizable.strings" ]]; then
    print -u2 "SayAll macro platform Chinese localization is missing"
    exit 1
  fi
elif [[ -e "$SAYALL_MACRO_RESOURCE_BUNDLE" ]]; then
  print -u2 "SayAll macro platform resource bundle exists without the inclusion marker"
  exit 1
fi
if [[ "$REQUIRE_SAYALL_MACRO_PLATFORM" == "1" && "$SAYALL_MACRO_PLATFORM_INCLUDED" != "true" ]]; then
  print -u2 "App is missing the required SayAll macro platform marker"
  exit 1
fi

codesign --verify --deep --strict "$APP"
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" ]]; then
  RELAY_URL="$(plutil -extract RemoteWebRelayURL raw -o - "$PLIST" 2>/dev/null || true)"
  if [[ "$RELAY_URL" != wss://?*/ws ]]; then
    print -u2 "Developer ID app is missing a production Web Remote relay URL"
    exit 1
  fi
  EARLY_ACCESS_URL="$(plutil -extract EarlyAccessServiceURL raw -o - "$PLIST" 2>/dev/null || true)"
  if ! print -r -- "$EARLY_ACCESS_URL" | rg -q '^https://[^/?#]+/?$'; then
    print -u2 "Developer ID app is missing a production root HTTPS Early Access URL"
    exit 1
  fi
  SIGNATURE_DETAILS="$(codesign -dvvv "$APP" 2>&1)"
  print -r -- "$SIGNATURE_DETAILS" | rg -q '^Authority=Developer ID Application:'
  print -r -- "$SIGNATURE_DETAILS" | rg -q "^TeamIdentifier=$EXPECTED_DEVELOPER_TEAM_ID$"
  print -r -- "$SIGNATURE_DETAILS" | rg -q '^CodeDirectory .*flags=.*runtime'
  for signed_component in \
    "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" \
    "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" \
    "$SPARKLE_FRAMEWORK"; do
    COMPONENT_SIGNATURE_DETAILS="$(codesign -dvvv "$signed_component" 2>&1)"
    print -r -- "$COMPONENT_SIGNATURE_DETAILS" | rg -q '^Authority=Developer ID Application:'
    print -r -- "$COMPONENT_SIGNATURE_DETAILS" | \
      rg -q "^TeamIdentifier=$EXPECTED_DEVELOPER_TEAM_ID$"
    print -r -- "$COMPONENT_SIGNATURE_DETAILS" | \
      rg -q '^CodeDirectory .*flags=.*runtime'
  done
fi
file "$BINARY" | rg -q 'Mach-O 64-bit executable'
ARCHS="$(lipo -archs "$BINARY")"
test "$ARCHS" = "$RELEASE_ARCH"
xcrun vtool -show-build "$BINARY" | rg -Fq "minos $RELEASE_MIN_SYSTEM_VERSION"
otool -l "$BINARY" | rg -A2 'LC_RPATH' | rg -q '@executable_path/\.\./Frameworks'

if [[ "$RELEASE_VARIANT" == "intel" ]]; then
  for sparkle_binary in \
    "$SPARKLE_FRAMEWORK/Versions/B/Sparkle" \
    "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" \
    "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater" \
    "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
    test "$(lipo -archs "$sparkle_binary")" = "x86_64"
  done
fi

EXPECTED_APP_FILES=$'Contents/Info.plist\nContents/MacOS/RemoteMic\nContents/Resources/AppIcon.icns\nContents/Resources/COPYRIGHT.md\nContents/Resources/FirstInstallGuide.md\nContents/Resources/LICENSE.md\nContents/Resources/LOGO-LICENSE.md\nContents/Resources/RC003-remote-photo.png\nContents/Resources/README.md\nContents/Resources/StatusIconActiveTemplate.png\nContents/Resources/StatusIconActiveTemplate@2x.png\nContents/Resources/StatusIconTemplate.png\nContents/Resources/StatusIconTemplate@2x.png\nContents/Resources/TECHNICAL.md\nContents/Resources/THIRD_PARTY_NOTICES.md\nContents/Resources/TROUBLESHOOTING.md\nContents/_CodeSignature/CodeResources'
while IFS= read -r expected_file; do
  test -f "$APP/$expected_file"
done <<< "$EXPECTED_APP_FILES"
for source_localization_dir in "$ROOT"/Resources/*.lproj(N); do
  localization_name="${source_localization_dir:t}"
  while IFS= read -r source_file; do
    relative_path="${source_file#$source_localization_dir/}"
    test -f "$APP/Contents/Resources/$localization_name/$relative_path"
  done < <(find "$source_localization_dir" -type f | LC_ALL=C sort)
done

if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' "$APP/Contents"; then
  print -u2 "bundle contains a forbidden local path or example device address"
  exit 1
fi

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  xcrun stapler validate "$APP"
  /usr/sbin/spctl -a -vv -t open --context context:primary-signature "$APP"
fi

print "APP VERIFY PASS: $APP"
print "RELEASE VARIANT: $RELEASE_VARIANT"
