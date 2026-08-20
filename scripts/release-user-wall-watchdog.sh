#!/bin/zsh
set -euo pipefail
umask 077

MODE="${1:-}"
REQUEST_STARTED_AT="${2:-}"
RELEASE_READY_AT="${3:-}"
REQUEST_ID="${4:-}"
TARGET="${5:-}"
COMPLETION_FILE="${6:-}"
RUN_ID_FILE="${7:-}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
POLL_SECONDS="${RELEASE_WATCHDOG_POLL_SECONDS:-5}"

if [[ "$#" -ne 7 ]]; then
  print -u2 "usage: $0 preview|stable <request-started-epoch> <release-ready-epoch> <request-id> <candidate-branch-or-tag> <completion-file> <run-manifest.jsonl>"
  exit 2
fi
case "$MODE" in
  preview)
    TOTAL_BUDGET_SECONDS=1740
    READY_BUDGET_SECONDS=840
    [[ "$TARGET" =~ '^release/pre-v[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
      print -u2 "preview watchdog requires release/pre-vX.Y.Z"
      exit 2
    }
    ;;
  stable)
    TOTAL_BUDGET_SECONDS=1740
    READY_BUDGET_SECONDS=1740
    [[ "$TARGET" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
      print -u2 "stable watchdog requires vX.Y.Z"
      exit 2
    }
    ;;
  *) print -u2 "watchdog mode must be preview or stable"; exit 2 ;;
esac
if [[ ! "$REQUEST_STARTED_AT" =~ '^[0-9]+$' ||
      ! "$RELEASE_READY_AT" =~ '^[0-9]+$' ||
      "$RELEASE_READY_AT" -lt "$REQUEST_STARTED_AT" ]]; then
  print -u2 "request_started_at/release_ready_at must be ordered Unix epoch seconds"
  exit 2
fi
if [[ ! "$REQUEST_ID" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$' ]]; then
  print -u2 "request_id is invalid"
  exit 2
fi
if [[ ! "$POLL_SECONDS" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "RELEASE_WATCHDOG_POLL_SECONDS must be positive seconds"
  exit 2
fi
for command_name in jq "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

initial_now="$(/bin/date +%s)"
if (( initial_now - RELEASE_READY_AT < 0 )); then
  print -u2 "release timestamps cannot be in the future"
  exit 2
fi

cancel_registered_runs() {
  local manifest_line run_id workflow_name head_sha head_branch recorded_target remote_json
  [[ -f "$RUN_ID_FILE" ]] || return 0
  while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
    [[ -z "$manifest_line" ]] && continue
    if ! print -r -- "$manifest_line" | jq -e . >/dev/null 2>&1; then
      print -u2 "Ignoring malformed workflow run manifest entry"
      continue
    fi
    run_id="$(print -r -- "$manifest_line" | jq -r '.runId // empty')"
    workflow_name="$(print -r -- "$manifest_line" | jq -r '.workflow // empty')"
    head_sha="$(print -r -- "$manifest_line" | jq -r '.headSha // empty')"
    head_branch="$(print -r -- "$manifest_line" | jq -r '.headBranch // empty')"
    recorded_target="$(print -r -- "$manifest_line" | jq -r '.target // empty')"
    if [[ ! "$run_id" =~ '^[1-9][0-9]*$' ||
          ! "$head_sha" =~ '^[0-9a-f]{40}$' ||
          -z "$workflow_name" || -z "$head_branch" ||
          "$recorded_target" != "$TARGET" ||
          "$(print -r -- "$manifest_line" | jq -r '.requestId // empty')" != "$REQUEST_ID" ]]; then
      print -u2 "Ignoring workflow run manifest entry with mismatched identity"
      continue
    fi
    remote_json="$($GH_BIN run view "$run_id" --repo "$REPOSITORY" --json workflowName,headSha,headBranch 2>/dev/null || true)"
    if ! print -r -- "$remote_json" | jq -e \
      --arg workflow "$workflow_name" --arg sha "$head_sha" --arg branch "$head_branch" \
      '.workflowName == $workflow and .headSha == $sha and .headBranch == $branch' >/dev/null; then
      print -u2 "Ignoring workflow run whose remote identity does not match the manifest"
      continue
    fi
    "$GH_BIN" run cancel "$run_id" --repo "$REPOSITORY" >/dev/null 2>&1 || true
  done < "$RUN_ID_FILE"
}

while true; do
  if [[ -f "$COMPLETION_FILE" ]]; then
    if jq -e \
      --arg mode "$MODE" \
      --arg requestId "$REQUEST_ID" \
      --arg target "$TARGET" \
      --argjson requestStartedAt "$REQUEST_STARTED_AT" \
      --argjson releaseReadyAt "$RELEASE_READY_AT" '
        .mode == $mode and
        .requestId == $requestId and
        .target == $target and
        .requestStartedAt == $requestStartedAt and
        .releaseReadyAt == $releaseReadyAt and
        .status == "published-and-verified"
      ' "$COMPLETION_FILE" >/dev/null 2>&1; then
      print "RELEASE USER-WALL WATCHDOG PASS mode=$MODE target=$TARGET"
      exit 0
    fi
    print -u2 "Ignoring completion file with mismatched release identity"
  fi
  now="$(/bin/date +%s)"
  total_elapsed=$(( now - REQUEST_STARTED_AT ))
  ready_elapsed=$(( now - RELEASE_READY_AT ))
  if (( total_elapsed < 0 || ready_elapsed < 0 )); then
    print -u2 "release timestamps cannot be in the future"
    exit 2
  fi
  if (( total_elapsed >= TOTAL_BUDGET_SECONDS || ready_elapsed >= READY_BUDGET_SECONDS )); then
    cancel_registered_runs
    print -u2 "RELEASE USER-WALL SLO EXCEEDED mode=$MODE target=$TARGET total=${total_elapsed}s/${TOTAL_BUDGET_SECONDS}s ready=${ready_elapsed}s/${READY_BUDGET_SECONDS}s"
    print -u2 "The release manager has at most 60 seconds to report this bounded failure."
    exit 124
  fi
  /bin/sleep "$POLL_SECONDS"
done
