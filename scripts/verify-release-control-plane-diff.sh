#!/usr/bin/env bash
set -euo pipefail

ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CLASSIFY=0
REQUIRE_METADATA=0
case "${1:-}" in
  --classify)
    CLASSIFY=1
    shift
    ;;
  --require-release-metadata-only)
    REQUIRE_METADATA=1
    shift
    ;;
esac
BASE_COMMIT="${1:-}"
HEAD_COMMIT="${2:-HEAD}"
[[ "$#" -le 2 && "$BASE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "usage: $0 [--classify|--require-release-metadata-only] <base-commit> [head-commit]" >&2
  exit 2
}

# A release metadata PR may only change the two version keys in Info.plist and
# documentation. Compare the plist semantically so a formatting rewrite, another
# product key, or a dependency change can never enter this fast path.
info_plist_version_build_only() {
  python3 - "$ROOT" "$BASE_COMMIT" "$HEAD_COMMIT" <<'PY'
import plistlib
import subprocess
import sys

root, base_rev, head_rev = sys.argv[1:4]
keys = ("CFBundleShortVersionString", "CFBundleVersion")


def load(revision):
    data = subprocess.check_output(
        ["git", "-C", root, "show", f"{revision}:Resources/Info.plist"],
        stderr=subprocess.DEVNULL,
    )
    value = plistlib.loads(data)
    if not isinstance(value, dict):
        raise ValueError("Info.plist root is not a dictionary")
    return value


try:
    base = load(base_rev)
    head = load(head_rev)
except Exception:
    sys.exit(1)

if any(key not in base or key not in head for key in keys):
    sys.exit(1)
if not any(base[key] != head[key] for key in keys):
    sys.exit(1)
for key in keys:
    base.pop(key, None)
    head.pop(key, None)
sys.exit(0 if base == head else 1)
PY
}

# CI and release-proof reuse consume this one fail-closed classification.
changed=false
docs_only=true
control_only=true
tooling_only=true
repository_only=true
release_checks=false
release_metadata_only=true
info_plist_metadata=false
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
      release_metadata_only=false
      continue
      ;;
    scripts/verify-repository-governance.sh|.github/workflows/repository-governance.yml)
      docs_only=false
      tooling_only=false
      control_only=false
      release_metadata_only=false
      continue
      ;;
    Resources/Info.plist)
      docs_only=false
      tooling_only=false
      repository_only=false
      control_only=false
      release_checks=true
      if info_plist_version_build_only; then
        info_plist_metadata=true
      else
        release_metadata_only=false
      fi
      continue
      ;;
  esac
  docs_only=false
  tooling_only=false
  repository_only=false
  release_metadata_only=false
  case "$changed_path" in
    .github/workflows/mac-release-package.yml|\
    .github/workflows/mac-preview-publication.yml|\
    .github/workflows/mac-stable-promote.yml|\
    scripts/prepare-preview-release.sh|scripts/stage-macos-preview.sh|\
    config/release-assets.json|scripts/release-assets.py|\
    scripts/test-private-platform.py|scripts/run-release-stage.sh|scripts/verify-release-contents.py|\
    scripts/prepare-public-release-assets.sh|scripts/verify-preview-cdn-availability.sh|\
    scripts/verify-staged-release-assets.sh|scripts/recover-preview-stage.sh|\
    scripts/verify-release-asset-source.sh|\
    scripts/publish-staged-preview.sh|scripts/publish-preview-release.sh|\
    scripts/promote-preview-release.sh|scripts/prepare-staged-preview-ui-test.sh|\
    scripts/record-preview-ui-attestation.sh|scripts/verify-release-ready-main-ci.sh|\
    scripts/verify-release-dependency-pins.sh|scripts/test-macos-release-flow.sh|\
    scripts/test-verify-release-asset-source.sh|scripts/verify-release-metadata.sh|\
    scripts/verify-preview-ui-assets.sh|\
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
  release_metadata_only=false
elif [[ "$docs_only" == true ]]; then
  control_only=false
  tooling_only=false
  repository_only=false
  release_metadata_only=false
elif [[ "$tooling_only" == true ]]; then
  control_only=false
  repository_only=false
  release_metadata_only=false
elif [[ "$repository_only" == true ]]; then
  control_only=false
  tooling_only=false
  release_metadata_only=false
elif [[ "$control_only" == true ]]; then
  tooling_only=false
  release_metadata_only=false
fi

if [[ "$release_metadata_only" == true && "$info_plist_metadata" != true ]]; then
  release_metadata_only=false
fi
if [[ "$release_metadata_only" == true ]]; then
  docs_only=false
  tooling_only=false
  repository_only=false
  control_only=false
  release_checks=true
fi

product_change=true
if [[ "$docs_only" == true || "$control_only" == true || "$tooling_only" == true ||
      "$repository_only" == true || "$release_metadata_only" == true ]]; then
  product_change=false
fi

if (( CLASSIFY == 1 )); then
  printf '%s\n' "docs_only=$docs_only" "release_control_plane_only=$control_only" \
    "tooling_only=$tooling_only" "repository_only=$repository_only" \
    "release_metadata_only=$release_metadata_only" \
    "product_change=$product_change" "release_checks=$release_checks"
elif (( REQUIRE_METADATA == 1 )); then
  [[ "$release_metadata_only" == true && "$product_change" == false ]] || {
    echo "source diff is not release-metadata-only" >&2
    exit 1
  }
elif [[ "$control_only" != true ]]; then
  echo "source diff is not release-control-plane-only" >&2
  exit 1
fi
