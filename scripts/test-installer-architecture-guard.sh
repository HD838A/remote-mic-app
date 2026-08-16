#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_SCRIPT="$ROOT/scripts/build-doubao-driver-pkg.sh"
VERIFY_SCRIPT="$ROOT/scripts/verify-doubao-driver-pkg.sh"
PREINSTALL="$ROOT/packaging/doubao-driver/install/preinstall"
POSTINSTALL="$ROOT/packaging/doubao-driver/install/postinstall"
RESOURCES="$ROOT/packaging/doubao-driver/distribution/Resources"
LOCK_TEST_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-installer-signing-lock-test.XXXXXX)"
FAKE_PRODUCTSIGN="$LOCK_TEST_DIR/fake-productsign"
SIGN_LOG="$LOCK_TEST_DIR/sign.log"
SIGN_LOCK="$LOCK_TEST_DIR/installer-signing.lock"

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
/usr/bin/grep -Fq 'UNSIGNED_INSTALL_PACKAGE=' "$BUILD_SCRIPT"
/usr/bin/grep -Fq 'installer-signing-probe-productsign' "$BUILD_SCRIPT"
/usr/bin/grep -Fq 'run_locked_productsign installer-productsign' "$BUILD_SCRIPT"
/usr/bin/grep -Fq '/usr/bin/lockf -k -t "$INSTALLER_SIGNING_LOCK_TIMEOUT_SECONDS"' \
  "$BUILD_SCRIPT"
if /usr/bin/grep -Fq 'INSTALL_COMPONENT_SIGNING_ARGS' "$BUILD_SCRIPT"; then
  print -u2 "component package must remain unsigned inside the final product archive"
  exit 1
fi
/usr/bin/grep -Fq '/usr/sbin/installer -showChoicesXML' "$VERIFY_SCRIPT"
/usr/bin/grep -Fq 'wrong-architecture product package unexpectedly passed Installer evaluation' \
  "$VERIFY_SCRIPT"
/usr/bin/grep -Fq 'Status: no signature' "$VERIFY_SCRIPT"
/usr/bin/grep -Fq 'The deployable outer product archive is the Installer trust boundary.' \
  "$VERIFY_SCRIPT"
/usr/bin/grep -Fq '/usr/sbin/spctl -a -vv -t install "$PACKAGE"' "$VERIFY_SCRIPT"

{
  print '#!/bin/zsh'
  print 'set -euo pipefail'
  print 'lane="$1"'
  print 'print -r -- "start:$lane" >> "$FAKE_SIGN_LOG"'
  print '/bin/sleep 0.3'
  print 'print -r -- "end:$lane" >> "$FAKE_SIGN_LOG"'
} > "$FAKE_PRODUCTSIGN"
/bin/chmod 755 "$FAKE_PRODUCTSIGN"

FAKE_SIGN_LOG="$SIGN_LOG" /usr/bin/lockf -k -t 5 \
  "$SIGN_LOCK" "$FAKE_PRODUCTSIGN" apple-silicon &
apple_sign_pid=$!
FAKE_SIGN_LOG="$SIGN_LOG" /usr/bin/lockf -k -t 5 \
  "$SIGN_LOCK" "$FAKE_PRODUCTSIGN" intel &
intel_sign_pid=$!
wait "$apple_sign_pid"
wait "$intel_sign_pid"

sign_events=("${(@f)$(<"$SIGN_LOG")}")
if (( ${#sign_events[@]} != 4 )); then
  print -u2 "unexpected Installer signing lock event count"
  exit 1
fi
first_lane="${sign_events[1]#start:}"
second_lane="${sign_events[3]#start:}"
test "${sign_events[2]}" = "end:$first_lane"
test "${sign_events[4]}" = "end:$second_lane"
test "$first_lane" != "$second_lane"

print "INSTALLER ARCHITECTURE GUARD TEST PASS"
