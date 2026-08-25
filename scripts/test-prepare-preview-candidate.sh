#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/sayall-preview-candidate-test.XXXXXX)"
ORIGIN="$WORK_DIR/origin.git"
ORCHESTRATOR="$WORK_DIR/orchestrator"
FAKE_GH="$WORK_DIR/fake-gh"

cleanup() {
  local trash_root="$HOME/.Trash"
  local trash_target="$trash_root/sayall-preview-candidate-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$trash_root"
  if [[ -d "$WORK_DIR" ]]; then
    /bin/mv "$WORK_DIR" "$trash_target"
  fi
}
trap cleanup EXIT

/usr/bin/git init -q --bare "$ORIGIN"
/usr/bin/git clone -q "$ORIGIN" "$ORCHESTRATOR"
/bin/mkdir -p \
  "$ORCHESTRATOR/Resources/zh-Hans.lproj" \
  "$ORCHESTRATOR/Resources/en.lproj" \
  "$ORCHESTRATOR/scripts"
/bin/cp "$ROOT/scripts/prepare-preview-candidate.sh" \
  "$ORCHESTRATOR/scripts/prepare-preview-candidate.sh"

print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
   <key>CFBundleDisplayName</key>
    <string>Fixture</string>
  <key>CFBundleVersion</key>
     <string>199</string>
    <key>CFBundleShortVersionString</key>
  <string>1.9.4</string>
 <key>NSBonjourServices</key>
    <array>
      <string>_fixture._tcp</string>
    </array>
</dict>
</plist>' > "$ORCHESTRATOR/Resources/Info.plist"
print -r -- '# 版本历史

## 1.9.4

- 旧版本。' > "$ORCHESTRATOR/Resources/zh-Hans.lproj/ReleaseHistory.md"
print -r -- '# Release History

## 1.9.4

- Previous version.' > "$ORCHESTRATOR/Resources/en.lproj/ReleaseHistory.md"
print -r -- '#!/bin/zsh
set -euo pipefail
test "$(git -C "$REPOSITORY_ROOT" branch --show-current)" = "$GITHUB_REF_NAME"
print "PREVIEW BRANCH PASS"' > "$ORCHESTRATOR/scripts/verify-preview-branch.sh"
print -r -- '#!/bin/zsh
set -euo pipefail
print "$(git branch --show-current) $(git rev-parse HEAD)" >> "${FAKE_PR_LOG:?}"
print "PREVIEW RECORDING DRAFT PR READY: https://example.invalid/pr/1"' \
  > "$ORCHESTRATOR/scripts/prepare-preview-recording-pr.sh"
/bin/chmod 755 "$ORCHESTRATOR/scripts/"*.sh

/usr/bin/git -C "$ORCHESTRATOR" add .
/usr/bin/git -C "$ORCHESTRATOR" \
  -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -q -m base
/usr/bin/git -C "$ORCHESTRATOR" branch -M main
/usr/bin/git -C "$ORCHESTRATOR" tag v1.9.4
/usr/bin/git -C "$ORCHESTRATOR" push -q origin main --tags
main_sha="$(/usr/bin/git -C "$ORCHESTRATOR" rev-parse HEAD)"

print -r -- '#!/bin/zsh
set -euo pipefail
case "${1:-} ${2:-}" in
  "run list")
    jq -n --arg sha "${FAKE_MAIN_SHA:?}" "[{databaseId:100,status:\"completed\",conclusion:\"success\",headSha:\$sha,url:\"https://example.invalid/actions/100\"}]"
    ;;
  "release view")
    exit 1
    ;;
  *)
    print -u2 "unexpected fake gh invocation: $*"
    exit 2
    ;;
esac' > "$FAKE_GH"
/bin/chmod 755 "$FAKE_GH"

zh_notes="$WORK_DIR/zh-notes.md"
en_notes="$WORK_DIR/en-notes.md"
print -r -- '- 新预览功能。' > "$zh_notes"
print -r -- '- New Preview capability.' > "$en_notes"
pr_log="$WORK_DIR/pr.log"
: > "$pr_log"

FAKE_MAIN_SHA="$main_sha" FAKE_PR_LOG="$pr_log" \
REPOSITORY_ROOT="$ORCHESTRATOR" GH_BIN="$FAKE_GH" \
  "$ORCHESTRATOR/scripts/prepare-preview-candidate.sh" \
    1.9.5 200 "$zh_notes" "$en_notes" "$WORK_DIR/candidate-195" \
    > "$WORK_DIR/fresh.txt" 2>&1 || {
      /bin/cat "$WORK_DIR/fresh.txt" >&2
      exit 1
    }
/usr/bin/grep -Fq 'PREVIEW CANDIDATE READY: release/pre-v1.9.5' "$WORK_DIR/fresh.txt"
candidate_195_sha="$(/usr/bin/git -C "$WORK_DIR/candidate-195" rev-parse HEAD)"
test "$(/usr/bin/git -C "$WORK_DIR/candidate-195" rev-parse HEAD^)" = "$main_sha"
test "$(/usr/bin/git -C "$WORK_DIR/candidate-195" rev-list --count "$main_sha"..HEAD)" = 1
test "$(/usr/bin/git -C "$WORK_DIR/candidate-195" diff-tree --no-commit-id --name-only -r HEAD | LC_ALL=C /usr/bin/sort)" = \
  $'Resources/Info.plist\nResources/en.lproj/ReleaseHistory.md\nResources/zh-Hans.lproj/ReleaseHistory.md'
/usr/bin/python3 - "$ORCHESTRATOR/Resources/Info.plist" \
  "$WORK_DIR/candidate-195/Resources/Info.plist" <<'PY'
from pathlib import Path
import re
import sys

base = Path(sys.argv[1]).read_bytes()
candidate = Path(sys.argv[2]).read_bytes()
expected = base
for key, old, new in (
    (b"CFBundleShortVersionString", b"1.9.4", b"1.9.5"),
    (b"CFBundleVersion", b"199", b"200"),
):
    pattern = re.compile(
        rb"(<key>" + re.escape(key) + rb"</key>[ \t\r\n]*<string>)" +
        re.escape(old) + rb"(</string>)"
    )
    expected, count = pattern.subn(
        lambda match: match.group(1) + new + match.group(2),
        expected,
        count=1,
    )
    if count != 1:
        raise SystemExit(f"fixture key replacement count for {key!r}: {count}")
if candidate != expected:
    raise SystemExit("candidate plist changed bytes other than version/build values")
PY
/usr/bin/grep -Fq '## 1.9.5（预发布）' \
  "$WORK_DIR/candidate-195/Resources/zh-Hans.lproj/ReleaseHistory.md"
/usr/bin/grep -Fq '## 1.9.5 (Pre-release)' \
  "$WORK_DIR/candidate-195/Resources/en.lproj/ReleaseHistory.md"

FAKE_MAIN_SHA="$main_sha" FAKE_PR_LOG="$pr_log" \
REPOSITORY_ROOT="$ORCHESTRATOR" GH_BIN="$FAKE_GH" \
  "$ORCHESTRATOR/scripts/prepare-preview-candidate.sh" \
    1.9.5 200 "$zh_notes" "$en_notes" "$WORK_DIR/unused-reuse-path" \
    > "$WORK_DIR/reuse.txt" 2>&1 || {
      /bin/cat "$WORK_DIR/reuse.txt" >&2
      exit 1
    }
/usr/bin/grep -Fq 'PREVIEW CANDIDATE REUSED: release/pre-v1.9.5' "$WORK_DIR/reuse.txt"
test "$(/usr/bin/git -C "$WORK_DIR/candidate-195" rev-parse HEAD)" = "$candidate_195_sha"
test -z "$(/usr/bin/git -C "$ORCHESTRATOR" ls-remote --heads origin 'refs/heads/release/pre-v1.9.5-*')"

/usr/bin/git -C "$ORCHESTRATOR" tag v1.9.6 "$main_sha"
/usr/bin/git -C "$ORCHESTRATOR" push -q origin v1.9.6
FAKE_MAIN_SHA="$main_sha" FAKE_PR_LOG="$pr_log" \
REPOSITORY_ROOT="$ORCHESTRATOR" GH_BIN="$FAKE_GH" \
  "$ORCHESTRATOR/scripts/prepare-preview-candidate.sh" \
    1.9.6 201 "$zh_notes" "$en_notes" "$WORK_DIR/candidate-197" \
    > "$WORK_DIR/increment.txt" 2>&1 || {
      /bin/cat "$WORK_DIR/increment.txt" >&2
      exit 1
    }
/usr/bin/grep -Fq 'PREVIEW CANDIDATE READY: release/pre-v1.9.7' "$WORK_DIR/increment.txt"
test "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$WORK_DIR/candidate-197/Resources/Info.plist")" = 1.9.7
test "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$WORK_DIR/candidate-197/Resources/Info.plist")" = 201
test -z "$(/usr/bin/git -C "$ORCHESTRATOR" ls-remote --heads origin 'refs/heads/release/pre-v1.9.7-*')"

FAKE_MAIN_SHA="$main_sha" FAKE_PR_LOG="$pr_log" \
REPOSITORY_ROOT="$ORCHESTRATOR" GH_BIN="$FAKE_GH" \
  "$ORCHESTRATOR/scripts/prepare-preview-candidate.sh" \
    1.9.8 199 "$zh_notes" "$en_notes" "$WORK_DIR/candidate-auto-build" \
    > "$WORK_DIR/auto-build.txt" 2>&1 || {
      /bin/cat "$WORK_DIR/auto-build.txt" >&2
      exit 1
    }
/usr/bin/grep -Fq 'VERSION_BUILD: 1.9.8 (200)' "$WORK_DIR/auto-build.txt"
test "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$WORK_DIR/candidate-auto-build/Resources/Info.plist")" = 200

test "$(/usr/bin/wc -l < "$pr_log" | /usr/bin/tr -d ' ')" = 4
print "PREVIEW CANDIDATE PREPARATION TEST PASS"
