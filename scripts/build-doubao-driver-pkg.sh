#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
OUTPUT_DIR="$RELEASE_OUTPUT_DIR"
DRIVER="$OUTPUT_DIR/MiRemoteV2ch.driver"
APP="$OUTPUT_DIR/SayAll.app"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
INSTALL_PACKAGE="$OUTPUT_DIR/$RELEASE_INSTALL_PACKAGE_NAME"
LEGACY_INSTALL_PACKAGE="$OUTPUT_DIR/安装豆包兼容麦克风.pkg"
UNINSTALL_PACKAGE="$OUTPUT_DIR/$RELEASE_UNINSTALL_PACKAGE_NAME"
LEGACY_UNINSTALL_PACKAGE="$OUTPUT_DIR/卸载豆包兼容麦克风.pkg"
INSTALLER_SIGNING_IDENTITY="${INSTALLER_SIGNING_IDENTITY:--}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"
RELEASE_STAGE_TIMEOUTS="${RELEASE_STAGE_TIMEOUTS:-0}"
RELEASE_PKGBUILD_TIMEOUT_SECONDS="${RELEASE_PKGBUILD_TIMEOUT_SECONDS:-90}"
RELEASE_PRODUCTBUILD_TIMEOUT_SECONDS="${RELEASE_PRODUCTBUILD_TIMEOUT_SECONDS:-90}"
RELEASE_PRODUCTSIGN_TIMEOUT_SECONDS="${RELEASE_PRODUCTSIGN_TIMEOUT_SECONDS:-45}"
INSTALLER_SIGNING_LOCK_TIMEOUT_SECONDS="${INSTALLER_SIGNING_LOCK_TIMEOUT_SECONDS:-30}"
INSTALLER_SIGNING_LOCK_PATH="${INSTALLER_SIGNING_LOCK_PATH:-/private/tmp/remote-mic-installer-signing.lock}"
RELEASE_STAGE_RUNNER="$ROOT/scripts/run-release-stage.sh"
WORK_DIR="$(/usr/bin/mktemp -d "$OUTPUT_DIR/.doubao-driver-package.XXXXXX")"
PAYLOAD_ROOT="$WORK_DIR/payload"
INSTALL_SCRIPTS="$WORK_DIR/install-scripts"
UNINSTALL_SCRIPTS="$WORK_DIR/uninstall-scripts"
COMPONENT_PLIST="$WORK_DIR/components.plist"
INSTALL_COMPONENT_PACKAGE="$WORK_DIR/RemoteMicComponent.pkg"
UNSIGNED_INSTALL_PACKAGE="$WORK_DIR/Install Remote Mic-unsigned.pkg"
UNSIGNED_UNINSTALL_PACKAGE="$WORK_DIR/Uninstall Remote Mic-unsigned.pkg"
SIGNING_PROBE_UNSIGNED_PACKAGE="$WORK_DIR/Installer Signing Probe-unsigned.pkg"
SIGNING_PROBE_PACKAGE="$WORK_DIR/Installer Signing Probe.pkg"
DISTRIBUTION="$ROOT/packaging/doubao-driver/distribution/$RELEASE_VARIANT.xml"
DISTRIBUTION_RESOURCES="$ROOT/packaging/doubao-driver/distribution/Resources"

cleanup() {
  local user_home trash_directory trash_destination
  case "$WORK_DIR" in
    "$OUTPUT_DIR/.doubao-driver-package."*)
      user_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
      trash_directory="$user_home/.Trash"
      trash_destination="$trash_directory/${WORK_DIR:t}.package-build.$(date -u +%Y%m%dT%H%M%SZ).$$"
      if [[ -d "$trash_directory" && ! -e "$trash_destination" ]] && \
          /bin/mv -n -- "$WORK_DIR" "$trash_destination"; then
        print "PACKAGE WORKSPACE MOVED TO TRASH: $trash_destination"
      else
        print -u2 "PACKAGE WORKSPACE PRESERVED: $WORK_DIR"
      fi
      ;;
    *) print -u2 "refusing to clean unexpected work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

test -x /usr/bin/pkgbuild
test -x /usr/bin/productbuild
test -f "$DISTRIBUTION"
test -d "$DISTRIBUTION_RESOURCES/en.lproj"
test -d "$DISTRIBUTION_RESOURCES/zh-Hans.lproj"
case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
case "$RELEASE_STAGE_TIMEOUTS" in
  0|1) ;;
  *) print -u2 "RELEASE_STAGE_TIMEOUTS must be 0 or 1"; exit 1 ;;
esac
if [[ "$RELEASE_STAGE_TIMEOUTS" == "1" && ! -x "$RELEASE_STAGE_RUNNER" ]]; then
  print -u2 "release stage runner is unavailable"
  exit 1
fi
if ! print -r -- "$INSTALLER_SIGNING_LOCK_TIMEOUT_SECONDS" | \
    /usr/bin/grep -Eq '^[1-9][0-9]*$'; then
  print -u2 "INSTALLER_SIGNING_LOCK_TIMEOUT_SECONDS must be a positive integer"
  exit 1
fi
if (( INSTALLER_SIGNING_LOCK_TIMEOUT_SECONDS >= RELEASE_PRODUCTSIGN_TIMEOUT_SECONDS )); then
  print -u2 "Installer signing lock timeout must be shorter than the productsign stage timeout"
  exit 1
fi
case "$INSTALLER_SIGNING_LOCK_PATH" in
  /private/tmp/*.lock) ;;
  *) print -u2 "INSTALLER_SIGNING_LOCK_PATH must be an explicit lock file under /private/tmp"; exit 1 ;;
esac

run_release_stage() {
  local stage="$1"
  local timeout_seconds="$2"
  shift 2
  if [[ "$RELEASE_STAGE_TIMEOUTS" == "1" ]]; then
    "$RELEASE_STAGE_RUNNER" "$RELEASE_VARIANT" "$stage" "$timeout_seconds" -- "$@"
  else
    "$@"
  fi
}

run_locked_productsign() {
  local stage="$1"
  local input_package="$2"
  local output_package="$3"
  run_release_stage "$stage" "$RELEASE_PRODUCTSIGN_TIMEOUT_SECONDS" \
    /usr/bin/lockf -k -t "$INSTALLER_SIGNING_LOCK_TIMEOUT_SECONDS" \
    "$INSTALLER_SIGNING_LOCK_PATH" \
    /usr/bin/productsign --sign "$INSTALLER_SIGNING_IDENTITY" \
    "$input_package" "$output_package"
}
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && "$INSTALLER_SIGNING_IDENTITY" == "-" ]]; then
  print -u2 "Developer ID Installer signing is required"
  exit 1
fi
"$ROOT/scripts/verify-doubao-driver.sh" "$DRIVER"
"$ROOT/scripts/verify-app.sh" "$APP"

move_existing_package_to_trash() {
  local package="$1"
  local user_home trash_directory trash_destination counter=0
  [[ -e "$package" || -L "$package" ]] || return 0
  user_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
  trash_directory="$user_home/.Trash"
  test -d "$trash_directory"
  trash_destination="$trash_directory/${package:t}.package-build.$(date -u +%Y%m%dT%H%M%SZ).$$"
  while [[ -e "$trash_destination" || -L "$trash_destination" ]]; do
    counter=$((counter + 1))
    trash_destination="$trash_directory/${package:t}.package-build.$(date -u +%Y%m%dT%H%M%SZ).$$.$counter"
  done
  /bin/mv -n -- "$package" "$trash_destination"
  print "PREVIOUS PACKAGE MOVED TO TRASH: $trash_destination"
}

for existing_package in \
  "$INSTALL_PACKAGE" \
  "$LEGACY_INSTALL_PACKAGE" \
  "$UNINSTALL_PACKAGE" \
  "$LEGACY_UNINSTALL_PACKAGE"; do
  move_existing_package_to_trash "$existing_package"
done
/bin/mkdir -p \
  "$PAYLOAD_ROOT/Applications" \
  "$PAYLOAD_ROOT/Library/Application Support/RemoteMic/Installer"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$APP" "$PAYLOAD_ROOT/Applications/SayAll.app"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$DRIVER" \
  "$PAYLOAD_ROOT/Library/Application Support/RemoteMic/Installer/MiRemoteV2ch.driver"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/packaging/doubao-driver/install" "$INSTALL_SCRIPTS"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$RELEASE_CONFIG_PLIST" "$INSTALL_SCRIPTS/release-variant.plist"
/usr/bin/plutil -replace PackageBuild -string "$BUILD" \
  "$INSTALL_SCRIPTS/release-variant.plist"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/packaging/doubao-driver/uninstall" "$UNINSTALL_SCRIPTS"

run_release_stage installer-component-analysis "$RELEASE_PKGBUILD_TIMEOUT_SECONDS" \
  /usr/bin/pkgbuild \
  --analyze \
  --root "$PAYLOAD_ROOT" \
  "$COMPONENT_PLIST"

APP_COMPONENT_INDEX=-1
component_index=0
while true; do
  bundle_path="$(/usr/libexec/PlistBuddy \
    -c "Print :$component_index:RootRelativeBundlePath" \
    "$COMPONENT_PLIST" 2>/dev/null || true)"
  [[ -z "$bundle_path" ]] && break
  if [[ "$bundle_path" == "Applications/SayAll.app" ]]; then
    /usr/libexec/PlistBuddy \
      -c "Set :$component_index:BundleIsRelocatable false" \
      "$COMPONENT_PLIST"
    APP_COMPONENT_INDEX="$component_index"
    break
  fi
  component_index=$((component_index + 1))
done
if [[ "$APP_COMPONENT_INDEX" -lt 0 ]]; then
  print -u2 "unable to identify the SayAll.app component in the generated plist"
  exit 1
fi

run_release_stage installer-component-pkgbuild "$RELEASE_PKGBUILD_TIMEOUT_SECONDS" \
  /usr/bin/pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --scripts "$INSTALL_SCRIPTS" \
  --component-plist "$COMPONENT_PLIST" \
  --identifier "com.hd838a.RemoteMic.installer" \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  "$INSTALL_COMPONENT_PACKAGE"

run_release_stage installer-productbuild "$RELEASE_PRODUCTBUILD_TIMEOUT_SECONDS" \
  /usr/bin/productbuild \
  --distribution "$DISTRIBUTION" \
  --resources "$DISTRIBUTION_RESOURCES" \
  --package-path "$WORK_DIR" \
  "$UNSIGNED_INSTALL_PACKAGE"

run_release_stage uninstaller-pkgbuild "$RELEASE_PKGBUILD_TIMEOUT_SECONDS" \
  /usr/bin/pkgbuild \
  --nopayload \
  --scripts "$UNINSTALL_SCRIPTS" \
  --identifier "com.hd838a.MiRemoteV2ch.uninstaller" \
  --version "$VERSION" \
  "$UNSIGNED_UNINSTALL_PACKAGE"

if [[ "$INSTALLER_SIGNING_IDENTITY" != "-" ]]; then
  test -x /usr/bin/lockf
  test -x /usr/bin/productsign
  run_release_stage installer-signing-probe-pkgbuild 30 \
    /usr/bin/pkgbuild \
    --nopayload \
    --identifier "com.hd838a.RemoteMic.installer-signing-probe" \
    --version "$VERSION" \
    "$SIGNING_PROBE_UNSIGNED_PACKAGE"
  run_locked_productsign installer-signing-probe-productsign \
    "$SIGNING_PROBE_UNSIGNED_PACKAGE" "$SIGNING_PROBE_PACKAGE"
  PROBE_SIGNATURE_DETAILS="$(/usr/sbin/pkgutil --check-signature \
    "$SIGNING_PROBE_PACKAGE" 2>&1)"
  print -r -- "$PROBE_SIGNATURE_DETAILS" | \
    rg -q 'Status: signed by a developer certificate issued by Apple for distribution'
  run_locked_productsign installer-productsign \
    "$UNSIGNED_INSTALL_PACKAGE" "$INSTALL_PACKAGE"
  run_locked_productsign uninstaller-productsign \
    "$UNSIGNED_UNINSTALL_PACKAGE" "$UNINSTALL_PACKAGE"
else
  /bin/mv "$UNSIGNED_INSTALL_PACKAGE" "$INSTALL_PACKAGE"
  /bin/mv "$UNSIGNED_UNINSTALL_PACKAGE" "$UNINSTALL_PACKAGE"
fi

"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install
"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall

print "Built: $INSTALL_PACKAGE"
print "Built: $UNINSTALL_PACKAGE"
print "RELEASE VARIANT: $RELEASE_VARIANT"
print "INSTALLER SIGNING IDENTITY: $INSTALLER_SIGNING_IDENTITY"
print "APP VERSION: $VERSION ($BUILD)"
