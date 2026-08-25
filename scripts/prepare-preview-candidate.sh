#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
REQUESTED_VERSION="${1:-}"
BUILD="${2:-}"
ZH_NOTES="${3:-}"
EN_NOTES="${4:-}"
CANDIDATE_WORKTREE="${5:-}"

if [[ "$#" -ne 5 ]]; then
  print -u2 "usage: $0 <requested-version> <build> <zh-notes-file> <en-notes-file> <absolute-candidate-worktree>"
  exit 2
fi
[[ "$REQUESTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]]
[[ "$CANDIDATE_WORKTREE" == /* && "$CANDIDATE_WORKTREE" != / && "$CANDIDATE_WORKTREE" != "$ROOT" ]]
for command_name in git jq plutil python3 "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || { print -u2 "Missing required command: $command_name"; exit 1; }
done
for notes in "$ZH_NOTES" "$EN_NOTES"; do
  [[ -s "$notes" ]] || { print -u2 "release notes file is empty: $notes"; exit 1; }
  awk 'NF && $0 !~ /^- / {exit 1}' "$notes" || {
    print -u2 "every non-empty release note line must start with '- ': $notes"
    exit 1
  }
done

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || { print -u2 "candidate preparation requires a clean orchestrator worktree"; exit 1; }
git fetch --no-tags origin main
base_main_commit="$(git rev-parse origin/main)"
base_build="$(git show "$base_main_commit:Resources/Info.plist" | plutil -extract CFBundleVersion raw -o - -- -)"
[[ "$base_build" =~ ^[0-9]+$ ]]
if (( BUILD <= base_build )); then
  BUILD="$(( base_build + 1 ))"
fi

main_run="$($GH_BIN run list --repo "$REPOSITORY" --workflow mac-ci.yml --branch main --commit "$base_main_commit" --limit 20 --json databaseId,status,conclusion,headSha,url | jq -c --arg sha "$base_main_commit" '[.[] | select(.headSha == $sha and .status == "completed" and .conclusion == "success")] | sort_by(.databaseId) | last // empty')"
[[ -n "$main_run" ]] || { print -u2 "latest origin/main has no successful macOS CI proof: $base_main_commit"; exit 1; }

version="$REQUESTED_VERSION"
while true; do
  tag="v$version"
  branch="release/pre-$tag"
  tag_exists=false
  release_exists=false
  git ls-remote --exit-code origin "refs/tags/$tag" >/dev/null 2>&1 && tag_exists=true
  "$GH_BIN" release view "$tag" --repo "$REPOSITORY" --json tagName >/dev/null 2>&1 && release_exists=true
  if [[ "$tag_exists" == false && "$release_exists" == false ]]; then
    break
  fi
  major="${version%%.*}"
  remainder="${version#*.}"
  minor="${remainder%%.*}"
  patch_version="${version##*.}"
  version="$major.$minor.$(( patch_version + 1 ))"
done

tag="v$version"
branch="release/pre-$tag"
remote_branch="$(git ls-remote origin "refs/heads/$branch" | awk 'NR == 1 {print $1}')"
if [[ -n "$remote_branch" ]]; then
  existing_path="$(git worktree list --porcelain | awk -v branch="refs/heads/$branch" '$1 == "worktree" {path=$2} $1 == "branch" && $2 == branch {print path; exit}')"
  if [[ -n "$existing_path" ]]; then
    candidate_root="$existing_path"
  else
    [[ ! -e "$CANDIDATE_WORKTREE" ]] || { print -u2 "candidate worktree path already exists: $CANDIDATE_WORKTREE"; exit 1; }
    git fetch --no-tags origin "refs/heads/$branch:refs/remotes/origin/$branch"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git worktree add "$CANDIDATE_WORKTREE" "$branch"
    else
      git worktree add -b "$branch" "$CANDIDATE_WORKTREE" "refs/remotes/origin/$branch"
    fi
    candidate_root="$CANDIDATE_WORKTREE"
  fi
  test "$(git -C "$candidate_root" rev-parse HEAD)" = "$remote_branch"
  test "$(plutil -extract CFBundleShortVersionString raw -o - "$candidate_root/Resources/Info.plist")" = "$version"
  test "$(plutil -extract CFBundleVersion raw -o - "$candidate_root/Resources/Info.plist")" = "$BUILD"
  GITHUB_REF_NAME="$branch" ALLOW_FROZEN_BASE_MAIN=1 REPOSITORY_ROOT="$candidate_root" \
    "$candidate_root/scripts/verify-preview-branch.sh"
  (cd "$candidate_root" && ./scripts/prepare-preview-recording-pr.sh)
  print "PREVIEW CANDIDATE REUSED: $branch at $remote_branch"
  print "CANDIDATE_WORKTREE: $candidate_root"
  exit 0
fi

[[ ! -e "$CANDIDATE_WORKTREE" ]] || { print -u2 "candidate worktree path already exists: $CANDIDATE_WORKTREE"; exit 1; }
git worktree add -b "$branch" "$CANDIDATE_WORKTREE" "$base_main_commit"
candidate_root="$CANDIDATE_WORKTREE"

python3 - "$candidate_root/Resources/Info.plist" "$version" "$BUILD" <<'PY'
from pathlib import Path
import re
import sys

plist_path = Path(sys.argv[1])
updates = (
    (b"CFBundleShortVersionString", sys.argv[2].encode("ascii")),
    (b"CFBundleVersion", sys.argv[3].encode("ascii")),
)
data = plist_path.read_bytes()

for key, value in updates:
    pattern = re.compile(
        rb"(?P<before><key>" + re.escape(key) +
        rb"</key>)(?P<between>[ \t\r\n]*<string>)[^<]*(?P<suffix></string>)"
    )
    matches = list(pattern.finditer(data))
    if len(matches) != 1:
        raise SystemExit(
            f"expected exactly one {key.decode('ascii')} string in {plist_path}, found {len(matches)}"
        )

    def replace(match: re.Match[bytes]) -> bytes:
        return (
            match.group("before")
            + match.group("between")
            + value
            + match.group("suffix")
        )

    data = pattern.sub(replace, data, count=1)

plist_path.write_bytes(data)
PY
prepend_history() {
  local history="$1"
  local notes="$2"
  local heading="$3"
  python3 - "$history" "$notes" "$heading" <<'PY'
from pathlib import Path
import sys

history_path = Path(sys.argv[1])
notes_path = Path(sys.argv[2])
heading = sys.argv[3]
text = history_path.read_text(encoding="utf-8")
notes = notes_path.read_text(encoding="utf-8").strip()
lines = text.splitlines()
if len(lines) < 2 or not lines[0].startswith("# ") or lines[1] != "":
    raise SystemExit(f"unexpected release history header: {history_path}")
body = "\n".join(lines[2:]).lstrip("\n")
history_path.write_text(f"{lines[0]}\n\n## {heading}\n\n{notes}\n\n{body}\n", encoding="utf-8")
PY
}

prepend_history "$candidate_root/Resources/zh-Hans.lproj/ReleaseHistory.md" "$ZH_NOTES" "${version}（预发布）"
prepend_history "$candidate_root/Resources/en.lproj/ReleaseHistory.md" "$EN_NOTES" "${version} (Pre-release)"

changed_paths="$(git -C "$candidate_root" diff --name-only)"
expected_paths=$'Resources/Info.plist\nResources/en.lproj/ReleaseHistory.md\nResources/zh-Hans.lproj/ReleaseHistory.md'
test "$(print -r -- "$changed_paths" | LC_ALL=C sort)" = "$(print -r -- "$expected_paths" | LC_ALL=C sort)"
git -C "$candidate_root" diff --check
git -C "$candidate_root" add -- \
  Resources/Info.plist \
  Resources/en.lproj/ReleaseHistory.md \
  Resources/zh-Hans.lproj/ReleaseHistory.md
git -C "$candidate_root" -c user.name='SayAll Release Manager' -c user.email='release-manager@sayall.app' \
  commit -m "chore(mac): prepare $tag preview"
candidate_commit="$(git -C "$candidate_root" rev-parse HEAD)"
test "$(git -C "$candidate_root" rev-parse HEAD^)" = "$base_main_commit"
git -C "$candidate_root" push -u origin "$branch"
GITHUB_REF_NAME="$branch" ALLOW_FROZEN_BASE_MAIN=1 REPOSITORY_ROOT="$candidate_root" \
  "$candidate_root/scripts/verify-preview-branch.sh"
(cd "$candidate_root" && ./scripts/prepare-preview-recording-pr.sh)

print "PREVIEW CANDIDATE READY: $branch at $candidate_commit"
print "VERSION_BUILD: $version ($BUILD)"
print "BASE_MAIN_COMMIT: $base_main_commit"
print "MAIN_CI_RUN: $(print -r -- "$main_run" | jq -r '.url')"
print "CANDIDATE_WORKTREE: $candidate_root"
