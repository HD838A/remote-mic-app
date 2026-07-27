#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PACKAGE="${1:?usage: verify-doubao-driver-pkg.sh PACKAGE install|uninstall}"
MODE="${2:?usage: verify-doubao-driver-pkg.sh PACKAGE install|uninstall}"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remote-mic-driver-package-verify.XXXXXX)"
EXPANDED="$WORK_DIR/expanded"
PAYLOAD_FILES="$WORK_DIR/payload-files"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remote-mic-driver-package-verify.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected verification path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

test -f "$PACKAGE"
/usr/sbin/pkgutil --expand "$PACKAGE" "$EXPANDED"
test -f "$EXPANDED/PackageInfo"

case "$MODE" in
  install)
    /usr/bin/grep -Fq 'identifier="com.hd838a.RemoteMic.installer"' "$EXPANDED/PackageInfo"
    /usr/bin/grep -Fq '<payload ' "$EXPANDED/PackageInfo"
    /usr/sbin/pkgutil --payload-files "$PACKAGE" > "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Applications/无线麦.app/Contents/Info.plist' "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Applications/无线麦.app/Contents/MacOS/RemoteMic' "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver/Contents/Info.plist' "$PAYLOAD_FILES"
    /usr/bin/grep -qx './Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver/Contents/MacOS/MiRemoteV2ch' "$PAYLOAD_FILES"
    test -x "$EXPANDED/Scripts/preinstall"
    test -x "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx 'DESTINATION="${TARGET_VOLUME%/}/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"' "$EXPANDED/Scripts/preinstall"
    /usr/bin/grep -Fqx '/usr/bin/codesign --verify --deep --strict "$DESTINATION"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx '/usr/bin/codesign --verify --deep --strict "$APP_DESTINATION"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx 'test "$(/usr/bin/uname -m)" = "arm64"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx 'test "$DRIVER_ARCHS" = "arm64"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx 'test "$APP_ARCHS" = "arm64"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx "/usr/bin/vtool -show-build \"\$BINARY\" | /usr/bin/grep -q 'minos 26\\.0'" "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx "/usr/bin/vtool -show-build \"\$APP_BINARY\" | /usr/bin/grep -q 'minos 26\\.0'" "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx '/usr/bin/killall coreaudiod' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fq '/bin/launchctl asuser "$CONSOLE_UID"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fq '/usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/open "$APP_DESTINATION"' "$EXPANDED/Scripts/postinstall"
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
print "DOUBAO DRIVER PACKAGE VERIFY PASS: $PACKAGE ($MODE)"
