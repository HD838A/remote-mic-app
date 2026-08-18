#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BRANCH="${GITHUB_REF_NAME:-}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:-}"
EXPECTED_PIPELINE_DIGEST="${EXPECTED_PIPELINE_DIGEST:-}"
RELEASE_TAG="${RELEASE_TAG:-}"
CANARY_REMOTE_NAME="${CANARY_REMOTE_NAME:-origin}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 2
fi
if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)" || {
    print -u2 "release canary requires a named branch"
    exit 1
  }
fi
if [[ ! "$BRANCH" =~ '^release/pre-v([0-9]+\.[0-9]+\.[0-9]+)-canary-[a-z0-9][a-z0-9._-]*$' ]]; then
  print -u2 "release canary branch must match release/pre-vX.Y.Z-canary-name"
  exit 1
fi
BRANCH_VERSION="${match[1]}"
if [[ ! "$EXPECTED_COMMIT" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "release canary requires an exact 40-character commit"
  exit 1
fi
if [[ ! "$EXPECTED_PIPELINE_DIGEST" =~ '^[0-9a-f]{64}$' ]]; then
  print -u2 "release canary requires an exact pipeline SHA-256 digest"
  exit 1
fi

cd "$ROOT"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
if [[ "$VERSION" != "$BRANCH_VERSION" || "$RELEASE_TAG" != "v$VERSION" ]]; then
  print -u2 "release canary branch, tag input, and Info.plist version must agree"
  exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$EXPECTED_COMMIT" ]]; then
  print -u2 "release canary checkout does not match the expected commit"
  exit 1
fi
REMOTE_HEAD="$(git ls-remote "$CANARY_REMOTE_NAME" "refs/heads/$BRANCH" | \
  /usr/bin/awk 'NR == 1 { print $1 }')"
if [[ "$REMOTE_HEAD" != "$EXPECTED_COMMIT" ]]; then
  print -u2 "release canary branch must be pushed and its remote head must match the expected commit"
  exit 1
fi
if [[ "$(./scripts/release-pipeline-digest.sh)" != "$EXPECTED_PIPELINE_DIGEST" ]]; then
  print -u2 "release canary pipeline digest does not match the reviewed input"
  exit 1
fi

./scripts/verify-release-timeout-budgets.sh
./scripts/verify-release-dependency-pins.sh

print "PROTECTED RELEASE CANARY PROVENANCE PASS"
print "BRANCH: $BRANCH"
print "COMMIT: $EXPECTED_COMMIT"
print "PIPELINE DIGEST: $EXPECTED_PIPELINE_DIGEST"
