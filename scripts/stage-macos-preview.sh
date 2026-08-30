#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
WORKFLOW_FILE="mac-release-package.yml"
MODE="${1:-preview}"

[[ "$REPOSITORY" == "HD838A/remote-mic-app" ]] || {
  print -u2 "Preview staging is restricted to HD838A/remote-mic-app"
  exit 1
}

if [[ "$#" -gt 1 || ( "$MODE" != preview && "$MODE" != smoke ) ]]; then
  print -u2 "usage: $0 [preview|smoke]"
  exit 2
fi
for command_name in git jq plutil "$GH_BIN"; do
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

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || {
  print -u2 "staging requires a clean committed worktree"
  exit 1
}
[[ "$(git branch --show-current)" == main ]] || {
  print -u2 "staging must run from main"
  exit 1
}
git fetch --no-tags origin main
commit="$(git rev-parse HEAD)"
[[ "$commit" == "$(git rev-parse origin/main)" ]] || {
  print -u2 "local main must exactly match origin/main"
  exit 1
}
version="$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
build="$(plutil -extract CFBundleVersion raw -o - Resources/Info.plist)"
tag="v$version"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || {
  print -u2 "Info.plist version/build is invalid"
  exit 1
}

if [[ "$MODE" == preview ]]; then
  tag_is_occupied=0
  tag_probe_status=0
  if git ls-remote --exit-code origin "refs/tags/$tag" >/dev/null 2>&1; then
    tag_is_occupied=1
  else
    tag_probe_status=$?
    if (( tag_probe_status != 2 )); then
      print -u2 "unable to check remote Tag $tag (git exit $tag_probe_status)"
      exit 1
    fi
  fi

  release_is_occupied=0
  release_response=""
  if release_response="$($GH_BIN api --include "repos/$REPOSITORY/releases/tags/$tag" 2>/dev/null)"; then
    release_is_occupied=1
  else
    release_probe_status=$?
    release_http_code="$(print -r -- "$release_response" | /usr/bin/awk '$1 ~ /^HTTP\/[0-9.]+$/ {code=$2} END {print code}')"
    if [[ "$release_http_code" != 404 ]]; then
      if [[ -n "$release_http_code" ]]; then
        print -u2 "unable to check GitHub Release $tag (HTTP $release_http_code, gh exit $release_probe_status)"
      else
        print -u2 "unable to check GitHub Release $tag (no HTTP response, gh exit $release_probe_status)"
      fi
      exit 1
    fi
  fi

  if (( tag_is_occupied || release_is_occupied )); then
    print -u2 "$tag is already a public identity; prepare the next patch version and continue automatically"
    exit 42
  fi

  cdn_status=0
  "$CDN_PROBE_BIN" "$tag" >/dev/null || cdn_status=$?
  case "$cdn_status" in
    0)
      ;;
    42)
      print -u2 "$tag already has immutable CDN assets; prepare the next patch version and continue automatically"
      exit 42
      ;;
    *)
      print -u2 "unable to establish CDN availability for $tag"
      exit 1
      ;;
  esac

  stable_release="$($GH_BIN api "repos/$REPOSITORY/releases/latest")" || {
    print -u2 "unable to verify the current stable latest Release"
    exit 1
  }
  stable_latest="$(print -r -- "$stable_release" | jq -r '.tag_name')"
  print -r -- "$stable_release" | jq -e \
    --arg tag "$stable_latest" \
    '.tag_name == $tag and ($tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and .draft == false and .prerelease == false' >/dev/null || {
    print -u2 "Preview staging requires releases/latest to be a formal stable Release; found $stable_latest"
    exit 1
  }
fi

GITHUB_REPOSITORY="$REPOSITORY" GH_BIN="$GH_BIN" \
  "$ROOT/scripts/verify-release-ready-main-ci.sh" "$commit"
REPOSITORY_ROOT="$ROOT" "$ROOT/scripts/verify-release-workflow-gh-token.sh" >/dev/null
GITHUB_REPOSITORY="$REPOSITORY" \
  "$ROOT/scripts/verify-release-dependency-pins.sh" >/dev/null

run_title="mac-release $MODE $commit"
dispatched_at="$(/bin/date -u +'%Y-%m-%dT%H:%M:%SZ')"
"$GH_BIN" workflow run "$WORKFLOW_FILE" --repo "$REPOSITORY" --ref main \
  --raw-field "mode=$MODE" \
  --raw-field "expected_commit=$commit"

run_id=""
run_url=""
for lookup_attempt in {1..6}; do
  runs_json="$("$GH_BIN" run list --repo "$REPOSITORY" \
    --workflow "$WORKFLOW_FILE" --branch main --commit "$commit" \
    --event workflow_dispatch --limit 20 \
    --json databaseId,createdAt,displayTitle,event,headBranch,headSha,url)"
  matches="$(print -r -- "$runs_json" | jq -c \
    --arg title "$run_title" --arg sha "$commit" --arg created "$dispatched_at" \
    '[.[] | select(.event == "workflow_dispatch" and .headBranch == "main" and .headSha == $sha and .displayTitle == $title and .createdAt >= $created)]')"
  count="$(print -r -- "$matches" | jq -r length)"
  if (( count > 1 )); then
    print -u2 "dispatch succeeded, but multiple exact Runs were found; do not redispatch"
    exit 3
  fi
  if (( count == 1 )); then
    run_id="$(print -r -- "$matches" | jq -r '.[0].databaseId')"
    run_url="$(print -r -- "$matches" | jq -r '.[0].url')"
    break
  fi
  (( lookup_attempt < 6 )) && /bin/sleep 5
done

[[ "$run_id" =~ ^[1-9][0-9]*$ && -n "$run_url" ]] || {
  print -u2 "dispatch succeeded, but its Run was not resolved within 25 seconds; do not redispatch"
  exit 3
}
print "MAC RELEASE STAGING DISPATCHED"
print "MODE: $MODE"
print "TAG: $tag"
print "SOURCE_COMMIT: $commit"
print "RUN_ID: $run_id"
print "RUN_URL: $run_url"
