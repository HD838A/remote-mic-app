#!/bin/zsh
set -euo pipefail
umask 077

# Regression tests for the release-notes commit line renderer.
#
# Build 284 shipped with a hand-written `Commit：公开 main 01606521` while the
# package came from 16c1fe2b. The renderer replaces that line with the real build
# tree and baseline, and keeps whatever followed the first `；` (private tag).

SCRIPT_ROOT="${0:A:h:h}"
RENDER="$SCRIPT_ROOT/scripts/render-private-draft-notes.sh"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/sayall-notes-render-test.XXXXXX)"

cleanup() {
  local trash_root="$HOME/.Trash"
  local trash_target="$trash_root/sayall-notes-render-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$trash_root"
  [[ -d "$WORK_DIR" ]] && /bin/mv "$WORK_DIR" "$trash_target"
}
trap cleanup EXIT INT TERM

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BASE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
passed=0
last_output=""

fail() {
  print -u2 "release notes render test failed: $1"
  exit 1
}

expect_ok() {
  local description="$1"
  shift
  local exit_code=0
  last_output="$("$RENDER" "$@" 2>&1)" || exit_code=$?
  (( exit_code == 0 )) || fail "$description: expected pass, exit=$exit_code output=$last_output"
  (( passed += 1 ))
  print "PASS $description"
}

expect_fail() {
  local description="$1" expected_message="$2"
  shift 2
  local exit_code=0
  last_output="$("$RENDER" "$@" 2>&1)" || exit_code=$?
  (( exit_code != 0 )) || fail "$description: expected failure but it passed"
  [[ "$last_output" == *"$expected_message"* ]] || \
    fail "$description: failure message missing [$expected_message]: $last_output"
  (( passed += 1 ))
  print "PASS $description"
}

[[ -x "$RENDER" ]] || fail "render-private-draft-notes.sh is not executable"

# --- 1) 已有 Commit 行：替换并保留 `；` 之后的内容 ---------------------------------
notes_with_line="$WORK_DIR/with-line.md"
cat > "$notes_with_line" <<'NOTES'
## 内部测试包

- 私有平台复用 tag `2.7.2` 的已发布构件。
Commit：公开 main `01606521`（手写值）；私有平台 tag `2.7.2` `c6f24bd8`
- 其它说明
NOTES
out_with_line="$WORK_DIR/with-line.out.md"
expect_ok "existing commit line is rewritten" \
  --notes "$notes_with_line" --out "$out_with_line" \
  --source-commit "$HEAD_SHA" --baseline-ref origin/main --baseline-sha "$BASE_SHA"

/usr/bin/grep -Fq 'Commit：构建树 `aaaaaaa` · 基线 `origin/main` `bbbbbbb`；私有平台 tag `2.7.2` `c6f24bd8`' "$out_with_line" || \
  fail "rendered line is wrong: $(/usr/bin/grep '^Commit' "$out_with_line")"
/usr/bin/grep -Fq '01606521' "$out_with_line" && fail "hand-written main SHA survived the rewrite"
/usr/bin/grep -Fq '其它说明' "$out_with_line" || fail "unrelated lines were dropped"
(( passed += 1 ))
print "PASS suffix and unrelated lines are preserved"

# --- 2) 没有 Commit 行：追加 ----------------------------------------------------
notes_without_line="$WORK_DIR/without-line.md"
print '## 内部测试包\n\n- 没有 Commit 行' > "$notes_without_line"
out_without_line="$WORK_DIR/without-line.out.md"
expect_ok "missing commit line is appended" \
  --notes "$notes_without_line" --out "$out_without_line" \
  --source-commit "$HEAD_SHA" --baseline-ref origin/main --baseline-sha "$BASE_SHA"
/usr/bin/grep -Fq 'Commit：构建树 `aaaaaaa` · 基线 `origin/main` `bbbbb' "$out_without_line" || \
  fail "appended line is missing"

# --- 3) 参数校验 ----------------------------------------------------------------
expect_fail "writing over the source notes is rejected" "--out must differ from --notes" \
  --notes "$notes_with_line" --out "$notes_with_line" \
  --source-commit "$HEAD_SHA" --baseline-ref origin/main --baseline-sha "$BASE_SHA"
expect_fail "short source commit is rejected" "--source-commit must be a full 40-character" \
  --notes "$notes_with_line" --out "$WORK_DIR/x.md" \
  --source-commit "abc" --baseline-ref origin/main --baseline-sha "$BASE_SHA"

# --- 4) 渲染结果没有替换字符 ----------------------------------------------------
/usr/bin/grep -q "$(/usr/bin/printf '\357\277\275')" "$out_with_line" && fail "rendered notes contain U+FFFD"
(( passed += 1 ))
print "PASS rendered notes contain no replacement character"

print "RESULT passed=$passed failed=0"
