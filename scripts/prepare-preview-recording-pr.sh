#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi
for command_name in git jq "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

cd "$ROOT"
BASE_COMMIT="$(git rev-parse HEAD^)"
TRUSTED_RUNNER="$(/usr/bin/mktemp /private/tmp/sayall-trusted-recording-pr.XXXXXX)"
git show "${BASE_COMMIT}:scripts/run-trusted-release-validation.sh" > "$TRUSTED_RUNNER"
/bin/chmod 755 "$TRUSTED_RUNNER"
REPOSITORY_ROOT="$ROOT" "$TRUSTED_RUNNER" >/dev/null
BRANCH="$(git symbolic-ref --quiet --short HEAD)"
HEAD_COMMIT="$(git rev-parse HEAD)"
VERSION="${BRANCH#release/pre-v}"
PR_JSON="$(
  "$GH_BIN" pr list \
    --repo "$REPOSITORY" \
    --head "$BRANCH" \
    --base main \
    --state open \
    --json number,url,isDraft,headRefOid
)"

if [[ "$(print -r -- "$PR_JSON" | jq 'length')" == "0" ]]; then
  PR_URL="$(
    "$GH_BIN" pr create \
      --repo "$REPOSITORY" \
      --head "$BRANCH" \
      --base main \
      --draft \
      --title "Prepare to record v$VERSION preview candidate in main" \
      --body "Runs the protected Apple Silicon and Intel checks early for the v$VERSION preview candidate. This PR must remain Draft and cannot merge until the published pre-release bytes and provenance have passed Release Guard verification."
  )"
else
  if ! print -r -- "$PR_JSON" | jq -e \
    --arg headSha "$HEAD_COMMIT" '
      length == 1 and .[0].headRefOid == $headSha and .[0].isDraft == true
    ' >/dev/null; then
    print -u2 "the preview recording PR must point to candidate HEAD and remain Draft before publication"
    exit 1
  fi
  PR_URL="$(print -r -- "$PR_JSON" | jq -r '.[0].url')"
fi

print "PREVIEW RECORDING DRAFT PR READY: $PR_URL"
print "The Draft PR CI may run in parallel with the exact-SHA Preview Candidate workflow."
