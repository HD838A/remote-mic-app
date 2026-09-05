#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
WORKFLOW_FILE="mac-preview-publication.yml"
ATTESTATION="${1:-}"

if [[ "$#" -ne 1 || ! -r "$ATTESTATION" ]]; then
  echo "usage: $0 <preview-ui-attestation.json>" >&2
  exit 2
fi
for command_name in git jq base64 "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

jq -e '
  .schemaVersion == 4 and .result == "passed" and .mode == "preview" and
  (.sourceBranch == "main" or (.sourceBranch | test("^hotfix/v[0-9]+[.][0-9]+[.][0-9]+$"))) and
  (.sourceKind == "main" or .sourceKind == "hotfix") and
  (.sourceCommit | test("^[0-9a-f]{40}$")) and
  (.sourceWorkflowCommit | test("^[0-9a-f]{40}$")) and
  ((.sourceKind == "main" and .sourceBranch == "main" and .sourceBaseTag == "" and .sourceBaseCommit == "") or
   (.sourceKind == "hotfix" and .sourceBranch == ("hotfix/" + .tag) and
    (.sourceBaseTag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
    (.sourceBaseCommit | test("^[0-9a-f]{40}$")))) and
  (.sourceRunId | type == "number" and . > 0) and
  (.sourceRunAttempt | type == "number" and . > 0) and
  (.signedArtifactId | type == "number" and . > 0) and
  (.signedArtifactDigest | test("^sha256:[0-9a-f]{64}$")) and
  (.assetManifestSHA256 | test("^[0-9a-f]{64}$"))
' "$ATTESTATION" >/dev/null || {
  echo "preview UI attestation is invalid" >&2
  exit 1
}

[[ "$REPOSITORY" == "HD838A/remote-mic-app" ]] || {
  echo "Preview publication is restricted to HD838A/remote-mic-app" >&2
  exit 1
}

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || {
  echo "publication dispatch requires a clean worktree" >&2
  exit 1
}
git fetch --no-tags origin main
[[ "$(git branch --show-current)" == main &&
    "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || {
  echo "publication dispatch must run from exact origin/main" >&2
  exit 1
}

source_branch="$(jq -r '.sourceBranch' "$ATTESTATION")"
source_commit="$(jq -r '.sourceCommit' "$ATTESTATION")"
source_version="$(jq -r '.target.version' "$ATTESTATION")"
RELEASE_SOURCE_CHECKOUT_MODE=none \
RELEASE_SOURCE_REMOTE_MODE=published \
RELEASE_SOURCE_EXPECTED_BASE_TAG="$(jq -r '.sourceBaseTag' "$ATTESTATION")" \
RELEASE_SOURCE_EXPECTED_BASE_COMMIT="$(jq -r '.sourceBaseCommit' "$ATTESTATION")" \
GITHUB_REPOSITORY="$REPOSITORY" GH_BIN="$GH_BIN" \
  "$ROOT/scripts/verify-public-release-source.sh" \
  "$source_branch" "$source_commit" "$source_version" >/dev/null

ui_attestation_b64="$(/usr/bin/base64 < "$ATTESTATION" | /usr/bin/tr -d '\n')"
[[ "${#ui_attestation_b64}" -le 60000 ]] || {
  echo "UI attestation exceeds the workflow input limit" >&2
  exit 1
}

$GH_BIN workflow run "$WORKFLOW_FILE" --repo "$REPOSITORY" --ref main \
  --raw-field "source_run_id=$(jq -r '.sourceRunId' "$ATTESTATION")" \
  --raw-field "ui_attestation_b64=$ui_attestation_b64"

echo "PREVIEW PUBLICATION DISPATCHED"
echo "TAG: $(jq -r '.tag' "$ATTESTATION")"
echo "SOURCE_BRANCH: $source_branch"
echo "SOURCE_COMMIT: $(jq -r '.sourceCommit' "$ATTESTATION")"
