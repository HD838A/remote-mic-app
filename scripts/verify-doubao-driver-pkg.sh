#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PACKAGE="${1:?usage: verify-doubao-driver-pkg.sh PACKAGE install|uninstall}"
MODE="${2:?usage: verify-doubao-driver-pkg.sh PACKAGE install|uninstall}"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/xrbm-driver-package-verify.XXXXXX)"
EXPANDED="$WORK_DIR/expanded"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/xrbm-driver-package-verify.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected verification path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

test -f "$PACKAGE"
/usr/sbin/pkgutil --expand "$PACKAGE" "$EXPANDED"
test -f "$EXPANDED/PackageInfo"

case "$MODE" in
  install)
    /usr/bin/grep -Fq 'identifier="com.hd838a.MiRemoteV2ch.installer"' "$EXPANDED/PackageInfo"
    /usr/bin/grep -Fq '<payload ' "$EXPANDED/PackageInfo"
    /usr/sbin/pkgutil --payload-files "$PACKAGE" | /usr/bin/grep -qx './Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver/Contents/Info.plist'
    /usr/sbin/pkgutil --payload-files "$PACKAGE" | /usr/bin/grep -qx './Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver/Contents/MacOS/MiRemoteV2ch'
    test -x "$EXPANDED/Scripts/preinstall"
    test -x "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx 'DESTINATION="${TARGET_VOLUME%/}/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"' "$EXPANDED/Scripts/preinstall"
    /usr/bin/grep -Fqx '/usr/bin/codesign --verify --deep --strict "$DESTINATION"' "$EXPANDED/Scripts/postinstall"
    /usr/bin/grep -Fqx '/usr/bin/killall coreaudiod' "$EXPANDED/Scripts/postinstall"
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
