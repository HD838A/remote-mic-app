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
INSTALLER_CHOICES="$WORK_DIR/installer-choices.xml"
INSTALLER_ERROR="$WORK_DIR/installer-error.txt"

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
PACKAGE_INFO="$EXPANDED/PackageInfo"
SCRIPTS_DIR="$EXPANDED/Scripts"
COMPONENT_PACKAGE=""

case "$MODE" in
  install)
    DISTRIBUTION="$EXPANDED/Distribution"
    COMPONENT_PACKAGE="$EXPANDED/RemoteMicComponent.pkg"
    test -f "$DISTRIBUTION"
    test -d "$COMPONENT_PACKAGE"
    test -f "$EXPANDED/Resources/en.lproj/Localizable.strings"
    test -f "$EXPANDED/Resources/zh-Hans.lproj/Localizable.strings"
    /usr/bin/xmllint --noout "$DISTRIBUTION"
    /usr/bin/plutil -lint "$EXPANDED/Resources/en.lproj/Localizable.strings"
    /usr/bin/plutil -lint "$EXPANDED/Resources/zh-Hans.lproj/Localizable.strings"
    /usr/bin/grep -Fq 'hostArchitectures="arm64,x86_64"' "$DISTRIBUTION"
    /usr/bin/grep -Fq "system.sysctl('hw.optional.arm64')" "$DISTRIBUTION"
    /usr/bin/grep -Fq "my.result.type = 'Fatal'" "$DISTRIBUTION"
    /usr/bin/grep -Fq 'my.result.message = system.localizedString' "$DISTRIBUTION"
    /usr/bin/grep -Fq '<installation-check script="installationCheck()"/>' "$DISTRIBUTION"
    /usr/bin/grep -Fq 'RemoteMicComponent.pkg</pkg-ref>' "$DISTRIBUTION"
    case "$RELEASE_VARIANT" in
      apple-silicon)
        WRONG_ARCHITECTURE_KEY="wrong_architecture_apple_silicon"
        UNSUPPORTED_SYSTEM_KEY="unsupported_system_apple_silicon"
        ALTERNATE_PACKAGE_LABEL="Intel"
        ;;
      intel)
        WRONG_ARCHITECTURE_KEY="wrong_architecture_intel"
        UNSUPPORTED_SYSTEM_KEY="unsupported_system_intel"
        ALTERNATE_PACKAGE_LABEL="Apple Silicon"
        ;;
    esac
    for localization in en.lproj zh-Hans.lproj; do
      LOCALIZABLE="$EXPANDED/Resources/$localization/Localizable.strings"
      /usr/bin/grep -Fq "\"$WRONG_ARCHITECTURE_KEY\"" "$LOCALIZABLE"
      /usr/bin/grep -Fq "\"$UNSUPPORTED_SYSTEM_KEY\"" "$LOCALIZABLE"
      /usr/bin/grep -Fq "$ALTERNATE_PACKAGE_LABEL" "$LOCALIZABLE"
    done
    /usr/bin/grep -Fq "system.localizedString('$WRONG_ARCHITECTURE_KEY')" "$DISTRIBUTION"
    /usr/bin/grep -Fq "system.localizedString('$UNSUPPORTED_SYSTEM_KEY')" "$DISTRIBUTION"

    if [[ "$(/usr/sbin/sysctl -in hw.optional.arm64 2>/dev/null || print 0)" == "1" ]]; then
      CURRENT_HARDWARE_ARCHITECTURE="arm64"
    else
      CURRENT_HARDWARE_ARCHITECTURE="x86_64"
    fi
    CURRENT_SYSTEM_MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
    if [[ "$CURRENT_HARDWARE_ARCHITECTURE" != "$RELEASE_ARCH" ]]; then
      if /usr/sbin/installer -showChoicesXML -pkg "$PACKAGE" -target / \
          > "$INSTALLER_CHOICES" 2> "$INSTALLER_ERROR"; then
        print -u2 "wrong-architecture product package unexpectedly passed Installer evaluation"
        exit 1
      fi
      /usr/bin/grep -Fq "$ALTERNATE_PACKAGE_LABEL" "$INSTALLER_ERROR"
    elif [[ "$CURRENT_SYSTEM_MAJOR" -ge "$RELEASE_MIN_SYSTEM_MAJOR" ]]; then
      /usr/sbin/installer -showChoicesXML -pkg "$PACKAGE" -target / \
        > "$INSTALLER_CHOICES" 2> "$INSTALLER_ERROR"
      /usr/bin/grep -Fq '<string>remote-mic</string>' "$INSTALLER_CHOICES"
    else
      if /usr/sbin/installer -showChoicesXML -pkg "$PACKAGE" -target / \
          > "$INSTALLER_CHOICES" 2> "$INSTALLER_ERROR"; then
        print -u2 "unsupported-system product package unexpectedly passed Installer evaluation"
        exit 1
      fi
      /usr/bin/grep -Fq "macOS $RELEASE_MIN_SYSTEM_MAJOR" "$INSTALLER_ERROR"
    fi

    PACKAGE_INFO="$COMPONENT_PACKAGE/PackageInfo"
    SCRIPTS_DIR="$COMPONENT_PACKAGE/Scripts"
    test -f "$PACKAGE_INFO"
    /usr/bin/grep -Fq 'identifier="com.hd838a.RemoteMic.installer"' "$PACKAGE_INFO"
    /usr/bin/grep -Fq '<payload ' "$PACKAGE_INFO"
    /usr/bin/lsbom -s "$COMPONENT_PACKAGE/Bom" > "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Applications/Remote Mic.app/Contents/Info.plist' "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Applications/Remote Mic.app/Contents/MacOS/RemoteMic' "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Library/Application Support/RemoteMic/Installer/MiRemoteV2ch.driver/Contents/Info.plist' "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Library/Application Support/RemoteMic/Installer/MiRemoteV2ch.driver/Contents/MacOS/MiRemoteV2ch' "$PAYLOAD_FILES"
    test -x "$SCRIPTS_DIR/preinstall"
    test -x "$SCRIPTS_DIR/postinstall"
    test -f "$SCRIPTS_DIR/release-variant.plist"
    test "$(/usr/bin/plutil -extract ExpectedArchitecture raw -o - \
      "$SCRIPTS_DIR/release-variant.plist")" = "$RELEASE_ARCH"
    test "$(/usr/bin/plutil -extract MinimumSystemMajor raw -o - \
      "$SCRIPTS_DIR/release-variant.plist")" = "$RELEASE_MIN_SYSTEM_MAJOR"
    test "$(/usr/bin/plutil -extract MinimumSystemVersion raw -o - \
      "$SCRIPTS_DIR/release-variant.plist")" = "$RELEASE_MIN_SYSTEM_VERSION"
    test "$(/usr/bin/plutil -extract PackageBuild raw -o - \
      "$SCRIPTS_DIR/release-variant.plist")" = "$BUILD"
    /usr/bin/grep -Fqx 'DESTINATION="${TARGET_VOLUME%/}/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"' "$SCRIPTS_DIR/preinstall"
    /usr/bin/grep -Fqx 'APP_DESTINATION="${TARGET_VOLUME%/}/Applications/Remote Mic.app"' "$SCRIPTS_DIR/preinstall"
    if /usr/bin/grep -Fq '/bin/rm -rf -- "$APP_DESTINATION"' "$SCRIPTS_DIR/preinstall"; then
      print -u2 "preinstall must not delete an existing Remote Mic.app"
      exit 1
    fi
    /usr/bin/grep -Fq 'will be updated atomically' "$SCRIPTS_DIR/preinstall"
    /usr/bin/grep -Fq 'INSTALLED_BUILD=' "$SCRIPTS_DIR/preinstall"
    /usr/bin/grep -Fq 'The existing app was left intact. Use a newer installer.' \
      "$SCRIPTS_DIR/preinstall"
    /usr/bin/grep -Fq '/bin/rm -rf -- "$LEGACY_APP_DESTINATION"' "$SCRIPTS_DIR/preinstall"
    /usr/bin/grep -Fq 'driver_is_healthy_and_current()' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fq '/usr/bin/file -b "$1"' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fq 'The existing MiRemoteV 2ch is healthy and was kept in place.' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fq '/usr/bin/codesign --verify --deep --strict "$DESTINATION"' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fqx 'APP_DESTINATION="${TARGET_VOLUME%/}/Applications/Remote Mic.app"' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fqx 'LEGACY_APP_DESTINATION="${TARGET_VOLUME%/}/Applications/无线麦.app"' "$SCRIPTS_DIR/postinstall"
    for sparkle_executable in \
      '$SPARKLE_VERSION_DIR/Sparkle' \
      '$SPARKLE_VERSION_DIR/Autoupdate' \
      '$SPARKLE_VERSION_DIR/Updater.app/Contents/MacOS/Updater' \
      '$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc/Contents/MacOS/Installer' \
      '$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc/Contents/MacOS/Downloader'; do
      /usr/bin/grep -Fq "$sparkle_executable" "$SCRIPTS_DIR/postinstall"
    done
    /usr/bin/grep -Fqx 'for app_executable in "${APP_EXECUTABLES[@]}"; do' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fqx '  /bin/chmod 755 "$app_executable"' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fqx '  test -x "$app_executable"' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fqx '/usr/bin/codesign --verify --deep --strict "$APP_DESTINATION"' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fq '/usr/sbin/sysctl -in hw.optional.arm64' "$SCRIPTS_DIR/preinstall"
    /usr/bin/grep -Fq '/usr/sbin/sysctl -in hw.optional.arm64' "$SCRIPTS_DIR/postinstall"
    if /usr/bin/grep -Fq '/usr/bin/uname -m' "$SCRIPTS_DIR/preinstall" "$SCRIPTS_DIR/postinstall"; then
      print -u2 "package scripts must inspect hardware architecture without uname"
      exit 1
    fi
    /usr/bin/grep -Fq 'if [[ "$CURRENT_ARCHITECTURE" != "$EXPECTED_ARCHITECTURE" ]]; then' \
      "$SCRIPTS_DIR/preinstall"
    /usr/bin/grep -Fq 'if [[ "$CURRENT_ARCHITECTURE" != "$EXPECTED_ARCHITECTURE" ]]; then' \
      "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fqx 'if [[ "$DRIVER_CHANGED" -eq 1 ]]; then' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fqx '  /usr/bin/killall coreaudiod' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fq '/bin/launchctl asuser "$CONSOLE_UID"' "$SCRIPTS_DIR/postinstall"
    /usr/bin/grep -Fq '/usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/open "$APP_DESTINATION"' "$SCRIPTS_DIR/postinstall"
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
    test -f "$PACKAGE_INFO"
    /usr/bin/grep -Fq 'identifier="com.hd838a.MiRemoteV2ch.uninstaller"' "$PACKAGE_INFO"
    if /usr/bin/grep -Fq '<payload ' "$PACKAGE_INFO"; then
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

/usr/bin/grep -Fq "version=\"$VERSION\"" "$PACKAGE_INFO"
if [[ -d "$SCRIPTS_DIR" ]] && \
   rg -n --pcre2 \
     '(?<![[:alnum:]_.-])(?:/usr/bin/)?(?:lipo|vtool|xcrun|xcode-select|xcodebuild|swift|swiftc|clang)(?![[:alnum:]_.-])' \
     "$SCRIPTS_DIR"; then
  print -u2 "package scripts must not require Xcode or Command Line Tools"
  exit 1
fi
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
