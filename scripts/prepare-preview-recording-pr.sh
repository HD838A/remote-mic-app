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
REPOSITORY_ROOT="$ROOT" ALLOW_FROZEN_BASE_MAIN=1 "$TRUSTED_RUNNER" >/dev/null
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

# GitHub attaches required checks to a commit, not to a branch. Refuse to
# create a second recording PR for the same candidate SHA, even when another
# branch already points at it.
PR_BY_SHA_JSON="$(
  "$GH_BIN" api \
    "repos/$REPOSITORY/commits/$HEAD_COMMIT/pulls" \
    --header 'Accept: application/vnd.github+json' \
    --jq "[.[] | select(.state == \"open\" and .base.ref == \"main\" and .head.repo.full_name == \"$REPOSITORY\") | {number, url: .html_url, isDraft: .draft, headRefName: .head.ref, headRefOid: .head.sha}]"
)"
PR_BY_SHA_COUNT="$(print -r -- "$PR_BY_SHA_JSON" | jq 'length')"
if (( PR_BY_SHA_COUNT > 1 )); then
  print -u2 "candidate $HEAD_COMMIT already has multiple open main recording PRs; resolve the duplicate before continuing"
  exit 1
fi
if (( PR_BY_SHA_COUNT == 1 )); then
  if ! print -r -- "$PR_BY_SHA_JSON" | jq -e \
    --arg branch "$BRANCH" --arg headSha "$HEAD_COMMIT" \
    '.[0].headRefName == $branch and .[0].headRefOid == $headSha and .[0].isDraft == true' >/dev/null; then
    print -u2 "candidate $HEAD_COMMIT already has an open recording PR on another branch or in a non-Draft state"
    exit 1
  fi
fi

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
  PR_BY_SHA_JSON="$(
    "$GH_BIN" api \
      "repos/$REPOSITORY/commits/$HEAD_COMMIT/pulls" \
      --header 'Accept: application/vnd.github+json' \
      --jq "[.[] | select(.state == \"open\" and .base.ref == \"main\" and .head.repo.full_name == \"$REPOSITORY\") | {number, url: .html_url, isDraft: .draft, headRefName: .head.ref, headRefOid: .head.sha}]"
  )"
  if ! print -r -- "$PR_BY_SHA_JSON" | jq -e \
    --arg branch "$BRANCH" --arg headSha "$HEAD_COMMIT" '
      length == 1 and
      .[0].headRefName == $branch and
      .[0].headRefOid == $headSha and
      .[0].isDraft == true
    ' >/dev/null; then
    print -u2 "recording PR creation did not converge to one exact-SHA Draft PR"
    exit 1
  fi
  PR_URL="$(print -r -- "$PR_BY_SHA_JSON" | jq -r '.[0].url')"
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
