#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
WORKFLOW_FILE="mac-preview-candidate.yml"
WORKFLOW_NAME="macOS Preview Candidate"
GH_BIN="${GH_BIN:-gh}"
RUN_ID="${1:-}"
REQUIRE_PREVIEW_RECORDING_PR="${REQUIRE_PREVIEW_RECORDING_PR:-0}"

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
  print -u2 "candidate CI verification requires release/pre-vX.Y.Z"
  exit 1
fi

"$ROOT/scripts/verify-preview-branch.sh" >/dev/null
"$ROOT/scripts/verify-release-dependency-pins.sh" >/dev/null
HEAD_COMMIT="$(git rev-parse HEAD)"
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v${BRANCH#release/pre-v}" ]]; then
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

RUN_JSON="$(
  "$GH_BIN" run view "$RUN_ID" \
    --repo "$REPOSITORY" \
    --json workflowName,event,status,conclusion,headBranch,headSha,jobs,url
)"
if ! print -r -- "$RUN_JSON" | jq -e \
  --arg workflow "$WORKFLOW_NAME" \
  --arg branch "$BRANCH" \
  --arg headSha "$HEAD_COMMIT" '
    .workflowName == $workflow and
    .event == "push" and
    .status == "completed" and
    .conclusion == "success" and
    .headBranch == $branch and
    .headSha == $headSha and
    ([.jobs[] | select(
      .name == "Validate and package preview candidate (Apple Silicon)" and
      .status == "completed" and .conclusion == "success" and
      (([.steps[] | select(.name == "Reuse exact parent main product-code proof" and .conclusion == "success")] | length) == 1 or
       (([.steps[] | select(.name == "Run full candidate validation when reuse is ineligible" and .conclusion == "success")] | length) == 1 and
        ([.steps[] | select(.name == "Upload full ad-hoc candidate" and .conclusion == "success")] | length) == 1))
    )] | length) == 1 and
    ([.jobs[] | select(
      .name == "Validate and package preview candidate (Intel Ventura)" and
      .status == "completed" and .conclusion == "success" and
      (([.steps[] | select(.name == "Reuse exact parent main product-code proof" and .conclusion == "success")] | length) == 1 or
       (([.steps[] | select(.name == "Run full candidate validation when reuse is ineligible" and .conclusion == "success")] | length) == 1 and
        ([.steps[] | select(.name == "Upload full ad-hoc candidate" and .conclusion == "success")] | length) == 1))
    )] | length) == 1
  ' >/dev/null; then
  print -u2 "preview candidate run $RUN_ID is not a successful exact-SHA two-architecture push run"
  exit 1
fi

if [[ "$REQUIRE_PREVIEW_RECORDING_PR" == "1" ]]; then
  PR_JSON="$(
    "$GH_BIN" pr list \
      --repo "$REPOSITORY" \
      --head "$BRANCH" \
      --base main \
      --state open \
      --json number,url,isDraft,headRefOid
  )"
  if ! print -r -- "$PR_JSON" | jq -e \
    --arg headSha "$HEAD_COMMIT" '
      length == 1 and .[0].headRefOid == $headSha and .[0].isDraft == true
    ' >/dev/null; then
    print -u2 "signed packaging requires one exact-SHA Draft preview recording PR"
    exit 1
  fi
  PR_NUMBER="$(print -r -- "$PR_JSON" | jq -r '.[0].number')"
  PR_CHECKS_JSON="$(
    "$GH_BIN" pr view "$PR_NUMBER" \
      --repo "$REPOSITORY" \
      --json statusCheckRollup
  )"
  if ! print -r -- "$PR_CHECKS_JSON" | jq -e '
    [.statusCheckRollup[] | select(
      .name == "Swift tests and build (Apple Silicon)" and
      .status == "COMPLETED" and .conclusion == "SUCCESS"
    )] | length == 1
  ' >/dev/null || ! print -r -- "$PR_CHECKS_JSON" | jq -e '
    [.statusCheckRollup[] | select(
      .name == "Swift tests and build (Intel Ventura)" and
      .status == "COMPLETED" and .conclusion == "SUCCESS"
    )] | length == 1
  ' >/dev/null; then
    print -u2 "signed packaging requires successful exact-SHA Draft PR Apple Silicon and Intel checks"
    exit 1
  fi
fi

print "PREVIEW CANDIDATE CI PASS"
print "BRANCH: $BRANCH"
print "HEAD: $HEAD_COMMIT"
print "RUN_ID: $RUN_ID"
