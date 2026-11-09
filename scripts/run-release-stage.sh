#!/bin/zsh
set -euo pipefail

if [[ "$#" -eq 2 && "$1" == report-status ]]; then
  exec python3 - "$2" <<'PY'
import json
from pathlib import Path
import re
import sys

fields = {"schemaVersion", "lane", "stage", "result", "elapsedSeconds", "timeoutSeconds", "exitCode"}
check_fields = {"schemaVersion", "lane", "stage", "checkLine", "exitCode"}
try:
    records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
    if not records:
        raise ValueError("empty status")
    for record in records:
        if isinstance(record, dict) and set(record) == check_fields:
            valid = (
                type(record["schemaVersion"]) is int and record["schemaVersion"] == 1
                and record["lane"] in {"apple-silicon", "intel"}
                and record["stage"] == "app-verify"
                and type(record["checkLine"]) is int and record["checkLine"] > 0
                and type(record["exitCode"]) is int and 1 <= record["exitCode"] <= 255
            )
            if not valid:
                raise ValueError("invalid check status")
            continue
        valid = (
            isinstance(record, dict) and set(record) == fields
            and record["schemaVersion"] == 1
            and all(isinstance(record[key], str) and re.fullmatch(r"[A-Za-z0-9._-]+", record[key])
                    for key in ("lane", "stage"))
            and record["result"] in {"started", "passed", "failed", "timeout", "cancelled"}
            and type(record["elapsedSeconds"]) is int
            and type(record["timeoutSeconds"]) is int and record["timeoutSeconds"] > 0
            and (record["exitCode"] is None or
                 (type(record["exitCode"]) is int and 0 <= record["exitCode"] <= 255))
        )
        if not valid:
            raise ValueError("invalid status")
except (OSError, ValueError, TypeError):
    print("RELEASE STATUS result=unavailable")
    sys.exit(1)

for record in records:
    if "checkLine" in record:
        print(f"RELEASE STATUS lane={record['lane']} stage=app-verify "
              f"result=failed line={record['checkLine']} exit={record['exitCode']}")
        continue
    message = (f"RELEASE STATUS lane={record['lane']} stage={record['stage']} "
               f"result={record['result']} elapsed={record['elapsedSeconds']}s")
    if record["exitCode"] is not None:
        message += f" exit={record['exitCode']}"
    if record["result"] == "timeout":
        message += f" limit={record['timeoutSeconds']}s"
    print(message)
PY
fi

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

record_stage_status() {
  [[ -n "${RELEASE_STAGE_STATUS_FILE:-}" ]] || return 0
  # A single append keeps concurrent lanes separate. Diagnostics preserve the
  # original command result, including timeout and cancellation exit codes.
  python3 - "$RELEASE_STAGE_STATUS_FILE" "$LANE" "$STAGE" "$1" "$2" "$3" "$TIMEOUT_SECONDS" <<'PY' || true
import json
import sys

record = {"schemaVersion": 1, "lane": sys.argv[2], "stage": sys.argv[3],
          "result": sys.argv[4], "elapsedSeconds": int(sys.argv[5]),
          "exitCode": None if sys.argv[4] == "started" else int(sys.argv[6]),
          "timeoutSeconds": int(sys.argv[7])}
with open(sys.argv[1], "ab", buffering=0) as output:
    output.write((json.dumps(record) + "\n").encode())
PY
}

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
  record_stage_status cancelled "$elapsed" 143
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
record_stage_status started 0 0

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
    record_stage_status timeout "$elapsed" 124
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
  record_stage_status passed "$elapsed" "$child_status"
else
  print -u2 "RELEASE STAGE FAIL lane=$LANE stage=$STAGE elapsed=${elapsed}s exit=$child_status"
  record_stage_status failed "$elapsed" "$child_status"
fi
exit "$child_status"
