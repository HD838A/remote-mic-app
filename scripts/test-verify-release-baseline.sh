#!/bin/zsh
set -euo pipefail
umask 077

# Regression tests for the release baseline gate.
#
# The gate exists because build 284 was packaged from a stale feature branch: its
# HEAD was 11 merges behind origin/main, while the release notes claimed the then
# current main SHA. These fixtures pin both directions of the ancestry check, the
# packaging allowlist, the required-commit assertion and the dirty-worktree rule.

SCRIPT_ROOT="${0:A:h:h}"
GUARD="$SCRIPT_ROOT/scripts/verify-release-baseline.sh"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/sayall-release-baseline-test.XXXXXX)"

cleanup() {
  local trash_root="$HOME/.Trash"
  local trash_target="$trash_root/sayall-release-baseline-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$trash_root"
  [[ -d "$WORK_DIR" ]] && /bin/mv "$WORK_DIR" "$trash_target"
}
trap cleanup EXIT

passed=0
repo=""
last_output=""

fail() {
  print -u2 "release baseline gate test failed: $1"
  exit 1
}

commit() {
  local target="$1" message="$2"
  git -C "$target" add -A
  git -C "$target" commit -q -m "$message"
}

make_repo() {
  local root="$1"
  local repo_path="$root/repo"
  local origin="$root/origin.git"
  /bin/mkdir -p "$repo_path/Sources/RemoteMic" "$repo_path/Resources" "$repo_path/packaging/demo"
  git -C "$root" init -q --bare "$origin"
  git init -q -b main "$repo_path"
  git -C "$repo_path" config user.email "release-baseline-test@example.com"
  git -C "$repo_path" config user.name "Release Baseline Test"
  print 'let value = 1' > "$repo_path/Sources/RemoteMic/Main.swift"
  print '<plist><dict><key>CFBundleVersion</key><string>1</string></dict></plist>' > "$repo_path/Resources/Info.plist"
  print '{"policy":"v1"}' > "$repo_path/packaging/demo/policy.lock.json"
  commit "$repo_path" "initial"
  git -C "$repo_path" remote add origin "$origin"
  git -C "$repo_path" push -q -u origin main
  print -r -- "$repo_path"
}

expect_ok() {
  local description="$1"
  shift
  local exit_code=0
  last_output="$(REPOSITORY_ROOT="$repo" "$GUARD" --no-fetch "$@" 2>&1)" || exit_code=$?
  (( exit_code == 0 )) || fail "$description: expected pass, exit=$exit_code output=$last_output"
  (( passed += 1 ))
  print "PASS $description"
}

expect_fail() {
  local description="$1" expected_message="$2"
  shift 2
  local exit_code=0
  last_output="$(REPOSITORY_ROOT="$repo" "$GUARD" --no-fetch "$@" 2>&1)" || exit_code=$?
  (( exit_code != 0 )) || fail "$description: expected failure but the gate passed"
  [[ "$last_output" == *"$expected_message"* ]] || \
    fail "$description: failure message missing [$expected_message]: $last_output"
  (( passed += 1 ))
  print "PASS $description"
}

[[ -x "$GUARD" ]] || fail "verify-release-baseline.sh is not executable"

# --- 1) 干净 main：通过，AHEAD=0 -------------------------------------------------
repo="$(make_repo "$WORK_DIR/clean")"
expect_ok "clean main passes"
[[ "$last_output" == *"RELEASE_BASELINE_OK"* ]] || fail "clean main did not report RELEASE_BASELINE_OK"
[[ "$last_output" == *"RELEASE_AHEAD_COUNT=0"* ]] || fail "clean main reported a non-zero ahead count: $last_output"

# --- 2) 只有 build 递增与政策锁：通过 ---------------------------------------------
git -C "$repo" switch -q -c packaging
print '<plist><dict><key>CFBundleVersion</key><string>2</string></dict></plist>' > "$repo/Resources/Info.plist"
commit "$repo" "bump build"
print '{"policy":"v2"}' > "$repo/packaging/demo/policy.lock.json"
commit "$repo" "sync policy lock"
expect_ok "packaging commits pass"
[[ "$last_output" == *"RELEASE_AHEAD_COUNT=2"* ]] || fail "packaging commits reported the wrong ahead count: $last_output"

# --- 3) 混入产品改动：失败 ------------------------------------------------------
print 'let value = 2' > "$repo/Sources/RemoteMic/Main.swift"
commit "$repo" "product change on packaging branch"
expect_fail "product change is rejected" "may only change Resources/Info.plist or packaging"
git -C "$repo" reset -q --hard HEAD~1

# --- 4) 基线过期：失败 ----------------------------------------------------------
git -C "$repo" switch -q main
print 'let value = 3' > "$repo/Sources/RemoteMic/Main.swift"
commit "$repo" "main moved on"
git -C "$repo" push -q origin main
git -C "$repo" switch -q packaging
expect_fail "stale packaging branch is rejected" "is not built on origin/main"
git -C "$repo" switch -q main
git -C "$repo" reset -q --hard HEAD~1
git -C "$repo" push -q --force origin main
git -C "$repo" switch -q packaging
git -C "$repo" rebase -q main

# --- 5) 目标提交断言 ------------------------------------------------------------
base_sha="$(git -C "$repo" rev-parse main)"
expect_ok "required commit present" --require "$base_sha"
expect_ok "historical head is validated" --head "$base_sha"
# CI 的 Preview 打卡：基线钉在 dispatch 指定的提交上，main 前进也不应误判。
expect_ok "pinned baseline equal to head passes" --base "$base_sha" --head "$base_sha"
[[ "$last_output" == *"RELEASE_AHEAD_COUNT=0"* ]] || fail "--head reported the wrong ahead count: $last_output"
git -C "$repo" switch -q -c side "$base_sha"
print 'side' > "$repo/side.txt"
commit "$repo" "unrelated work"
side_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" switch -q packaging
expect_fail "missing required commit is rejected" "is not part of the built tree" --require "$side_sha"

# --- 6) 脏工作树 ----------------------------------------------------------------
print 'dirty' >> "$repo/Sources/RemoteMic/Main.swift"
expect_fail "dirty worktree is rejected" "worktree is not clean"
last_output="$(REPOSITORY_ROOT="$repo" "$GUARD" --no-fetch --allow-dirty 2>&1)" || \
  fail "dirty worktree should pass with --allow-dirty: $last_output"
[[ "$last_output" == *"RELEASE_DIRTY=true"* ]] || fail "--allow-dirty did not report RELEASE_DIRTY=true: $last_output"
(( passed += 1 ))
print "PASS dirty worktree passes with --allow-dirty"

print "RESULT passed=$passed failed=0"
