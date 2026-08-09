#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
runtime_log="$HOME/Library/Logs/RemoteMic/runtime.log"
acceptance_root="$root/.build/voice-acceptance"
current_file="$acceptance_root/current"
command=${1:-status}

current_session() {
  [[ -f "$current_file" ]] || {
    print -u2 "No active voice acceptance session. Run: $0 prepare"
    exit 2
  }
  print -r -- "$(<"$current_file")"
}

snapshot() {
  local session start_line start_local
  session=$(current_session)
  start_line=$(<"$session/start-line")
  start_local=$(<"$session/start-local")
  if [[ -f "$runtime_log" ]]; then
    tail -n +"$start_line" "$runtime_log" > "$session/runtime.log"
  else
    : > "$session/runtime.log"
  fi
  /usr/bin/log show --style compact --start "$start_local" \
    --predicate 'process == "RemoteMic"' > "$session/unified.log" 2>/dev/null || true
  print -r -- "session=$session"
  print -r -- "runtime=$session/runtime.log"
  print -r -- "steps=$session/steps.log"
  print -r -- "unified=$session/unified.log"
}

case "$command" in
  prepare)
    session="$acceptance_root/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$session"
    mkdir -p "$acceptance_root"
    print -r -- "$session" > "$current_file"
    if [[ -f "$runtime_log" ]]; then
      print -r -- "$(( $(wc -l < "$runtime_log") + 1 ))" > "$session/start-line"
    else
      print -r -- "1" > "$session/start-line"
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$session/start-local"
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) PREPARE" > "$session/steps.log"
    "$root/script/build_and_run.sh" --verify | tee "$session/build-run.log"
    snapshot
    ;;
  mark)
    shift
    (( $# > 0 )) || {
      print -u2 "usage: $0 mark <step description>"
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
      print -r -- "No active voice acceptance session"
    fi
    ;;
  *)
    print -u2 "usage: $0 <prepare|mark|snapshot|finish|status>"
    exit 2
    ;;
esac
