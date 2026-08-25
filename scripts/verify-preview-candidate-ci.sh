#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
WORKFLOW_FILE="mac-preview-candidate.yml"
WORKFLOW_NAME="macOS Preview Candidate"
WORKFLOW_PATH=".github/workflows/mac-preview-candidate.yml"
PR_WORKFLOW_NAME="macOS CI"
PR_WORKFLOW_PATH=".github/workflows/mac-ci.yml"
GH_BIN="${GH_BIN:-gh}"
RUN_ID="${1:-}"
REQUIRE_PREVIEW_RECORDING_PR="${REQUIRE_PREVIEW_RECORDING_PR:-0}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:-}"

if [[ "$#" -gt 1 ]]; then
  print -u2 "usage: $0 [preview-run-id]"
  exit 1
fi
case "$REQUIRE_PREVIEW_RECORDING_PR" in
  0|1) ;;
  *) print -u2 "REQUIRE_PREVIEW_RECORDING_PR must be 0 or 1"; exit 1 ;;
esac
for command_name in git jq "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

cd "$ROOT"
BRANCH="${GITHUB_REF_NAME:-}"
if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git symbolic-ref --quiet --short HEAD)" || {
    print -u2 "candidate CI verification requires a branch"
    exit 1
  }
fi
if [[ ! "$BRANCH" =~ '^release/pre-v[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "candidate CI verification requires the single candidate branch release/pre-vX.Y.Z"
  exit 1
fi
BRANCH_VERSION="${BRANCH#release/pre-v}"

BASE_COMMIT="$(git rev-parse HEAD^)"
TRUSTED_RUNNER="$(/usr/bin/mktemp /private/tmp/sayall-trusted-candidate-ci.XXXXXX)"
git show "${BASE_COMMIT}:scripts/run-trusted-release-validation.sh" > "$TRUSTED_RUNNER"
/bin/chmod 755 "$TRUSTED_RUNNER"
REPOSITORY_ROOT="$ROOT" GITHUB_REF_NAME="$BRANCH" ALLOW_FROZEN_BASE_MAIN=1 \
  "$TRUSTED_RUNNER" >/dev/null
HEAD_COMMIT="$(git rev-parse HEAD)"
if [[ -n "$EXPECTED_COMMIT" && "$EXPECTED_COMMIT" != "$HEAD_COMMIT" ]]; then
  print -u2 "candidate checkout does not match expected_commit"
  exit 1
fi
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$BRANCH_VERSION" ]]; then
  print -u2 "signed packaging tag must match the preview candidate branch"
  exit 1
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(
    "$GH_BIN" run list \
      --repo "$REPOSITORY" \
      --workflow "$WORKFLOW_FILE" \
      --branch "$BRANCH" \
      --commit "$HEAD_COMMIT" \
      --event push \
      --status success \
      --limit 20 \
      --json databaseId,headSha,headBranch,event,status,conclusion \
      --jq '.[0].databaseId // empty'
  )"
fi
if [[ -z "$RUN_ID" || ! "$RUN_ID" =~ '^[0-9]+$' ]]; then
  print -u2 "no successful macOS Preview Candidate push run exists for $BRANCH at $HEAD_COMMIT"
  exit 1
fi

RUN_API_JSON="$("$GH_BIN" api "repos/$REPOSITORY/actions/runs/$RUN_ID")"
RUN_ATTEMPT="$(print -r -- "$RUN_API_JSON" | jq -r '.run_attempt // empty')"
if ! print -r -- "$RUN_API_JSON" | jq -e \
  --arg workflowName "$WORKFLOW_NAME" \
  --arg workflowPath "$WORKFLOW_PATH" \
  --arg branch "$BRANCH" \
  --arg headSha "$HEAD_COMMIT" '
    .name == $workflowName and
    .path == $workflowPath and
    .event == "push" and
    .status == "completed" and
    .conclusion == "success" and
    .head_branch == $branch and
    .head_sha == $headSha and
    (.run_attempt | type) == "number" and .run_attempt > 0 and
    (.updated_at | type) == "string"
  ' >/dev/null || [[ ! "$RUN_ATTEMPT" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "preview candidate run $RUN_ID has unexpected workflow provenance"
  exit 1
fi
RUN_JOBS_JSON="$(
  "$GH_BIN" api "repos/$REPOSITORY/actions/runs/$RUN_ID/attempts/$RUN_ATTEMPT/jobs?per_page=100"
)"
if ! print -r -- "$RUN_JOBS_JSON" | jq -e '
    ([.jobs[] | select(
      .name == "Validate and package preview candidate (Apple Silicon)" and
      .status == "completed" and .conclusion == "success" and
      ([.steps[] | select(.name == "Reuse exact parent main product-code proof" and .conclusion == "success")] | length) == 1
    )] | length) == 1 and
    ([.jobs[] | select(
      .name == "Validate and package preview candidate (Intel Ventura)" and
      .status == "completed" and .conclusion == "success" and
      ([.steps[] | select(.name == "Reuse exact parent main product-code proof" and .conclusion == "success")] | length) == 1
    )] | length) == 1
  ' >/dev/null; then
  print -u2 "preview candidate run $RUN_ID is not a successful exact-SHA two-architecture push run"
  exit 1
fi

CANDIDATE_GATE_COMPLETED_AT="$(print -r -- "$RUN_API_JSON" | jq -r '.updated_at // empty')"
if [[ -n "${RELEASE_READY_PROOF_OUTPUT:-}" ]]; then
  [[ -r "$RELEASE_READY_PROOF_OUTPUT" && -n "$CANDIDATE_GATE_COMPLETED_AT" ]] || {
    print -u2 "candidate CI proof lacks a trusted completion timestamp"
    exit 1
  }
  proof_temp="${RELEASE_READY_PROOF_OUTPUT}.candidate-gate.tmp"
  jq --arg candidateGateCompletedAt "$CANDIDATE_GATE_COMPLETED_AT" \
    '. + {candidateGateCompletedAt: $candidateGateCompletedAt}' \
    "$RELEASE_READY_PROOF_OUTPUT" > "$proof_temp"
  /bin/mv "$proof_temp" "$RELEASE_READY_PROOF_OUTPUT"
fi

if [[ "$REQUIRE_PREVIEW_RECORDING_PR" == "1" ]]; then
  PR_JSON="$(
    "$GH_BIN" api \
      "repos/$REPOSITORY/commits/$HEAD_COMMIT/pulls" \
      --header 'Accept: application/vnd.github+json' \
      --jq "[.[] | select(.state == \"open\" and .base.ref == \"main\" and .head.repo.full_name == \"$REPOSITORY\") | {number, url: .html_url, isDraft: .draft, headRefName: .head.ref, headRefOid: .head.sha}]"
  )"
  if ! print -r -- "$PR_JSON" | jq -e \
    --arg branch "$BRANCH" --arg headSha "$HEAD_COMMIT" '
      length == 1 and
      .[0].headRefName == $branch and
      .[0].headRefOid == $headSha and
      .[0].isDraft == true
    ' >/dev/null; then
    print -u2 "signed packaging requires exactly one exact-SHA Draft preview recording PR on the candidate branch"
    exit 1
  fi
  PR_NUMBER="$(print -r -- "$PR_JSON" | jq -r '.[0].number')"
  PR_CHECKS_JSON="$(
    "$GH_BIN" pr view "$PR_NUMBER" \
      --repo "$REPOSITORY" \
      --json statusCheckRollup
  )"
  if ! print -r -- "$PR_CHECKS_JSON" | jq -e '
    def latest_check($name):
      [.statusCheckRollup[] | select(.workflowName == "macOS CI" and .name == $name)]
      | sort_by(.startedAt // .completedAt // "")
      | last;
    (latest_check("Swift tests and build (Apple Silicon)")) as $apple |
    (latest_check("Swift tests and build (Intel Ventura)")) as $intel |
    $apple != null and $intel != null and
    $apple.status == "COMPLETED" and $apple.conclusion == "SUCCESS" and
    $intel.status == "COMPLETED" and $intel.conclusion == "SUCCESS"
  ' >/dev/null; then
    print -u2 "signed packaging requires successful exact-SHA Draft PR Apple Silicon and Intel checks"
    exit 1
  fi
  PR_RUN_IDS=("${(@f)$(print -r -- "$PR_CHECKS_JSON" | jq -r '
    def latest_check($name):
      [.statusCheckRollup[] | select(.workflowName == "macOS CI" and .name == $name)]
      | sort_by(.startedAt // .completedAt // "")
      | last;
    latest_check("Swift tests and build (Apple Silicon)"),
    latest_check("Swift tests and build (Intel Ventura)")
    | (.detailsUrl // "")
    | try capture("/actions/runs/(?<id>[0-9]+)/").id catch empty
  ' | /usr/bin/sort -u)}")
  if (( ${#PR_RUN_IDS[@]} != 1 )) || [[ ! "${PR_RUN_IDS[1]:-}" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Draft PR architecture checks must come from the same exact pull_request workflow run"
    exit 1
  fi
  PR_RUN_ID="${PR_RUN_IDS[1]}"
  PR_RUN_API_JSON="$("$GH_BIN" api "repos/$REPOSITORY/actions/runs/$PR_RUN_ID")"
  PR_RUN_ATTEMPT="$(print -r -- "$PR_RUN_API_JSON" | jq -r '.run_attempt // empty')"
  if ! print -r -- "$PR_RUN_API_JSON" | jq -e \
    --arg workflowName "$PR_WORKFLOW_NAME" \
    --arg workflowPath "$PR_WORKFLOW_PATH" \
    --arg branch "$BRANCH" \
    --arg headSha "$HEAD_COMMIT" '
      .name == $workflowName and
      .path == $workflowPath and
      .event == "pull_request" and
      .status == "completed" and .conclusion == "success" and
      .head_branch == $branch and .head_sha == $headSha and
      (.run_attempt | type) == "number" and .run_attempt > 0
    ' >/dev/null || [[ ! "$PR_RUN_ATTEMPT" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Draft PR checks came from an unexpected workflow path or run identity"
    exit 1
  fi
  PR_RUN_JOBS_JSON="$(
    "$GH_BIN" api "repos/$REPOSITORY/actions/runs/$PR_RUN_ID/attempts/$PR_RUN_ATTEMPT/jobs?per_page=100"
  )"
  if ! print -r -- "$PR_RUN_JOBS_JSON" | jq -e '
      ([.jobs[] | select(
        .name == "Swift tests and build (Apple Silicon)" and
        .status == "completed" and .conclusion == "success" and
        ([.steps[] | select(.name == "Reuse exact parent main CI for release metadata" and .conclusion == "success")] | length) == 1
      )] | length) == 1 and
      ([.jobs[] | select(
        .name == "Swift tests and build (Intel Ventura)" and
        .status == "completed" and .conclusion == "success" and
        ([.steps[] | select(.name == "Reuse exact parent main CI for release metadata" and .conclusion == "success")] | length) == 1
      )] | length) == 1
    ' >/dev/null; then
    print -u2 "Draft PR checks are not a successful exact-SHA pull_request macOS CI run"
    exit 1
  fi
fi

print "PREVIEW CANDIDATE CI PASS"
print "BRANCH: $BRANCH"
print "HEAD: $HEAD_COMMIT"
print "CANDIDATE_GATE_COMPLETED_AT: $CANDIDATE_GATE_COMPLETED_AT"
print "RUN_ID: $RUN_ID"
