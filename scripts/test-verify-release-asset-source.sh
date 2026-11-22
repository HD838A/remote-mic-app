#!/bin/zsh
set -euo pipefail
umask 077

# Regression tests for the release asset source check.
#
# The check exists because build 284 was published from a worktree that did not
# contain the release commit, and nothing looked inside the artifact. These
# fixtures cover app, zip, dmg and pkg containers plus the two failure shapes
# (wrong commit, missing field).

SCRIPT_ROOT="${0:A:h:h}"
VERIFY="$SCRIPT_ROOT/scripts/verify-release-asset-source.sh"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/sayall-asset-source-test.XXXXXX)"

cleanup() {
  local trash_root="$HOME/.Trash"
  local trash_target="$trash_root/sayall-asset-source-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$trash_root"
  [[ -d "$WORK_DIR" ]] && /bin/mv "$WORK_DIR" "$trash_target"
}
trap cleanup EXIT INT TERM

EXPECTED="1111111111111111111111111111111111111111"
OTHER="2222222222222222222222222222222222222222"
passed=0
last_output=""

fail() {
  print -u2 "release asset source test failed: $1"
  exit 1
}

make_app() {
  local root="$1" name="$2" commit="$3" include_commit="$4"
  local app="$root/$name.app"
  /bin/mkdir -p "$app/Contents/MacOS"
  print '#!/bin/zsh' > "$app/Contents/MacOS/SayAll"
  /bin/chmod +x "$app/Contents/MacOS/SayAll"
  if [[ "$include_commit" == "yes" ]]; then
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>SayAllSourceCommit</key>
  <string>$commit</string>
</dict>
</plist>
PLIST
  else
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.legacy</string>
</dict>
</plist>
PLIST
  fi
  print -r -- "$app"
}

expect_ok() {
  local description="$1"
  shift
  local exit_code=0
  last_output="$("$VERIFY" "$@" 2>&1)" || exit_code=$?
  (( exit_code == 0 )) || fail "$description: expected pass, exit=$exit_code output=$last_output"
  (( passed += 1 ))
  print "PASS $description"
}

expect_fail() {
  local description="$1" expected_message="$2"
  shift 2
  local exit_code=0
  last_output="$("$VERIFY" "$@" 2>&1)" || exit_code=$?
  (( exit_code != 0 )) || fail "$description: expected failure but the check passed"
  [[ "$last_output" == *"$expected_message"* ]] || \
    fail "$description: failure message missing [$expected_message]: $last_output"
  (( passed += 1 ))
  print "PASS $description"
}

[[ -x "$VERIFY" ]] || fail "verify-release-asset-source.sh is not executable"

# --- 1) 裸 App ------------------------------------------------------------------
good_app="$(make_app "$WORK_DIR/good" "SayAll" "$EXPECTED" yes)"
expect_ok "app with the expected commit passes" --asset "$good_app" --expected-commit "$EXPECTED"

wrong_app="$(make_app "$WORK_DIR/wrong" "SayAll" "$OTHER" yes)"
expect_fail "app from another commit is rejected" "reports source commit $OTHER, expected $EXPECTED" \
  --asset "$wrong_app" --expected-commit "$EXPECTED"

legacy_app="$(make_app "$WORK_DIR/legacy" "SayAll" "" no)"
expect_fail "app without the field is rejected" "has no SayAllSourceCommit" \
  --asset "$legacy_app" --expected-commit "$EXPECTED"

# --- 2) ZIP ---------------------------------------------------------------------
good_zip="$WORK_DIR/SayAll.zip"
/usr/bin/ditto -c -k --keepParent "$good_app" "$good_zip"
expect_ok "zip is opened and checked" --asset "$good_zip" --expected-commit "$EXPECTED"

# --- 3) DMG ---------------------------------------------------------------------
# hdiutil can transiently fail on shared runners. Retry only the local fixture
# creation and mount; a real source-commit mismatch still fails closed.
dmg_passed=false
for attempt in 1 2 3; do
  good_dmg="$WORK_DIR/SayAll-$attempt-$RANDOM.dmg"
  volname="SayAllSourceTest-$attempt-$-$RANDOM"
  if ! hdiutil create -quiet -srcfolder "$good_app" -volname "$volname" -format UDZO "$good_dmg" \
      > "$WORK_DIR/dmg-create-$attempt.log" 2>&1; then
    print -u2 "dmg create attempt $attempt failed: $(tail -1 "$WORK_DIR/dmg-create-$attempt.log")"
    sleep 1
    continue
  fi
  if output="$("$VERIFY" --asset "$good_dmg" --expected-commit "$EXPECTED" 2>&1)"; then
    (( passed += 1 ))
    print "PASS dmg is mounted and checked (attempt $attempt)"
    dmg_passed=true
    break
  fi
  print -u2 "dmg verify attempt $attempt failed: $output"
  if [[ -d "/Volumes/$volname" ]]; then
    hdiutil detach "/Volumes/$volname" -force >/dev/null 2>&1 || true
  fi
  sleep 1
done
$dmg_passed || fail "dmg is mounted and checked after 3 attempts"

# --- 4) PKG ---------------------------------------------------------------------
good_pkg="$WORK_DIR/SayAll.pkg"
pkg_root="$WORK_DIR/pkgroot"
/bin/mkdir -p "$pkg_root"
/bin/cp -R "$good_app" "$pkg_root/"
pkgbuild --quiet --ownership preserve --root "$pkg_root" \
  --identifier com.example.sayall.source-test --version 1.0 "$good_pkg"
expect_ok "pkg is expanded and checked" --asset "$good_pkg" --expected-commit "$EXPECTED"

# --- 5) 参数校验 ----------------------------------------------------------------
expect_fail "short sha is rejected" "--expected-commit must be a full 40-character" \
  --asset "$good_app" --expected-commit "abc123"

# The signing runner requires the same embedded proof in the update and installer.
proof_tests() {
  local -x REQUIRE_CLIENT_PROOF_KEY=1
  local -x SAYALL_CLIENT_PROOF_KEY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  expect_fail "required proof absent in update is rejected" "missing the required client proof key" \
    --asset "$good_zip" --expected-commit "$EXPECTED"
  expect_fail "required proof absent in installer is rejected" "missing the required client proof key" \
    --asset "$good_pkg" --expected-commit "$EXPECTED"

  /usr/bin/plutil -insert SayAllClientProofKey -string "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$good_app/Contents/Info.plist"
  expect_fail "different proof is rejected" "client proof key does not match" \
    --asset "$good_app" --expected-commit "$EXPECTED"
  /usr/bin/plutil -replace SayAllClientProofKey -string "$SAYALL_CLIENT_PROOF_KEY" "$good_app/Contents/Info.plist"
  proof_zip="$WORK_DIR/SayAll-proof.zip"
  /usr/bin/ditto -c -k --keepParent "$good_app" "$proof_zip"
  expect_ok "packaged update with matching proof passes" --asset "$proof_zip" --expected-commit "$EXPECTED"
  /bin/cp "$good_app/Contents/Info.plist" "$pkg_root/SayAll.app/Contents/Info.plist"
  proof_pkg="$WORK_DIR/SayAll-proof.pkg"
  pkgbuild --quiet --ownership preserve --root "$pkg_root" \
    --identifier com.example.sayall.source-test --version 1.0 "$proof_pkg"
  expect_ok "packaged installer with matching proof passes" --asset "$proof_pkg" --expected-commit "$EXPECTED"
}
proof_tests

print "RESULT passed=$passed failed=0"
