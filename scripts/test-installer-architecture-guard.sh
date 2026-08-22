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
COMPONENT_SIGN_MUTATION="$LOCK_TEST_DIR/component-sign-mutation.sh"
PRODUCT_SIGN_MUTATION="$LOCK_TEST_DIR/product-sign-mutation.sh"

extract_stage_block() {
  local script_file="$1"
  local stage_name="$2"
  /usr/bin/awk -v stage_name="$stage_name" '
    $0 ~ ("^run_release_stage " stage_name " ") { capture = 1 }
    capture { print }
    capture && NF == 0 { exit }
  ' "$script_file"
}

assert_unsigned_stage_block() {
  local script_file="$1"
  local stage_name="$2"
  local expected_tool="$3"
  local expected_output="$4"
  local stage_block
  stage_block="$(extract_stage_block "$script_file" "$stage_name")"
  if [[ -z "$stage_block" ]]; then
    print -u2 "missing release stage block: $stage_name"
    return 1
  fi
  if ! print -r -- "$stage_block" | /usr/bin/grep -Fq "$expected_tool"; then
    print -u2 "$stage_name does not call $expected_tool"
    return 1
  fi
  if ! print -r -- "$stage_block" | /usr/bin/grep -Fq "$expected_output"; then
    print -u2 "$stage_name does not write $expected_output"
    return 1
  fi
  if print -r -- "$stage_block" | \
      /usr/bin/grep -Eq '(^|[[:space:]])--sign([[:space:]]|$)'; then
    print -u2 "$stage_name must remain unsigned"
    return 1
  fi
}

mutate_stage_with_sign() {
  local source_script="$1"
  local stage_name="$2"
  local tool_name="$3"
  local destination_script="$4"
  /usr/bin/awk -v stage_name="$stage_name" -v tool_name="$tool_name" '
    $0 ~ ("^run_release_stage " stage_name " ") { capture = 1 }
    {
      print
      if (capture && !mutated && index($0, tool_name) != 0) {
        print "  --sign \"$INSTALLER_SIGNING_IDENTITY\" \\"
        mutated = 1
      }
    }
    END { if (!mutated) exit 1 }
  ' "$source_script" > "$destination_script"
}

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
/usr/bin/grep -Fq 'COMPONENT_PLIST=' "$BUILD_SCRIPT"
/usr/bin/grep -Fq '/usr/bin/pkgbuild' "$BUILD_SCRIPT"
/usr/bin/grep -Fq -- '--analyze' "$BUILD_SCRIPT"
/usr/bin/grep -Fq 'BundleIsRelocatable false' "$BUILD_SCRIPT"
/usr/bin/grep -Fq 'Applications/SayAll.app' "$BUILD_SCRIPT"
/usr/bin/grep -Fq 'UNSIGNED_INSTALL_PACKAGE=' "$BUILD_SCRIPT"
/usr/bin/grep -Fq 'installer-signing-probe-productsign' "$BUILD_SCRIPT"
/usr/bin/grep -Fq 'run_locked_productsign installer-productsign' "$BUILD_SCRIPT"
/usr/bin/grep -Fq '/usr/bin/lockf -k -t "$INSTALLER_SIGNING_LOCK_TIMEOUT_SECONDS"' \
  "$BUILD_SCRIPT"
if /usr/bin/grep -Fq 'INSTALL_COMPONENT_SIGNING_ARGS' "$BUILD_SCRIPT"; then
  print -u2 "component package must remain unsigned inside the final product archive"
  exit 1
fi
assert_unsigned_stage_block \
  "$BUILD_SCRIPT" installer-component-pkgbuild /usr/bin/pkgbuild \
  '"$INSTALL_COMPONENT_PACKAGE"'
assert_unsigned_stage_block \
  "$BUILD_SCRIPT" installer-productbuild /usr/bin/productbuild \
  '"$UNSIGNED_INSTALL_PACKAGE"'

mutate_stage_with_sign \
  "$BUILD_SCRIPT" installer-component-pkgbuild /usr/bin/pkgbuild \
  "$COMPONENT_SIGN_MUTATION"
/bin/zsh -n "$COMPONENT_SIGN_MUTATION"
if assert_unsigned_stage_block \
    "$COMPONENT_SIGN_MUTATION" installer-component-pkgbuild /usr/bin/pkgbuild \
    '"$INSTALL_COMPONENT_PACKAGE"' \
    > "$LOCK_TEST_DIR/component-sign-mutation.log" 2>&1; then
  print -u2 "component package mutation unexpectedly accepted --sign"
  exit 1
fi
/usr/bin/grep -Fq 'installer-component-pkgbuild must remain unsigned' \
  "$LOCK_TEST_DIR/component-sign-mutation.log"

mutate_stage_with_sign \
  "$BUILD_SCRIPT" installer-productbuild /usr/bin/productbuild \
  "$PRODUCT_SIGN_MUTATION"
/bin/zsh -n "$PRODUCT_SIGN_MUTATION"
if assert_unsigned_stage_block \
    "$PRODUCT_SIGN_MUTATION" installer-productbuild /usr/bin/productbuild \
    '"$UNSIGNED_INSTALL_PACKAGE"' \
    > "$LOCK_TEST_DIR/product-sign-mutation.log" 2>&1; then
  print -u2 "Distribution product mutation unexpectedly accepted --sign"
  exit 1
fi
/usr/bin/grep -Fq 'installer-productbuild must remain unsigned' \
  "$LOCK_TEST_DIR/product-sign-mutation.log"
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
: > "$SIGN_LOG"

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
