#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_SCRIPT="$ROOT/scripts/build-doubao-driver-pkg.sh"
VERIFY_SCRIPT="$ROOT/scripts/verify-doubao-driver-pkg.sh"
PREINSTALL="$ROOT/packaging/doubao-driver/install/preinstall"
POSTINSTALL="$ROOT/packaging/doubao-driver/install/postinstall"
RESOURCES="$ROOT/packaging/doubao-driver/distribution/Resources"

for distribution in \
  "$ROOT/packaging/doubao-driver/distribution/apple-silicon.xml" \
  "$ROOT/packaging/doubao-driver/distribution/intel.xml"; do
  /usr/bin/xmllint --noout "$distribution"
  /usr/bin/grep -Fq 'hostArchitectures="arm64,x86_64"' "$distribution"
  /usr/bin/grep -Fq "system.sysctl('hw.optional.arm64')" "$distribution"
  /usr/bin/grep -Fq "my.result.type = 'Fatal'" "$distribution"
  /usr/bin/grep -Fq 'my.result.message = system.localizedString' "$distribution"
  /usr/bin/grep -Fq '<installation-check script="installationCheck()"/>' "$distribution"
  /usr/bin/grep -Fq '>RemoteMicComponent.pkg</pkg-ref>' "$distribution"
done

for strings_file in "$RESOURCES"/*.lproj/Localizable.strings; do
  /usr/bin/plutil -lint "$strings_file"
  /usr/bin/grep -Fq 'wrong_architecture_apple_silicon' "$strings_file"
  /usr/bin/grep -Fq 'wrong_architecture_intel' "$strings_file"
  /usr/bin/grep -Fq 'unsupported_system_apple_silicon' "$strings_file"
  /usr/bin/grep -Fq 'unsupported_system_intel' "$strings_file"
  /usr/bin/grep -Fq 'Intel' "$strings_file"
  /usr/bin/grep -Fq 'Apple Silicon' "$strings_file"
done

for package_script in "$PREINSTALL" "$POSTINSTALL"; do
  /bin/zsh -n "$package_script"
  /usr/bin/grep -Fq '/usr/sbin/sysctl -in hw.optional.arm64' "$package_script"
  if /usr/bin/grep -Fq '/usr/bin/uname -m' "$package_script"; then
    print -u2 "installer script still relies on uname: $package_script"
    exit 1
  fi
done

/usr/bin/grep -Fq '/usr/bin/productbuild' "$BUILD_SCRIPT"
/usr/bin/grep -Fq 'INSTALL_COMPONENT_SIGNING_ARGS=(--sign "$INSTALLER_SIGNING_IDENTITY")' "$BUILD_SCRIPT"
/usr/bin/grep -Fq 'INSTALL_PRODUCT_SIGNING_ARGS=(--sign "$INSTALLER_SIGNING_IDENTITY")' "$BUILD_SCRIPT"
/usr/bin/grep -Fq '/usr/sbin/installer -showChoicesXML' "$VERIFY_SCRIPT"
/usr/bin/grep -Fq 'wrong-architecture product package unexpectedly passed Installer evaluation' \
  "$VERIFY_SCRIPT"

print "INSTALLER ARCHITECTURE GUARD TEST PASS"
