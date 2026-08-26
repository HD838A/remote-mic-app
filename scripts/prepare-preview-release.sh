#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
REQUESTED_VERSION="${1:-}"
REQUESTED_BUILD="${2:-}"
ZH_NOTES="${3:-}"
EN_NOTES="${4:-}"

[[ "$REPOSITORY" == "HD838A/remote-mic-app" ]] || {
  print -u2 "Preview metadata preparation is restricted to HD838A/remote-mic-app"
  exit 1
}

if [[ "$#" -ne 4 ]]; then
  print -u2 "usage: $0 <requested-version> <build> <zh-notes-file> <en-notes-file>"
  exit 2
fi
[[ "$REQUESTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  print -u2 "requested version must be X.Y.Z"
  exit 2
}
[[ "$REQUESTED_BUILD" =~ ^[1-9][0-9]*$ ]] || {
  print -u2 "build must be a positive integer"
  exit 2
}
for command_name in git plutil python3 rg "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done
CDN_PROBE_BIN="$ROOT/scripts/verify-preview-cdn-availability.sh"
[[ -x "$CDN_PROBE_BIN" ]] || {
  print -u2 "Missing executable CDN occupancy checker: $CDN_PROBE_BIN"
  exit 1
}
for notes_file in "$ZH_NOTES" "$EN_NOTES"; do
  [[ -s "$notes_file" ]] || {
    print -u2 "release notes file is empty: $notes_file"
    exit 1
  }
  /usr/bin/awk 'NF && $0 !~ /^- / {exit 1}' "$notes_file" || {
    print -u2 "every non-empty release note line must start with '- ': $notes_file"
    exit 1
  }
done

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || {
  print -u2 "preview metadata preparation requires a clean worktree"
  exit 1
}
branch="$(git symbolic-ref --quiet --short HEAD)" || {
  print -u2 "preview metadata preparation requires a named branch"
  exit 1
}
[[ "$branch" != main ]] || {
  print -u2 "create a normal PR branch from origin/main before preparing preview metadata"
  exit 1
}
git fetch --no-tags origin main
base_commit="$(git rev-parse origin/main)"
[[ "$(git rev-parse HEAD)" == "$base_commit" ]] || {
  print -u2 "preview metadata branch must start at the latest origin/main"
  exit 1
}

base_version="$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
base_build="$(plutil -extract CFBundleVersion raw -o - Resources/Info.plist)"
[[ "$base_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$base_build" =~ ^[0-9]+$ ]] || {
  print -u2 "current Info.plist version/build is invalid"
  exit 1
}

version_is_less() {
  local left="$1" right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<< "$left"
  IFS=. read -r right_major right_minor right_patch <<< "$right"
  (( left_major < right_major )) && return 0
  (( left_major > right_major )) && return 1
  (( left_minor < right_minor )) && return 0
  (( left_minor > right_minor )) && return 1
  (( left_patch < right_patch ))
}

increment_patch() {
  local value="$1" major minor patch
  IFS=. read -r major minor patch <<< "$value"
  print -r -- "$major.$minor.$(( patch + 1 ))"
}

remote_tag_is_occupied() {
  local tag="$1" probe_status
  if git ls-remote --exit-code origin "refs/tags/$tag" >/dev/null 2>&1; then
    return 0
  else
    probe_status=$?
  fi
  if (( probe_status == 2 )); then
    return 1
  fi
  print -u2 "unable to check remote Tag $tag (git exit $probe_status)"
  exit 1
}

public_release_is_occupied() {
  local tag="$1" response probe_status http_code
  if response="$($GH_BIN api --include "repos/$REPOSITORY/releases/tags/$tag" 2>/dev/null)"; then
    return 0
  fi
  probe_status=$?
  http_code="$(print -r -- "$response" | /usr/bin/awk '$1 ~ /^HTTP\/[0-9.]+$/ {code=$2} END {print code}')"
  if [[ "$http_code" == 404 ]]; then
    return 1
  fi
  if [[ -n "$http_code" ]]; then
    print -u2 "unable to check GitHub Release $tag (HTTP $http_code, gh exit $probe_status)"
  else
    print -u2 "unable to check GitHub Release $tag (no HTTP response, gh exit $probe_status)"
  fi
  exit 1
}

version="$REQUESTED_VERSION"
if version_is_less "$version" "$base_version"; then
  version="$base_version"
fi
while true; do
  tag="v$version"
  if remote_tag_is_occupied "$tag" || public_release_is_occupied "$tag"; then
    version="$(increment_patch "$version")"
    continue
  fi
  cdn_status=0
  "$CDN_PROBE_BIN" "$tag" >/dev/null || cdn_status=$?
  case "$cdn_status" in
    0)
      break
      ;;
    42)
      version="$(increment_patch "$version")"
      ;;
    *)
      print -u2 "unable to establish CDN availability for $tag"
      exit 1
      ;;
  esac
done

build="$REQUESTED_BUILD"
if (( build <= base_build )); then
  build=$(( base_build + 1 ))
fi

python3 - Resources/Info.plist "$version" "$build" <<'PY'
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
    if len(list(pattern.finditer(data))) != 1:
        raise SystemExit(f"expected exactly one {key.decode()} value in {plist_path}")
    data = pattern.sub(
        lambda match: match.group("before") + match.group("between") + value + match.group("suffix"),
        data,
        count=1,
    )
plist_path.write_bytes(data)
PY

prepend_history() {
  local history="$1" notes="$2" heading="$3"
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
history_path.write_text(
    f"{lines[0]}\n\n## {heading}\n\n{notes}\n\n{body}\n",
    encoding="utf-8",
)
PY
}

prepend_history Resources/zh-Hans.lproj/ReleaseHistory.md "$ZH_NOTES" "${version}（预发布）"
prepend_history Resources/en.lproj/ReleaseHistory.md "$EN_NOTES" "${version} (Pre-release)"

expected_paths=$'Resources/Info.plist\nResources/en.lproj/ReleaseHistory.md\nResources/zh-Hans.lproj/ReleaseHistory.md'
changed_paths="$(git diff --name-only | LC_ALL=C /usr/bin/sort)"
[[ "$changed_paths" == "$(print -r -- "$expected_paths" | LC_ALL=C /usr/bin/sort)" ]] || {
  print -u2 "preview metadata preparation changed an unexpected file"
  exit 1
}
git diff --check
if rg -i -q \
  '((连续|连点|点击|轻点).{0,24}(版本号|当前版本).{0,24}(次|隐藏|入口))|((tap|click).{0,24}(version|build).{0,24}(times|hidden|secret|invite|enrollment))|(隐藏入口|秘密手势|secret gesture|hidden entry|invitation-code entry)' \
  Resources/zh-Hans.lproj/ReleaseHistory.md Resources/en.lproj/ReleaseHistory.md; then
  print -u2 "release notes contain an internal trigger or confidential enrollment detail"
  exit 1
fi

print "PREVIEW METADATA READY"
print "SELECTED_VERSION: $version"
print "SELECTED_BUILD: $build"
print "BASE_MAIN_COMMIT: $base_commit"
print "NEXT: review, test, commit, push, and merge this normal PR before staging"
