#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
DRIVER="$OUTPUT_DIR/MiRemoteV2ch.driver"
APP="$OUTPUT_DIR/Remote Mic.app"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
INSTALL_PACKAGE="$OUTPUT_DIR/Install Remote Mic.pkg"
LEGACY_INSTALL_PACKAGE="$OUTPUT_DIR/安装豆包兼容麦克风.pkg"
UNINSTALL_PACKAGE="$OUTPUT_DIR/Uninstall Remote Mic.pkg"
LEGACY_UNINSTALL_PACKAGE="$OUTPUT_DIR/卸载豆包兼容麦克风.pkg"
INSTALLER_SIGNING_IDENTITY="${INSTALLER_SIGNING_IDENTITY:--}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"
WORK_DIR="$(/usr/bin/mktemp -d "$OUTPUT_DIR/.doubao-driver-package.XXXXXX")"
PAYLOAD_ROOT="$WORK_DIR/payload"
INSTALL_SCRIPTS="$WORK_DIR/install-scripts"
UNINSTALL_SCRIPTS="$WORK_DIR/uninstall-scripts"

cleanup() {
  case "$WORK_DIR" in
    "$OUTPUT_DIR/.doubao-driver-package."*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

test -x /usr/bin/pkgbuild
case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && "$INSTALLER_SIGNING_IDENTITY" == "-" ]]; then
  print -u2 "Developer ID Installer signing is required"
  exit 1
fi
"$ROOT/scripts/verify-doubao-driver.sh" "$DRIVER"
"$ROOT/scripts/verify-app.sh" "$APP"

/bin/rm -f -- \
  "$INSTALL_PACKAGE" \
  "$LEGACY_INSTALL_PACKAGE" \
  "$UNINSTALL_PACKAGE" \
  "$LEGACY_UNINSTALL_PACKAGE"
/bin/mkdir -p "$PAYLOAD_ROOT/Applications" "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$APP" "$PAYLOAD_ROOT/Applications/Remote Mic.app"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$DRIVER" "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/packaging/doubao-driver/install" "$INSTALL_SCRIPTS"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/packaging/doubao-driver/uninstall" "$UNINSTALL_SCRIPTS"

PACKAGE_SIGNING_OPTIONS=()
if [[ "$INSTALLER_SIGNING_IDENTITY" != "-" ]]; then
  PACKAGE_SIGNING_OPTIONS=(--sign "$INSTALLER_SIGNING_IDENTITY")
fi

/usr/bin/pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --scripts "$INSTALL_SCRIPTS" \
  --identifier "com.hd838a.RemoteMic.installer" \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  "${PACKAGE_SIGNING_OPTIONS[@]}" \
  "$INSTALL_PACKAGE"

/usr/bin/pkgbuild \
  --nopayload \
  --scripts "$UNINSTALL_SCRIPTS" \
  --identifier "com.hd838a.MiRemoteV2ch.uninstaller" \
  --version "$VERSION" \
  "${PACKAGE_SIGNING_OPTIONS[@]}" \
  "$UNINSTALL_PACKAGE"

"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install
"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall

print "Built: $INSTALL_PACKAGE"
print "Built: $UNINSTALL_PACKAGE"
print "INSTALLER SIGNING IDENTITY: $INSTALLER_SIGNING_IDENTITY"
