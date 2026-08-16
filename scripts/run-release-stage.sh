#!/bin/zsh
set -euo pipefail

if [[ "$#" -lt 5 ]]; then
  print -u2 "usage: $0 <lane> <stage> <timeout-seconds> -- <command> [args...]"
  exit 2
fi

LANE="$1"
STAGE="$2"
TIMEOUT_SECONDS="$3"
shift 3
if [[ "$1" != "--" ]]; then
  print -u2 "release stage command must follow --"
  exit 2
fi
shift
if [[ "$#" -eq 0 ]]; then
  print -u2 "release stage command is required"
  exit 2
fi
if ! print -r -- "$LANE" | /usr/bin/grep -Eq '^[A-Za-z0-9._-]+$'; then
  print -u2 "release stage lane must be a non-sensitive label"
  exit 2
fi
if ! print -r -- "$STAGE" | /usr/bin/grep -Eq '^[A-Za-z0-9._-]+$'; then
  print -u2 "release stage name must be a non-sensitive label"
  exit 2
fi
if ! print -r -- "$TIMEOUT_SECONDS" | /usr/bin/grep -Eq '^[1-9][0-9]*$'; then
  print -u2 "release stage timeout must be a positive integer"
  exit 2
fi

HEARTBEAT_SECONDS="${RELEASE_HEARTBEAT_SECONDS:-30}"
if ! print -r -- "$HEARTBEAT_SECONDS" | /usr/bin/grep -Eq '^[1-9][0-9]*$'; then
  print -u2 "RELEASE_HEARTBEAT_SECONDS must be a positive integer"
  exit 2
fi

CHILD_PID=""
TIMED_OUT=0
START_SECONDS="$(/bin/date +%s)"

collect_descendants() {
  local parent_pid="$1"
  local child_pid
  while IFS= read -r child_pid; do
    [[ -n "$child_pid" ]] || continue
    collect_descendants "$child_pid"
    RELEASE_DESCENDANT_PIDS+=("$child_pid")
  done < <(/usr/bin/pgrep -P "$parent_pid" 2>/dev/null || true)
}

process_running() {
  local target_pid="$1"
  local process_state
  /bin/kill -0 "$target_pid" 2>/dev/null || return 1
  process_state="$(/bin/ps -o stat= -p "$target_pid" 2>/dev/null | /usr/bin/tr -d ' ' || true)"
  [[ -n "$process_state" && "$process_state" != Z* ]]
}

terminate_process_tree() {
  local root_pid="$1"
  local process_id
  local attempt
  local any_running
  local -a target_pids
  typeset -ga RELEASE_DESCENDANT_PIDS=()
  collect_descendants "$root_pid"
  target_pids=("${RELEASE_DESCENDANT_PIDS[@]}" "$root_pid")
  for process_id in "${target_pids[@]}"; do
    /bin/kill -TERM "$process_id" 2>/dev/null || true
  done
  for attempt in {1..20}; do
    any_running=0
    for process_id in "${target_pids[@]}"; do
      if process_running "$process_id"; then
        any_running=1
        break
      fi
    done
    (( any_running == 0 )) && return 0
    /bin/sleep 0.1
  done
  for process_id in "${target_pids[@]}"; do
    /bin/kill -KILL "$process_id" 2>/dev/null || true
  done
}

handle_signal() {
  local signal_name="$1"
  local elapsed=$(( $(/bin/date +%s) - START_SECONDS ))
  print -u2 "RELEASE STAGE CANCEL lane=$LANE stage=$STAGE elapsed=${elapsed}s signal=$signal_name"
  if [[ -n "$CHILD_PID" ]]; then
    terminate_process_tree "$CHILD_PID"
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  exit 143
}

trap 'handle_signal TERM' TERM
trap 'handle_signal INT' INT
trap 'handle_signal HUP' HUP

NEXT_HEARTBEAT=$(( START_SECONDS + HEARTBEAT_SECONDS ))
print -u2 "RELEASE STAGE START lane=$LANE stage=$STAGE timeout=${TIMEOUT_SECONDS}s"

"$@" &
CHILD_PID=$!

while process_running "$CHILD_PID"; do
  now_seconds="$(/bin/date +%s)"
  elapsed=$(( now_seconds - START_SECONDS ))
  if (( now_seconds >= NEXT_HEARTBEAT )); then
    print -u2 "RELEASE STAGE HEARTBEAT lane=$LANE stage=$STAGE elapsed=${elapsed}s"
    NEXT_HEARTBEAT=$(( now_seconds + HEARTBEAT_SECONDS ))
  fi
  if (( elapsed >= TIMEOUT_SECONDS )); then
    TIMED_OUT=1
    print -u2 "RELEASE STAGE TIMEOUT lane=$LANE stage=$STAGE elapsed=${elapsed}s limit=${TIMEOUT_SECONDS}s"
    terminate_process_tree "$CHILD_PID"
    wait "$CHILD_PID" 2>/dev/null || true
    break
  fi
  /bin/sleep 1
done

if (( TIMED_OUT != 0 )); then
  exit 124
fi

if wait "$CHILD_PID"; then
  child_status=0
else
  child_status=$?
fi
elapsed=$(( $(/bin/date +%s) - START_SECONDS ))
if (( child_status == 0 )); then
  print -u2 "RELEASE STAGE PASS lane=$LANE stage=$STAGE elapsed=${elapsed}s"
else
  print -u2 "RELEASE STAGE FAIL lane=$LANE stage=$STAGE elapsed=${elapsed}s exit=$child_status"
fi
exit "$child_status"
