#!/bin/zsh
set -euo pipefail
umask 077

MODE="${1:-}"
REQUEST_STARTED_AT="${2:-}"
RELEASE_READY_AT="${3:-}"
TARGET="${4:-}"
COMPLETION_FILE="${5:-}"
RUN_ID_FILE="${6:-}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
POLL_SECONDS="${RELEASE_WATCHDOG_POLL_SECONDS:-5}"

if [[ "$#" -ne 6 ]]; then
  print -u2 "usage: $0 preview|stable <request-started-epoch> <release-ready-epoch> <candidate-branch-or-tag> <completion-file> <run-id-file>"
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
if [[ ! "$POLL_SECONDS" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "RELEASE_WATCHDOG_POLL_SECONDS must be positive seconds"
  exit 2
fi
for command_name in "$GH_BIN"; do
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
  local run_id
  [[ -f "$RUN_ID_FILE" ]] || return 0
  while IFS= read -r run_id || [[ -n "$run_id" ]]; do
    [[ -z "$run_id" ]] && continue
    if [[ ! "$run_id" =~ '^[1-9][0-9]*$' ]]; then
      print -u2 "Ignoring invalid registered workflow run id: $run_id"
      continue
    fi
    "$GH_BIN" run cancel "$run_id" --repo "$REPOSITORY" >/dev/null 2>&1 || true
  done < "$RUN_ID_FILE"
}

while true; do
  if [[ -f "$COMPLETION_FILE" ]]; then
    print "RELEASE USER-WALL WATCHDOG PASS mode=$MODE target=$TARGET"
    exit 0
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
