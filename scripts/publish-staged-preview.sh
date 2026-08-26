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
  .schemaVersion == 3 and .result == "passed" and .mode == "preview" and
  (.sourceCommit | test("^[0-9a-f]{40}$")) and
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
echo "SOURCE_COMMIT: $(jq -r '.sourceCommit' "$ATTESTATION")"
