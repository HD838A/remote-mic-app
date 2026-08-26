#!/bin/zsh
set -euo pipefail

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
BASE_COMMIT="${1:-}"
HEAD_COMMIT="${2:-HEAD}"

[[ "$BASE_COMMIT" =~ '^[0-9a-f]{40}$' ]] || {
  print -u2 "usage: $0 <base-commit> [head-commit]"
  exit 2
}

CONTROL_PLANE_SCRIPTS=(
  scripts/prepare-preview-release.sh
  scripts/stage-macos-preview.sh
  scripts/prepare-public-release-assets.sh
  scripts/verify-preview-cdn-availability.sh
  scripts/verify-staged-release-assets.sh
  scripts/recover-preview-stage.sh
  scripts/publish-staged-preview.sh
  scripts/publish-preview-release.sh
  scripts/promote-preview-release.sh
  scripts/prepare-staged-preview-ui-test.sh
  scripts/record-preview-ui-attestation.sh
  scripts/verify-preview-ui-attestation.sh
  scripts/verify-release-ready-main-ci.sh
  scripts/verify-release-dependency-pins.sh
  scripts/verify-release-workflow-gh-token.sh
  scripts/test-macos-release-flow.sh
  scripts/test-prepare-preview-release.sh
  scripts/verify-release-control-plane-diff.sh
)

control_changed=false
while IFS= read -r changed_path; do
  [[ -n "$changed_path" ]] || continue
  case "$changed_path" in
    *.md|Screenshots/*)
      continue
      ;;
    .github/workflows/mac-release-package.yml|\
    .github/workflows/mac-preview-publication.yml|\
    .github/workflows/mac-stable-promote.yml)
      control_changed=true
      ;;
    .github/workflows/mac-ci.yml)
      print -u2 "mac-ci.yml changes require the full two-architecture CI path"
      exit 1
      ;;
    Tests/RemoteMicTests/BuildSigningTests.swift)
      control_changed=true
      ;;
    *)
      allowed=false
      for control_path in "${CONTROL_PLANE_SCRIPTS[@]}"; do
        if [[ "$changed_path" == "$control_path" ]]; then
          allowed=true
          break
        fi
      done
      if [[ "$allowed" != true ]]; then
        print -u2 "non-control-plane path changed: $changed_path"
        exit 1
      fi
      control_changed=true
      ;;
  esac
done < <(git -C "$ROOT" diff --name-only "$BASE_COMMIT...$HEAD_COMMIT")

[[ "$control_changed" == true ]] || {
  print -u2 "no release control-plane change detected"
  exit 1
}
