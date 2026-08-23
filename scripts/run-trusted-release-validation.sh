#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
BRANCH="${GITHUB_REF_NAME:-$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)}"
HEAD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
BASE_COMMIT="$(git -C "$ROOT" rev-parse HEAD^)"
TRUSTED_DIR="$(/usr/bin/mktemp -d /private/tmp/sayall-trusted-release.XXXXXX)"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 2
fi
git -C "$ROOT" fetch origin main --tags >/dev/null
CURRENT_MAIN_COMMIT="$(git -C "$ROOT" rev-parse origin/main)"
if [[ "$BASE_COMMIT" != "$CURRENT_MAIN_COMMIT" ]]; then
  if [[ "${ALLOW_FROZEN_BASE_MAIN:-0}" != "1" ]] || \
     ! git -C "$ROOT" merge-base --is-ancestor "$BASE_COMMIT" "$CURRENT_MAIN_COMMIT"; then
    print -u2 "trusted release validation requires a current main base or an approved frozen ancestor"
    exit 1
  fi
fi

for script_name in \
  verify-release-metadata-diff.sh \
  verify-preview-branch.sh \
  verify-release-dependency-pins.sh \
  verify-release-ready-main-ci.sh \
  release-pipeline-digest.sh; do
  git -C "$ROOT" show "${BASE_COMMIT}:scripts/$script_name" > "$TRUSTED_DIR/$script_name"
  /bin/chmod 755 "$TRUSTED_DIR/$script_name"
done

if [[ "$BASE_COMMIT" != "$CURRENT_MAIN_COMMIT" ]]; then
  base_pipeline_digest="$(REPOSITORY_ROOT="$ROOT" "$TRUSTED_DIR/release-pipeline-digest.sh" "$BASE_COMMIT")"
  current_pipeline_digest="$(REPOSITORY_ROOT="$ROOT" "$TRUSTED_DIR/release-pipeline-digest.sh" "$CURRENT_MAIN_COMMIT")"
  if [[ "$base_pipeline_digest" != "$current_pipeline_digest" ]]; then
    print -u2 "release-critical pipeline changed after the candidate base; replace the candidate before signing"
    exit 1
  fi
fi

REPOSITORY_ROOT="$ROOT" \
  "$TRUSTED_DIR/verify-release-metadata-diff.sh" \
    "$BASE_COMMIT" "$HEAD_COMMIT" "$BRANCH"
REPOSITORY_ROOT="$ROOT" GITHUB_REF_NAME="$BRANCH" \
  ALLOW_FROZEN_BASE_MAIN="${ALLOW_FROZEN_BASE_MAIN:-0}" \
  "$TRUSTED_DIR/verify-preview-branch.sh"
REPOSITORY_ROOT="$ROOT" \
  "$TRUSTED_DIR/verify-release-dependency-pins.sh"
REPOSITORY_ROOT="$ROOT" ALLOW_FROZEN_BASE_MAIN="${ALLOW_FROZEN_BASE_MAIN:-0}" \
  "$TRUSTED_DIR/verify-release-ready-main-ci.sh" "$BASE_COMMIT"

print "TRUSTED PARENT RELEASE VALIDATION PASS"
print "BASE_MAIN_COMMIT: $BASE_COMMIT"
print "CANDIDATE_COMMIT: $HEAD_COMMIT"
