#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
runtime_log="$HOME/Library/Logs/RemoteMic/runtime.log"
acceptance_root="$project_root/.build/hid-button-acceptance"
current_file="$acceptance_root/current"
command=${1:-status}

current_session() {
  [[ -f "$current_file" ]] || {
    print -u2 "No active HID acceptance session. Run: $0 prepare"
    exit 2
  }
  print -r -- "$(<"$current_file")"
}

snapshot() {
  local session start_line
  session=$(current_session)
  start_line=$(<"$session/start-line")
  if [[ -f "$runtime_log" ]]; then
    tail -n +"$start_line" "$runtime_log" > "$session/runtime.log"
  else
    : > "$session/runtime.log"
  fi
  rg 'VOICE FN MAPPING|HID MAPPING (RECOVERY|VERIFY)|HID START|HID EDGE|HID GESTURE|HID BUTTON|VOICE SHORTCUT|ATVV STREAM' \
    "$session/runtime.log" > "$session/hid-summary.log" || true
  print -r -- "session=$session"
  print -r -- "steps=$session/steps.log"
  print -r -- "summary=$session/hid-summary.log"
  print -r -- "runtime=$session/runtime.log"
}

case "$command" in
  prepare)
    session="$acceptance_root/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$session"
    print -r -- "$session" > "$current_file"
    if [[ -f "$runtime_log" ]]; then
      print -r -- "$(( $(wc -l < "$runtime_log") + 1 ))" > "$session/start-line"
    else
      print -r -- "1" > "$session/start-line"
    fi
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) PREPARE" > "$session/steps.log"
    snapshot
    ;;
  mark)
    shift
    (( $# > 0 )) || {
      print -u2 "usage: $0 mark <button/gesture/lifecycle step>"
      exit 2
    }
    session=$(current_session)
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$session/steps.log"
    snapshot
    ;;
  snapshot)
    snapshot
    ;;
  finish)
    session=$(current_session)
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) FINISH" >> "$session/steps.log"
    snapshot
    ;;
  status)
    if [[ -f "$current_file" ]]; then
      snapshot
    else
      print -r -- "No active HID acceptance session"
    fi
    ;;
  *)
    print -u2 "usage: $0 <prepare|mark|snapshot|finish|status>"
    exit 2
    ;;
esac
