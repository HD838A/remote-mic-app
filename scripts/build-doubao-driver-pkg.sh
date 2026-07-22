#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
DRIVER="$OUTPUT_DIR/MiRemoteV2ch.driver"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
INSTALL_PACKAGE="$OUTPUT_DIR/安装豆包兼容麦克风.pkg"
UNINSTALL_PACKAGE="$OUTPUT_DIR/卸载豆包兼容麦克风.pkg"
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
"$ROOT/scripts/verify-doubao-driver.sh" "$DRIVER"

/bin/rm -f -- "$INSTALL_PACKAGE" "$UNINSTALL_PACKAGE"
/bin/mkdir -p "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$DRIVER" "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/packaging/doubao-driver/install" "$INSTALL_SCRIPTS"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/packaging/doubao-driver/uninstall" "$UNINSTALL_SCRIPTS"

/usr/bin/pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --scripts "$INSTALL_SCRIPTS" \
  --identifier "com.hd838a.MiRemoteV2ch.installer" \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  "$INSTALL_PACKAGE"

/usr/bin/pkgbuild \
  --nopayload \
  --scripts "$UNINSTALL_SCRIPTS" \
  --identifier "com.hd838a.MiRemoteV2ch.uninstaller" \
  --version "$VERSION" \
  "$UNINSTALL_PACKAGE"

"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install
"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall

print "Built: $INSTALL_PACKAGE"
print "Built: $UNINSTALL_PACKAGE"
