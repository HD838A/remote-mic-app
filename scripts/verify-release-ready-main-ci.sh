#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
WORKFLOW_FILE="mac-ci.yml"
WORKFLOW_NAME="macOS CI"
GH_BIN="${GH_BIN:-gh}"
MAIN_COMMIT="${1:-}"
PROOF_OUTPUT="${RELEASE_READY_PROOF_OUTPUT:-}"

if [[ "$#" -gt 1 ]]; then
  print -u2 "usage: $0 [main-commit]"
  exit 2
fi
for command_name in git jq "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

cd "$ROOT"
if [[ -z "$MAIN_COMMIT" ]]; then
  MAIN_COMMIT="$(git rev-parse HEAD^)"
fi
if [[ ! "$MAIN_COMMIT" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "release-ready main commit must be a full 40-character SHA"
  exit 1
fi
if [[ "$MAIN_COMMIT" != "$(git rev-parse origin/main)" ]]; then
  print -u2 "release candidate parent must be the latest fetched origin/main"
  exit 1
fi

RUN_ID="$(
  "$GH_BIN" run list \
    --repo "$REPOSITORY" \
    --workflow "$WORKFLOW_FILE" \
    --branch main \
    --commit "$MAIN_COMMIT" \
    --event push \
    --status success \
    --limit 20 \
    --json databaseId,headSha,headBranch,event,status,conclusion \
    --jq '.[0].databaseId // empty'
)"
if [[ -z "$RUN_ID" || ! "$RUN_ID" =~ '^[0-9]+$' ]]; then
  print -u2 "latest origin/main has no successful macOS CI push run: $MAIN_COMMIT"
  exit 1
fi

RUN_JSON="$(
  "$GH_BIN" run view "$RUN_ID" \
    --repo "$REPOSITORY" \
    --json workflowName,event,status,conclusion,headBranch,headSha,jobs,url
)"
if ! print -r -- "$RUN_JSON" | jq -e \
  --arg workflow "$WORKFLOW_NAME" \
  --arg headSha "$MAIN_COMMIT" '
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
  ' >/dev/null; then
  print -u2 "main CI run $RUN_ID is not an exact-SHA successful two-architecture push run"
  exit 1
fi

if [[ -n "$PROOF_OUTPUT" ]]; then
  /bin/mkdir -p "${PROOF_OUTPUT:h}"
  jq -n \
    --arg repository "$REPOSITORY" \
    --arg candidateCommit "$(git rev-parse HEAD)" \
    --arg baseMainCommit "$MAIN_COMMIT" \
    --argjson mainCiRunId "$RUN_ID" \
    --arg mainCiRunUrl "$(print -r -- "$RUN_JSON" | jq -r '.url')" \
    '{
      schemaVersion: 1,
      repository: $repository,
      candidateCommit: $candidateCommit,
      baseMainCommit: $baseMainCommit,
      reusedChecks: ["Apple Silicon", "Intel Ventura"],
      mainCiRunId: $mainCiRunId,
      mainCiRunUrl: $mainCiRunUrl
    }' > "$PROOF_OUTPUT"
fi

print "RELEASE-READY MAIN CI PASS"
print "MAIN_COMMIT: $MAIN_COMMIT"
print "MAIN_CI_RUN_ID: $RUN_ID"
print "MAIN_CI_RUN_URL: $(print -r -- "$RUN_JSON" | jq -r '.url')"
