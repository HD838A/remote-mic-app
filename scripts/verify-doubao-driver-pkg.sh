#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
PACKAGE="${1:?usage: verify-doubao-driver-pkg.sh PACKAGE install|uninstall}"
MODE="${2:?usage: verify-doubao-driver-pkg.sh PACKAGE install|uninstall}"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remote-mic-driver-package-verify.XXXXXX)"
EXPANDED="$WORK_DIR/expanded"
FULL_EXPANDED="$WORK_DIR/full-expanded"
PAYLOAD_FILES="$WORK_DIR/payload-files"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remote-mic-driver-package-verify.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected verification path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
case "$REQUIRE_NOTARIZATION" in
  0|1) ;;
  *) print -u2 "REQUIRE_NOTARIZATION must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && -z "$EXPECTED_DEVELOPER_TEAM_ID" ]]; then
  print -u2 "EXPECTED_DEVELOPER_TEAM_ID is required for Developer ID verification"
  exit 1
fi
if [[ "$REQUIRE_NOTARIZATION" == "1" && "$REQUIRE_DEVELOPER_ID_SIGNING" != "1" ]]; then
  print -u2 "notarization verification requires Developer ID verification"
  exit 1
fi

test -f "$PACKAGE"
/usr/sbin/pkgutil --expand "$PACKAGE" "$EXPANDED"
test -f "$EXPANDED/PackageInfo"
if [[ -d "$EXPANDED/Scripts" ]] && \
   rg -n --pcre2 \
     '(?<![[:alnum:]_.-])(?:/usr/bin/)?(?:lipo|vtool|xcrun|xcode-select|xcodebuild|swift|swiftc|clang)(?![[:alnum:]_.-])' \
     "$EXPANDED/Scripts"; then
  print -u2 "package scripts must not require Xcode or Command Line Tools"
  exit 1
fi

case "$MODE" in
  install)
    /usr/bin/grep -Fq 'identifier="com.hd838a.RemoteMic.installer"' "$EXPANDED/PackageInfo"
    /usr/bin/grep -Fq '<payload ' "$EXPANDED/PackageInfo"
    /usr/sbin/pkgutil --payload-files "$PACKAGE" > "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Applications/Remote Mic.app/Contents/Info.plist' "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Applications/Remote Mic.app/Contents/MacOS/RemoteMic' "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Library/Application Support/RemoteMic/Installer/MiRemoteV2ch.driver/Contents/Info.plist' "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Library/Application Support/RemoteMic/Installer/MiRemoteV2ch.driver/Contents/MacOS/MiRemoteV2ch' "$PAYLOAD_FILES"
    test -x "$EXPANDED/Scripts/preinstall"
    test -x "$EXPANDED/Scripts/postinstall"
    test -f "$EXPANDED/Scripts/release-variant.plist"
    test "$(/usr/bin/plutil -extract ExpectedArchitecture raw -o - \
      "$EXPANDED/Scripts/release-variant.plist")" = "$RELEASE_ARCH"
    test "$(/usr/bin/plutil -extract MinimumSystemMajor raw -o - \
      "$EXPANDED/Scripts/release-variant.plist")" = "$RELEASE_MIN_SYSTEM_MAJOR"
    test "$(/usr/bin/plutil -extract MinimumSystemVersion raw -o - \
      "$EXPANDED/Scripts/release-variant.plist")" = "$RELEASE_MIN_SYSTEM_VERSION"
    test "$(/usr/bin/plutil -extract PackageBuild raw -o - \
      "$EXPANDED/Scripts/release-variant.plist")" = "$BUILD"
    /usr/bin/grep -Fqx 'DESTINATION="${TARGET_VOLUME%/}/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"' "$EXPANDED/Scripts/preinstall"
    /usr/bin/grep -Fqx 'APP_DESTINATION="${TARGET_VOLUME%/}/Applications/Remote Mic.app"' "$EXPANDED/Scripts/preinstall"
    if /usr/bin/grep -Fq '/bin/rm -rf -- "$APP_DESTINATION"' "$EXPANDED/Scripts/preinstall"; then
      print -u2 "preinstall must not delete an existing Remote Mic.app"
      exit 1
    fi
    /usr/bin/grep -Fq 'will be updated atomically' "$EXPANDED/Scripts/preinstall"
    /usr/bin/grep -Fq 'INSTALLED_BUILD=' "$EXPANDED/Scripts/preinstall"
    /usr/bin/grep -Fq 'The existing app was left intact. Use a newer installer.' \
      "$EXPANDED/Scripts/preinstall"
    /usr/bin/grep -Fq '/bin/rm -rf -- "$LEGACY_APP_DESTINATION"' "$EXPANDED/Scripts/preinstall"
    /usr/bin/grep -Fq 'driver_is_healthy_and_current()' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fq '/usr/bin/file -b "$1"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fq 'The existing MiRemoteV 2ch is healthy and was kept in place.' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fq '/usr/bin/codesign --verify --deep --strict "$DESTINATION"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx 'APP_DESTINATION="${TARGET_VOLUME%/}/Applications/Remote Mic.app"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx 'LEGACY_APP_DESTINATION="${TARGET_VOLUME%/}/Applications/无线麦.app"' "$EXPANDED/Scripts/postinstall"
    for sparkle_executable in \
      '$SPARKLE_VERSION_DIR/Sparkle' \
      '$SPARKLE_VERSION_DIR/Autoupdate' \
      '$SPARKLE_VERSION_DIR/Updater.app/Contents/MacOS/Updater' \
      '$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc/Contents/MacOS/Installer' \
      '$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc/Contents/MacOS/Downloader'; do
      /usr/bin/grep -Fq "$sparkle_executable" "$EXPANDED/Scripts/postinstall"
    done
    /usr/bin/grep -Fqx 'for app_executable in "${APP_EXECUTABLES[@]}"; do' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx '  /bin/chmod 755 "$app_executable"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx '  test -x "$app_executable"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx '/usr/bin/codesign --verify --deep --strict "$APP_DESTINATION"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fq 'CURRENT_ARCHITECTURE="$(/usr/bin/uname -m)"' \
      "$EXPANDED/Scripts/preinstall"
    /usr/bin/grep -Fq 'if [[ "$CURRENT_ARCHITECTURE" != "$EXPECTED_ARCHITECTURE" ]]; then' \
      "$EXPANDED/Scripts/preinstall"
    /usr/bin/grep -Fq 'test "$(/usr/bin/uname -m)" = "$EXPECTED_ARCHITECTURE"' \
      "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx 'if [[ "$DRIVER_CHANGED" -eq 1 ]]; then' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx '  /usr/bin/killall coreaudiod' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fq '/bin/launchctl asuser "$CONSOLE_UID"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fq '/usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/open "$APP_DESTINATION"' "$EXPANDED/Scripts/postinstall"
    /usr/sbin/pkgutil --expand-full "$PACKAGE" "$FULL_EXPANDED"
    PAYLOAD_APP="$(/usr/bin/find "$FULL_EXPANDED" -type d -path '*/Applications/Remote Mic.app' -print -quit)"
    PAYLOAD_DRIVER="$(/usr/bin/find "$FULL_EXPANDED" -type d -path '*/Library/Application Support/RemoteMic/Installer/MiRemoteV2ch.driver' -print -quit)"
    test -n "$PAYLOAD_APP"
    test -n "$PAYLOAD_DRIVER"
    test "$(/usr/bin/lipo -archs "$PAYLOAD_APP/Contents/MacOS/RemoteMic")" = "$RELEASE_ARCH"
    test "$(/usr/bin/lipo -archs "$PAYLOAD_DRIVER/Contents/MacOS/MiRemoteV2ch")" = "$RELEASE_ARCH"
    test "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - \
      "$PAYLOAD_APP/Contents/Info.plist")" = "$RELEASE_MIN_SYSTEM_VERSION"
    test "$(/usr/bin/plutil -extract SUFeedURL raw -o - \
      "$PAYLOAD_APP/Contents/Info.plist")" = "$RELEASE_FEED_URL"
    test "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
      "$PAYLOAD_APP/Contents/Info.plist")" = "$VERSION"
    test "$(/usr/bin/plutil -extract CFBundleVersion raw -o - \
      "$PAYLOAD_APP/Contents/Info.plist")" = "$BUILD"
    ;;
  uninstall)
    /usr/bin/grep -Fq 'identifier="com.hd838a.MiRemoteV2ch.uninstaller"' "$EXPANDED/PackageInfo"
    if /usr/bin/grep -Fq '<payload ' "$EXPANDED/PackageInfo"; then
      print -u2 "uninstall package unexpectedly contains a payload declaration"
      exit 1
    fi
    test -x "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx '/bin/rm -rf -- "$DESTINATION"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx '/usr/bin/killall coreaudiod' "$EXPANDED/Scripts/postinstall"
    ;;
  *)
    print -u2 "unknown package mode: $MODE"
    exit 1
    ;;
esac

/usr/bin/grep -Fq "version=\"$VERSION\"" "$EXPANDED/PackageInfo"
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" ]]; then
  SIGNATURE_DETAILS="$(/usr/sbin/pkgutil --check-signature "$PACKAGE" 2>&1)"
  print -r -- "$SIGNATURE_DETAILS" | rg -q 'Status: signed by a developer certificate issued by Apple for distribution'
  print -r -- "$SIGNATURE_DETAILS" | rg -q "Developer ID Installer: .*\\($EXPECTED_DEVELOPER_TEAM_ID\\)"
fi
if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  xcrun stapler validate "$PACKAGE"
  /usr/sbin/spctl -a -vv -t install "$PACKAGE"
fi
print "DOUBAO DRIVER PACKAGE VERIFY PASS: $PACKAGE ($MODE)"
print "RELEASE VARIANT: $RELEASE_VARIANT"
