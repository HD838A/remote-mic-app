#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
WORKFLOW_FILE="mac-preview-publication.yml"
ATTESTATION="${1:-}"
PUBLICATION_MODE="${2:-prerelease}"

if [[ "$#" -lt 1 || "$#" -gt 2 || ! -r "$ATTESTATION" ]]; then
  print -u2 "usage: $0 <preview-ui-attestation.json> [draft|prerelease]"
  exit 2
fi
[[ "$PUBLICATION_MODE" == draft || "$PUBLICATION_MODE" == prerelease ]] || {
  print -u2 "publication mode must be draft or prerelease"
  exit 2
}
for command_name in git jq base64 "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || { print -u2 "Missing required command: $command_name"; exit 1; }
done

tag="$(jq -r '.tag' "$ATTESTATION")"
branch="$(jq -r '.candidateBranch' "$ATTESTATION")"
commit="$(jq -r '.candidateCommit' "$ATTESTATION")"
pipeline_digest="$(jq -r '.pipelineDigest' "$ATTESTATION")"
request_id="$(jq -r '.requestId' "$ATTESTATION")"
request_started_at="$(jq -r '.requestStartedAt // empty' "$ATTESTATION")"
source_run_id="$(jq -r '.sourceRunId' "$ATTESTATION")"
source_run_attempt="$(jq -r '.sourceRunAttempt' "$ATTESTATION")"
source_artifact_id="$(jq -r '.signedArtifactId' "$ATTESTATION")"
source_artifact_digest="$(jq -r '.signedArtifactDigest' "$ATTESTATION")"

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$branch" == "release/pre-$tag" ]]
[[ "$commit" =~ ^[0-9a-f]{40}$ && "$pipeline_digest" =~ ^[0-9a-f]{64}$ ]]
[[ "$request_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$ ]]
[[ "$request_started_at" =~ ^[0-9]+$ ]]
[[ "$source_run_id" =~ ^[1-9][0-9]*$ && "$source_run_attempt" =~ ^[1-9][0-9]*$ ]]
[[ "$source_artifact_id" =~ ^[1-9][0-9]*$ && "$source_artifact_digest" =~ ^sha256:[0-9a-f]{64}$ ]]

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || { print -u2 "publication dispatch requires a clean worktree"; exit 1; }
test "$(git branch --show-current)" = "$branch"
test "$(git rev-parse HEAD)" = "$commit"
test "$(git ls-remote origin "refs/heads/$branch" | awk 'NR == 1 {print $1}')" = "$commit"
test "$(./scripts/release-pipeline-digest.sh)" = "$pipeline_digest"

ui_attestation_b64="$(base64 < "$ATTESTATION" | tr -d '\n')"
[[ ${#ui_attestation_b64} -le 60000 ]] || { print -u2 "UI attestation exceeds workflow input limit"; exit 1; }

$GH_BIN workflow run "$WORKFLOW_FILE" --repo "$REPOSITORY" --ref main \
  --raw-field "publication_mode=$PUBLICATION_MODE" \
  --raw-field "tag=$tag" \
  --raw-field "expected_commit=$commit" \
  --raw-field "expected_pipeline_digest=$pipeline_digest" \
  --raw-field "request_started_at=$request_started_at" \
  --raw-field "request_id=$request_id" \
  --raw-field "source_run_id=$source_run_id" \
  --raw-field "source_run_attempt=$source_run_attempt" \
  --raw-field "source_artifact_id=$source_artifact_id" \
  --raw-field "source_artifact_digest=$source_artifact_digest" \
  --raw-field "ui_attestation_b64=$ui_attestation_b64"

print "PUBLISH STAGED PREVIEW DISPATCHED: $PUBLICATION_MODE $tag at $commit"
