#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
WORKFLOW_FILE="mac-ci.yml"
WORKFLOW_NAME="macOS CI"
GH_BIN="${GH_BIN:-gh}"
SOURCE_COMMIT="${1:-}"
SOURCE_BRANCH="${2:-$(git -C "$ROOT" branch --show-current 2>/dev/null || true)}"
PROOF_OUTPUT="${RELEASE_READY_PROOF_OUTPUT:-}"
CONTROL_PLANE_DIFF_BIN="${RELEASE_CONTROL_PLANE_DIFF_BIN:-$ROOT/scripts/verify-release-control-plane-diff.sh}"

[[ "$REPOSITORY" == "HD838A/remote-mic-app" ]] || {
  echo "Release source CI verification is restricted to HD838A/remote-mic-app" >&2
  exit 1
}

if [[ "$#" -gt 2 ]]; then
    echo "usage: $0 [source-commit] [main|hotfix/vX.Y.Z]" >&2
  exit 2
fi
for command_name in git jq "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

cd "$ROOT"
if [[ -z "$SOURCE_COMMIT" ]]; then
  SOURCE_COMMIT="$(git rev-parse HEAD)"
fi
if [[ ! "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "release-ready source commit must be a full 40-character SHA" >&2
  exit 1
fi
[[ "$SOURCE_BRANCH" == main || "$SOURCE_BRANCH" =~ ^hotfix/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "release-ready CI accepts only main or hotfix/vX.Y.Z" >&2
  exit 1
}
git fetch --no-tags origin "$SOURCE_BRANCH"
CURRENT_SOURCE_COMMIT="$(git rev-parse "origin/$SOURCE_BRANCH")"
if [[ "$SOURCE_COMMIT" != "$CURRENT_SOURCE_COMMIT" ]]; then
  if [[ "${ALLOW_FROZEN_BASE_MAIN:-0}" != "1" ]] || \
     ! git merge-base --is-ancestor "$SOURCE_COMMIT" "$CURRENT_SOURCE_COMMIT"; then
    echo "release candidate must be the current source branch head or an approved frozen ancestor" >&2
    exit 1
  fi
fi

find_successful_source_run_id() {
  local commit="$1"
  local event_filter='map(select(.event == "push"))[0].databaseId // empty'
  if [[ "$SOURCE_BRANCH" != main ]]; then
    event_filter='map(select(.event == "push" or .event == "workflow_dispatch"))[0].databaseId // empty'
  fi
  "$GH_BIN" run list \
    --repo "$REPOSITORY" \
    --workflow "$WORKFLOW_FILE" \
    --branch "$SOURCE_BRANCH" \
    --commit "$commit" \
    --status success \
    --limit 20 \
    --json databaseId,headSha,headBranch,event,status,conclusion \
    --jq "$event_filter"
}

load_source_run_json() {
  local run_id="$1"
  "$GH_BIN" run view "$run_id" \
    --repo "$REPOSITORY" \
    --json workflowName,event,status,conclusion,headBranch,headSha,jobs,url,updatedAt
}

is_full_product_run() {
  local run_json="$1"
  local commit="$2"
  printf '%s\n' "$run_json" | jq -e \
  --arg workflow "$WORKFLOW_NAME" \
  --arg headBranch "$SOURCE_BRANCH" \
  --arg headSha "$commit" '
    .workflowName == $workflow and
    (($headBranch == "main" and .event == "push") or
     ($headBranch != "main" and (.event == "push" or .event == "workflow_dispatch"))) and
    .status == "completed" and
    .conclusion == "success" and
    .headBranch == $headBranch and
    .headSha == $headSha and
    ([.jobs[] | select(
      .name == "Swift tests and build (Apple Silicon)" and
      .status == "completed" and .conclusion == "success" and
      ([.steps[] | select(.name == "Run Swift tests" and .conclusion == "success")] | length) == 1 and
      ([.steps[] | select(.name == "Run project self-test" and .conclusion == "success")] | length) == 1 and
      ([.steps[] | select(.name == "Build release configuration" and .conclusion == "success")] | length) == 1
    )] | length) == 1 and
    ([.jobs[] | select(
      .name == "Swift tests and build (Intel Ventura)" and
      .status == "completed" and .conclusion == "success" and
      ([.steps[] | select(.name == "Run Swift tests" and .conclusion == "success")] | length) == 1 and
      ([.steps[] | select(.name == "Run project self-test" and .conclusion == "success")] | length) == 1 and
      ([.steps[] | select(.name == "Build release configuration" and .conclusion == "success")] | length) == 1
    )] | length) == 1
  ' >/dev/null
}

is_control_plane_run() {
  local run_json="$1"
  local commit="$2"
  printf '%s\n' "$run_json" | jq -e \
    --arg workflow "$WORKFLOW_NAME" \
    --arg headBranch "$SOURCE_BRANCH" \
    --arg headSha "$commit" '
      .workflowName == $workflow and
      (($headBranch == "main" and .event == "push") or
       ($headBranch != "main" and (.event == "push" or .event == "workflow_dispatch"))) and
      .status == "completed" and
      .conclusion == "success" and
      .headBranch == $headBranch and
      .headSha == $headSha and
      ([.jobs[] | select(
        .name == "Swift tests and build (Apple Silicon)" and
        .status == "completed" and .conclusion == "success" and
        ([.steps[] | select(.name == "Run release control-plane fixture" and .conclusion == "success")] | length) == 1
      )] | length) == 1 and
      ([.jobs[] | select(
        .name == "Swift tests and build (Intel Ventura)" and
        .status == "completed" and .conclusion == "success" and
        ([.steps[] | select(.name == "Run release control-plane fixture" and .conclusion == "success")] | length) == 1
      )] | length) == 1
    ' >/dev/null
}

RUN_ID="$(find_successful_source_run_id "$SOURCE_COMMIT")"
if [[ -z "$RUN_ID" || ! "$RUN_ID" =~ ^[0-9]+$ ]]; then
  echo "release source has no eligible successful macOS CI run: $SOURCE_BRANCH $SOURCE_COMMIT" >&2
  exit 1
fi
RUN_JSON="$(load_source_run_json "$RUN_ID")"

PRODUCT_PROOF_COMMIT="$SOURCE_COMMIT"
PRODUCT_CI_RUN_ID="$RUN_ID"
PRODUCT_RUN_JSON="$RUN_JSON"
if ! is_full_product_run "$RUN_JSON" "$SOURCE_COMMIT"; then
  if ! is_control_plane_run "$RUN_JSON" "$SOURCE_COMMIT"; then
    echo "source-branch CI run $RUN_ID is neither a full product run nor a control-plane-only run" >&2
    exit 1
  fi

  PRODUCT_PROOF_COMMIT=""
  PRODUCT_CI_RUN_ID=""
  PRODUCT_RUN_JSON=""
  while IFS= read -r ancestor_commit; do
    ancestor_run_id="$(find_successful_source_run_id "$ancestor_commit")"
    [[ "$ancestor_run_id" =~ ^[0-9]+$ ]] || continue
    ancestor_run_json="$(load_source_run_json "$ancestor_run_id")"
    if is_full_product_run "$ancestor_run_json" "$ancestor_commit"; then
      PRODUCT_PROOF_COMMIT="$ancestor_commit"
      PRODUCT_CI_RUN_ID="$ancestor_run_id"
      PRODUCT_RUN_JSON="$ancestor_run_json"
      break
    fi
  done < <(git rev-list --first-parent --skip=1 --max-count=50 "$SOURCE_COMMIT")

  if [[ -z "$PRODUCT_PROOF_COMMIT" ]]; then
    echo "control-plane-only source has no recent first-parent full two-architecture product proof on the same branch" >&2
    exit 1
  fi
  if ! "$CONTROL_PLANE_DIFF_BIN" \
      "$PRODUCT_PROOF_COMMIT" "$SOURCE_COMMIT"; then
    echo "source changes after the inherited product proof are not control-plane-only" >&2
    exit 1
  fi
fi

if ! is_full_product_run "$PRODUCT_RUN_JSON" "$PRODUCT_PROOF_COMMIT"; then
  echo "product CI run $PRODUCT_CI_RUN_ID is not an exact-SHA successful two-architecture push run" >&2
  exit 1
fi

if [[ -n "$PROOF_OUTPUT" ]]; then
  /bin/mkdir -p "$(dirname "$PROOF_OUTPUT")"
  jq -n \
    --arg repository "$REPOSITORY" \
    --arg candidateCommit "$SOURCE_COMMIT" \
    --arg sourceBranch "$SOURCE_BRANCH" \
    --argjson sourceCiRunId "$RUN_ID" \
    --arg sourceCiRunUrl "$(printf '%s\n' "$RUN_JSON" | jq -r '.url')" \
    --arg sourceCiCompletedAt "$(printf '%s\n' "$RUN_JSON" | jq -r '.updatedAt')" \
    --arg productProofCommit "$PRODUCT_PROOF_COMMIT" \
    --argjson productCiRunId "$PRODUCT_CI_RUN_ID" \
    --arg productCiRunUrl "$(printf '%s\n' "$PRODUCT_RUN_JSON" | jq -r '.url')" \
    '{
      schemaVersion: 1,
      repository: $repository,
      candidateCommit: $candidateCommit,
      sourceBranch: $sourceBranch,
      reusedChecks: ["Apple Silicon", "Intel Ventura"],
      sourceCiRunId: $sourceCiRunId,
      sourceCiRunUrl: $sourceCiRunUrl,
      sourceCiCompletedAt: $sourceCiCompletedAt,
      productProofCommit: $productProofCommit,
      productCiRunId: $productCiRunId,
      productCiRunUrl: $productCiRunUrl
    }' > "$PROOF_OUTPUT"
fi

echo "RELEASE-READY SOURCE CI PASS"
echo "SOURCE_BRANCH: $SOURCE_BRANCH"
echo "SOURCE_COMMIT: $SOURCE_COMMIT"
echo "SOURCE_CI_RUN_ID: $RUN_ID"
echo "SOURCE_CI_RUN_URL: $(printf '%s\n' "$RUN_JSON" | jq -r '.url')"
echo "PRODUCT_PROOF_COMMIT: $PRODUCT_PROOF_COMMIT"
echo "PRODUCT_CI_RUN_ID: $PRODUCT_CI_RUN_ID"
echo "PRODUCT_CI_RUN_URL: $(printf '%s\n' "$PRODUCT_RUN_JSON" | jq -r '.url')"
