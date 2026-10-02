#!/usr/bin/env bash
set -euo pipefail

ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CLASSIFY=0
if [[ "${1:-}" == --classify ]]; then
  CLASSIFY=1
  shift
fi
BASE_COMMIT="${1:-}"
HEAD_COMMIT="${2:-HEAD}"
[[ "$#" -le 2 && "$BASE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "usage: $0 [--classify] <base-commit> [head-commit]" >&2
  exit 2
}

# CI and release-proof reuse consume this one fail-closed classification.
changed=false
docs_only=true
control_only=true
tooling_only=true
repository_only=true
release_checks=false
# Capture first so an invalid diff fails closed instead of hiding in a subprocess.
changed_paths="$(git -C "$ROOT" diff --name-only "$BASE_COMMIT...$HEAD_COMMIT")"
while IFS= read -r changed_path; do
  [[ -n "$changed_path" ]] || continue
  changed=true
  case "$changed_path" in
    *.md|Screenshots/*) continue ;;
    script/build_and_run.sh)
      docs_only=false
      repository_only=false
      continue
      ;;
    scripts/verify-repository-governance.sh|.github/workflows/repository-governance.yml)
      docs_only=false
      tooling_only=false
      control_only=false
      continue
      ;;
  esac
  docs_only=false
  tooling_only=false
  repository_only=false
  case "$changed_path" in
    .github/workflows/mac-release-package.yml|\
    .github/workflows/mac-preview-publication.yml|\
    .github/workflows/mac-stable-promote.yml|\
    scripts/prepare-preview-release.sh|scripts/stage-macos-preview.sh|\
    scripts/prepare-public-release-assets.sh|scripts/verify-preview-cdn-availability.sh|\
    scripts/verify-staged-release-assets.sh|scripts/recover-preview-stage.sh|\
    scripts/publish-staged-preview.sh|scripts/publish-preview-release.sh|\
    scripts/promote-preview-release.sh|scripts/prepare-staged-preview-ui-test.sh|\
    scripts/record-preview-ui-attestation.sh|scripts/verify-release-ready-main-ci.sh|\
    scripts/verify-release-dependency-pins.sh|scripts/test-macos-release-flow.sh|\
    Tests/RemoteMicTests/BuildSigningTests.swift)
      release_checks=true
      ;;
    *)
      control_only=false
      case "$changed_path" in
        scripts/*|.github/workflows/*|packaging/*|Resources/*|Package.swift|Package.resolved|\
        config/release-dependencies.json|Sources/RemoteMic/BridgeAppModel.swift|\
        Sources/RemoteMic/MacroFeatureIntegration.swift|Sources/RemoteMic/RemoteMicApp.swift|\
        Sources/RemoteMic/TranscriptHistorySection.swift)
          release_checks=true
          ;;
      esac
      ;;
  esac
done <<< "$changed_paths"

if [[ "$changed" != true ]]; then
  docs_only=false
  control_only=false
  tooling_only=false
  repository_only=false
  release_checks=true
elif [[ "$docs_only" == true ]]; then
  control_only=false
  tooling_only=false
  repository_only=false
elif [[ "$tooling_only" == true ]]; then
  control_only=false
  repository_only=false
elif [[ "$repository_only" == true ]]; then
  control_only=false
  tooling_only=false
elif [[ "$control_only" == true ]]; then
  tooling_only=false
fi
product_change=true
if [[ "$docs_only" == true || "$control_only" == true || "$tooling_only" == true || "$repository_only" == true ]]; then
  product_change=false
fi
if (( CLASSIFY == 1 )); then
  printf '%s\n' "docs_only=$docs_only" "release_control_plane_only=$control_only" \
    "tooling_only=$tooling_only" "repository_only=$repository_only" \
    "product_change=$product_change" "release_checks=$release_checks"
elif [[ "$control_only" != true ]]; then
  echo "source diff is not release-control-plane-only" >&2
  exit 1
fi
