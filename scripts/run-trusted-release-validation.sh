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
if [[ "$BASE_COMMIT" != "$(git -C "$ROOT" rev-parse origin/main)" ]]; then
  print -u2 "trusted release validation requires candidate parent to equal origin/main"
  exit 1
fi

for script_name in \
  verify-release-metadata-diff.sh \
  verify-preview-branch.sh \
  verify-release-dependency-pins.sh \
  verify-release-ready-main-ci.sh; do
  git -C "$ROOT" show "${BASE_COMMIT}:scripts/$script_name" > "$TRUSTED_DIR/$script_name"
  /bin/chmod 755 "$TRUSTED_DIR/$script_name"
done

REPOSITORY_ROOT="$ROOT" \
  "$TRUSTED_DIR/verify-release-metadata-diff.sh" \
    "$BASE_COMMIT" "$HEAD_COMMIT" "$BRANCH"
REPOSITORY_ROOT="$ROOT" GITHUB_REF_NAME="$BRANCH" \
  "$TRUSTED_DIR/verify-preview-branch.sh"
REPOSITORY_ROOT="$ROOT" \
  "$TRUSTED_DIR/verify-release-dependency-pins.sh"
REPOSITORY_ROOT="$ROOT" \
  "$TRUSTED_DIR/verify-release-ready-main-ci.sh" "$BASE_COMMIT"

print "TRUSTED PARENT RELEASE VALIDATION PASS"
print "BASE_MAIN_COMMIT: $BASE_COMMIT"
print "CANDIDATE_COMMIT: $HEAD_COMMIT"
