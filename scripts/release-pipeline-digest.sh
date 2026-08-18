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
  scripts/build-app.sh
  scripts/build-dmg.sh
  scripts/build-doubao-driver.sh
  scripts/build-doubao-driver-pkg.sh
  scripts/notarize-release.sh
  scripts/package-macos-release-in-actions.sh
  scripts/package-macos-release-variants.sh
  scripts/release-pipeline-digest.sh
  scripts/run-release-stage.sh
  scripts/verify-release-canary-provenance.sh
  scripts/verify-release-timeout-budgets.sh
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
