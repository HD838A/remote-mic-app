#!/bin/zsh
set -euo pipefail
umask 077

# Regression tests for the private Draft asset staging contract.
#
# The staging step exists because two release mistakes were invisible until
# after the upload: an asset name with whitespace was rewritten by gh into a
# name without build number or architecture, and a second architecture's
# installer was silently left out of the published set.

SCRIPT_ROOT="${0:A:h:h}"
PREPARE="$SCRIPT_ROOT/scripts/prepare-private-draft-assets.sh"
REPO_ROOT="${REPOSITORY_ROOT:-$SCRIPT_ROOT}"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/sayall-private-draft-assets-test.XXXXXX)"

cleanup() {
  local trash_root="$HOME/.Trash"
  local trash_target="$trash_root/sayall-private-draft-assets-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$trash_root"
  [[ -d "$WORK_DIR" ]] && /bin/mv "$WORK_DIR" "$trash_target"
}
trap cleanup EXIT

fail() {
  print -u2 "private draft asset staging test failed: $1"
  exit 1
}

expect_failure() {
  local expected_message="$1"
  shift
  local output_file="$WORK_DIR/failure-$RANDOM.log"
  if "$@" >"$output_file" 2>&1; then
    fail "expected failure but the command succeeded: $expected_message"
  fi
  /usr/bin/grep -Fq -- "$expected_message" "$output_file" || {
    /bin/cat "$output_file" >&2
    fail "failure did not contain the expected message: $expected_message"
  }
}

version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$REPO_ROOT/Resources/Info.plist")"
build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$REPO_ROOT/Resources/Info.plist")"

make_variant() {
  local directory="$1"
  /bin/mkdir -p "$directory"
  print "dmg fixture" > "$directory/SayAll-$version-$build.dmg"
  print "installer fixture" > "$directory/Install SayAll.pkg"
  print "uninstaller fixture" > "$directory/Uninstall SayAll.pkg"
}

apple_silicon="$WORK_DIR/apple-silicon"
intel="$WORK_DIR/intel"
make_variant "$apple_silicon"
make_variant "$intel"

# 1. Both variants with the same asset kinds stage under canonical names.
staging="$WORK_DIR/staged"
REPOSITORY_ROOT="$REPO_ROOT" "$PREPARE" "$staging" \
  "AppleSilicon=$apple_silicon" "Intel=$intel" > "$WORK_DIR/staged.log" || fail "staging a complete asset set failed"
[[ -f "$staging/SayAll-$version-$build-AppleSilicon.dmg" ]] || fail "Apple Silicon DMG is missing"
[[ -f "$staging/SayAll-$version-$build-Intel.dmg" ]] || fail "Intel DMG is missing"
[[ -f "$staging/SayAll-$version-$build-AppleSilicon-Installer.pkg" ]] || fail "Apple Silicon installer is missing"
[[ -f "$staging/SayAll-$version-$build-Intel-Installer.pkg" ]] || fail "Intel installer is missing"
[[ ! -e "$staging/SayAll-$version-$build-AppleSilicon-Uninstaller.pkg" ]] || fail "uninstaller must not be staged"
/usr/bin/jq -e --arg version "$version" --arg build "$build" \
  '.version == $version and .build == $build' \
  "$staging/staged-assets.json" >/dev/null || fail "staged manifest does not carry the release version and build"
/usr/bin/jq -e --arg version "$version" --arg build "$build" \
  '.assets | length == 4 and all(.name | test("^SayAll-'"$version"'-'"$build"'-(AppleSilicon|Intel)"))' \
  "$staging/staged-assets.json" >/dev/null || fail "staged manifest does not match the naming contract"

# 2. A variant that misses one asset kind must fail before anything is staged.
incomplete="$WORK_DIR/incomplete-intel"
/bin/mkdir -p "$incomplete"
print "dmg fixture" > "$incomplete/SayAll-$version-$build-Intel.dmg"
expect_failure "every variant must cover the same asset kinds" \
  env REPOSITORY_ROOT="$REPO_ROOT" "$PREPARE" "$WORK_DIR/staged-incomplete" \
  "AppleSilicon=$apple_silicon" "Intel=$incomplete"
[[ ! -e "$WORK_DIR/staged-incomplete" ]] || fail "a rejected asset set must not leave a staging directory"

# 3. A variant without any macOS distribution asset must fail.
empty_variant="$WORK_DIR/empty-variant"
/bin/mkdir -p "$empty_variant"
expect_failure "no macOS distribution asset was found" \
  env REPOSITORY_ROOT="$REPO_ROOT" "$PREPARE" "$WORK_DIR/staged-empty" \
  "AppleSilicon=$apple_silicon" "Intel=$empty_variant"

# 4. An existing staging directory must not be overwritten.
expect_failure "staging directory already exists" \
  env REPOSITORY_ROOT="$REPO_ROOT" "$PREPARE" "$staging" \
  "AppleSilicon=$apple_silicon" "Intel=$intel"

print "private draft asset staging tests passed"
