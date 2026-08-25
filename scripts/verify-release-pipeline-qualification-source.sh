#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BRANCH="${GITHUB_REF_NAME:-}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:-}"
EXPECTED_PIPELINE_DIGEST="${EXPECTED_PIPELINE_DIGEST:-}"
RELEASE_TAG="${RELEASE_TAG:-}"
QUALIFICATION_REMOTE_NAME="${RELEASE_QUALIFICATION_REMOTE_NAME:-origin}"
RELEASE_MODE="${RELEASE_MODE:-}"
QUALIFICATION_BRANCH_PREFIX="${RELEASE_PIPELINE_QUALIFICATION_BRANCH_PREFIX:-release/pipeline-qualification/}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 2
fi
if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)" || {
    print -u2 "release pipeline qualification requires a named branch"
    exit 1
  }
fi
if [[ "$RELEASE_MODE" != "qualification" ]]; then
  print -u2 "protected release pipeline qualification requires explicit qualification mode"
  exit 1
fi
if [[ ! "$BRANCH" =~ '^release/pipeline-qualification/[a-z0-9][a-z0-9._-]*$' ]] || \
   [[ "$BRANCH" != ${QUALIFICATION_BRANCH_PREFIX}* ]]; then
  print -u2 "protected release qualification must run from ${QUALIFICATION_BRANCH_PREFIX}<pr-or-commit>"
  exit 1
fi
if [[ ! "$EXPECTED_COMMIT" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "release pipeline qualification requires an exact 40-character commit"
  exit 1
fi
if [[ ! "$EXPECTED_PIPELINE_DIGEST" =~ '^[0-9a-f]{64}$' ]]; then
  print -u2 "release pipeline qualification requires an exact pipeline SHA-256 digest"
  exit 1
fi

cd "$ROOT"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
if [[ "$RELEASE_TAG" != "v$VERSION" ]]; then
  print -u2 "release qualification tag input must match Info.plist"
  exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$EXPECTED_COMMIT" ]]; then
  print -u2 "release qualification checkout does not match the expected commit"
  exit 1
fi
REMOTE_HEAD="$(git ls-remote "$QUALIFICATION_REMOTE_NAME" "refs/heads/$BRANCH" | \
  /usr/bin/awk 'NR == 1 { print $1 }')"
if [[ "$REMOTE_HEAD" != "$EXPECTED_COMMIT" ]]; then
  print -u2 "release qualification branch must be pushed and its remote head must match the expected commit"
  exit 1
fi
for command_name in jq "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done
PULLS_JSON="$(
  "$GH_BIN" api \
    "repos/$REPOSITORY/commits/$EXPECTED_COMMIT/pulls" \
    --header 'Accept: application/vnd.github+json'
)"
if ! print -r -- "$PULLS_JSON" | jq -e \
  --arg repository "$REPOSITORY" \
  --arg headSha "$EXPECTED_COMMIT" '
    [.[] | select(
      (.state == "open" or .merged_at != null) and
      .base.ref == "main" and
      .head.sha == $headSha and
      .head.repo.full_name == $repository
    )] | length == 1
  ' >/dev/null; then
  print -u2 "release qualification commit must belong to exactly one same-repository PR targeting main (open or merged)"
  exit 1
fi
if [[ "$(./scripts/release-pipeline-digest.sh)" != "$EXPECTED_PIPELINE_DIGEST" ]]; then
  print -u2 "release qualification pipeline digest does not match the reviewed input"
  exit 1
fi

./scripts/verify-release-timeout-budgets.sh
./scripts/verify-release-dependency-pins.sh

print "PROTECTED RELEASE PIPELINE QUALIFICATION PASS"
print "BRANCH: $BRANCH"
print "COMMIT: $EXPECTED_COMMIT"
print "PIPELINE_DIGEST: $EXPECTED_PIPELINE_DIGEST"
