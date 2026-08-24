#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
WORKFLOW_FILE="mac-ci.yml"
WORKFLOW_NAME="macOS CI"
GH_BIN="${GH_BIN:-gh}"
MAIN_COMMIT="${1:-}"
PROOF_OUTPUT="${RELEASE_READY_PROOF_OUTPUT:-}"

if [[ "$#" -gt 1 ]]; then
    echo "usage: $0 [main-commit]" >&2
  exit 2
fi
for command_name in git jq "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

cd "$ROOT"
if [[ -z "$MAIN_COMMIT" ]]; then
  MAIN_COMMIT="$(git rev-parse HEAD^)"
fi
if [[ ! "$MAIN_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "release-ready main commit must be a full 40-character SHA" >&2
  exit 1
fi
CURRENT_MAIN_COMMIT="$(git rev-parse origin/main)"
if [[ "$MAIN_COMMIT" != "$CURRENT_MAIN_COMMIT" ]]; then
  if [[ "${ALLOW_FROZEN_BASE_MAIN:-0}" != "1" ]] || \
     ! git merge-base --is-ancestor "$MAIN_COMMIT" "$CURRENT_MAIN_COMMIT"; then
    echo "release candidate base must be the current origin/main or an approved frozen ancestor" >&2
    exit 1
  fi
fi

find_successful_main_run_id() {
  local commit="$1"
  "$GH_BIN" run list \
    --repo "$REPOSITORY" \
    --workflow "$WORKFLOW_FILE" \
    --branch main \
    --commit "$commit" \
    --event push \
    --status success \
    --limit 20 \
    --json databaseId,headSha,headBranch,event,status,conclusion \
    --jq '.[0].databaseId // empty'
}

load_main_run_json() {
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
  --arg headSha "$commit" '
    .workflowName == $workflow and
    .event == "push" and
    .status == "completed" and
    .conclusion == "success" and
    .headBranch == "main" and
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
    --arg headSha "$commit" '
      .workflowName == $workflow and
      .event == "push" and
      .status == "completed" and
      .conclusion == "success" and
      .headBranch == "main" and
      .headSha == $headSha and
      ([.jobs[] | select(
        .name == "Release control-plane tests" and
        .status == "completed" and .conclusion == "success" and
        ([.steps[] | select(
          .name == "Run recovery control-plane tests" and .conclusion == "success"
        )] | length) == 1
      )] | length) == 1
    ' >/dev/null
}

RUN_ID="$(find_successful_main_run_id "$MAIN_COMMIT")"
if [[ -z "$RUN_ID" || ! "$RUN_ID" =~ ^[0-9]+$ ]]; then
  echo "candidate base main has no successful macOS CI push run: $MAIN_COMMIT" >&2
  exit 1
fi
RUN_JSON="$(load_main_run_json "$RUN_ID")"

PRODUCT_PROOF_COMMIT="$MAIN_COMMIT"
PRODUCT_CI_RUN_ID="$RUN_ID"
PRODUCT_RUN_JSON="$RUN_JSON"
if ! is_full_product_run "$RUN_JSON" "$MAIN_COMMIT"; then
  if ! is_control_plane_run "$RUN_JSON" "$MAIN_COMMIT"; then
    echo "main CI run $RUN_ID is neither a full product run nor a control-plane-only run" >&2
    exit 1
  fi

  PRODUCT_PROOF_COMMIT=""
  PRODUCT_CI_RUN_ID=""
  PRODUCT_RUN_JSON=""
  while IFS= read -r ancestor_commit; do
    ancestor_run_id="$(find_successful_main_run_id "$ancestor_commit")"
    [[ "$ancestor_run_id" =~ ^[0-9]+$ ]] || continue
    ancestor_run_json="$(load_main_run_json "$ancestor_run_id")"
    if is_full_product_run "$ancestor_run_json" "$ancestor_commit"; then
      PRODUCT_PROOF_COMMIT="$ancestor_commit"
      PRODUCT_CI_RUN_ID="$ancestor_run_id"
      PRODUCT_RUN_JSON="$ancestor_run_json"
      break
    fi
  done < <(git rev-list --first-parent --skip=1 --max-count=50 "$MAIN_COMMIT")

  if [[ -z "$PRODUCT_PROOF_COMMIT" ]]; then
    echo "control-plane main has no recent first-parent full two-architecture product proof" >&2
    exit 1
  fi
  if ! "$ROOT/scripts/verify-release-control-plane-diff.sh" \
      "$PRODUCT_PROOF_COMMIT" "$MAIN_COMMIT"; then
    echo "main changes after the inherited product proof are not control-plane-only" >&2
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
    --arg candidateCommit "$(git rev-parse HEAD)" \
    --arg baseMainCommit "$MAIN_COMMIT" \
    --argjson mainCiRunId "$RUN_ID" \
    --arg mainCiRunUrl "$(printf '%s\n' "$RUN_JSON" | jq -r '.url')" \
    --arg mainCiCompletedAt "$(printf '%s\n' "$RUN_JSON" | jq -r '.updatedAt')" \
    --arg productProofCommit "$PRODUCT_PROOF_COMMIT" \
    --argjson productCiRunId "$PRODUCT_CI_RUN_ID" \
    --arg productCiRunUrl "$(printf '%s\n' "$PRODUCT_RUN_JSON" | jq -r '.url')" \
    '{
      schemaVersion: 1,
      repository: $repository,
      candidateCommit: $candidateCommit,
      baseMainCommit: $baseMainCommit,
      reusedChecks: ["Apple Silicon", "Intel Ventura"],
      mainCiRunId: $mainCiRunId,
      mainCiRunUrl: $mainCiRunUrl,
      mainCiCompletedAt: $mainCiCompletedAt,
      productProofCommit: $productProofCommit,
      productCiRunId: $productCiRunId,
      productCiRunUrl: $productCiRunUrl
    }' > "$PROOF_OUTPUT"
fi

echo "RELEASE-READY MAIN CI PASS"
echo "MAIN_COMMIT: $MAIN_COMMIT"
echo "MAIN_CI_RUN_ID: $RUN_ID"
echo "MAIN_CI_RUN_URL: $(printf '%s\n' "$RUN_JSON" | jq -r '.url')"
echo "PRODUCT_PROOF_COMMIT: $PRODUCT_PROOF_COMMIT"
echo "PRODUCT_CI_RUN_ID: $PRODUCT_CI_RUN_ID"
echo "PRODUCT_CI_RUN_URL: $(printf '%s\n' "$PRODUCT_RUN_JSON" | jq -r '.url')"
