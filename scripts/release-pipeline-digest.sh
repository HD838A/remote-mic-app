#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 2
fi

PIPELINE_FILES=(
  .github/workflows/mac-release-package.yml
  .github/workflows/mac-preview-candidate.yml
  .github/workflows/mac-ci.yml
  .github/workflows/mac-stable-promote.yml
  scripts/build-app.sh
  scripts/build-dmg.sh
  scripts/build-doubao-driver.sh
  scripts/build-doubao-driver-pkg.sh
  scripts/notarize-release.sh
  scripts/package-macos-release-in-actions.sh
  scripts/package-macos-release-variants.sh
  scripts/prepare-preview-recording-pr.sh
  scripts/publish-release.sh
  scripts/release-pipeline-digest.sh
  scripts/run-release-stage.sh
  scripts/release-slo-ledger.sh
  scripts/release-user-wall-watchdog.sh
  scripts/resolve-release-request-attestation.sh
  scripts/run-trusted-release-validation.sh
  scripts/verify-release-dependency-pins.sh
  scripts/verify-release-metadata-diff.sh
  scripts/verify-release-ready-main-ci.sh
  scripts/verify-release-canary-provenance.sh
  scripts/verify-release-timeout-budgets.sh
  scripts/verify-preview-branch.sh
  scripts/verify-preview-candidate-ci.sh
)

for relative_path in "${PIPELINE_FILES[@]}"; do
  [[ -r "$ROOT/$relative_path" ]] || {
    print -u2 "release pipeline file is unreadable: $relative_path"
    exit 1
  }
done

(
  cd "$ROOT"
  for relative_path in "${PIPELINE_FILES[@]}"; do
    /usr/bin/shasum -a 256 "$relative_path"
  done
) | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
