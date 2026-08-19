#!/bin/zsh
set -euo pipefail
umask 077

MODE="${1:-}"
LEDGER_FILE="${2:-}"
REQUEST_STARTED_AT="${3:-}"
STAGE="${4:-}"
RESULT="${5:-}"
CLASSIFICATION="${6:-successful-pipeline}"

if [[ "$#" -lt 3 || "$#" -gt 6 ]]; then
  print -u2 "usage: $0 init|start|finish|check|report <ledger> <request-started-epoch> [stage-or-budget] [result] [classification]"
  exit 2
fi
if [[ ! "$REQUEST_STARTED_AT" =~ '^[0-9]+$' ]]; then
  print -u2 "request_started_at must be Unix epoch seconds"
  exit 2
fi
case "$MODE" in
  init|start|finish|check|report) ;;
  *) print -u2 "unsupported release ledger operation: $MODE"; exit 2 ;;
esac

now="$(/bin/date +%s)"
elapsed=$(( now - REQUEST_STARTED_AT ))
if (( elapsed < 0 )); then
  print -u2 "request_started_at cannot be in the future"
  exit 2
fi

case "$MODE" in
  init)
    /bin/mkdir -p "${LEDGER_FILE:h}"
    print -r -- $'timestamp\telapsed_seconds\tevent\tstage\tresult\tclassification' > "$LEDGER_FILE"
    print -r -- "$now\t$elapsed\trequest-started\trelease\trunning\tsuccessful-pipeline" >> "$LEDGER_FILE"
    ;;
  start)
    [[ -n "$STAGE" ]] || { print -u2 "stage is required"; exit 2; }
    print -r -- "$now\t$elapsed\tstage-start\t$STAGE\trunning\t$CLASSIFICATION" >> "$LEDGER_FILE"
    ;;
  finish)
    [[ -n "$STAGE" && -n "$RESULT" ]] || { print -u2 "stage and result are required"; exit 2; }
    print -r -- "$now\t$elapsed\tstage-finish\t$STAGE\t$RESULT\t$CLASSIFICATION" >> "$LEDGER_FILE"
    ;;
  check)
    if [[ ! "$STAGE" =~ '^[1-9][0-9]*$' ]]; then
      print -u2 "release SLO budget must be positive seconds"
      exit 2
    fi
    if (( elapsed > STAGE )); then
      print -r -- "$now\t$elapsed\tslo-overrun\trelease\tfailed\t${RESULT:-external-or-pipeline-wait}" >> "$LEDGER_FILE"
      print -u2 "RELEASE SLO EXCEEDED elapsed=${elapsed}s budget=${STAGE}s"
      exit 124
    fi
    print "RELEASE SLO WITHIN BUDGET elapsed=${elapsed}s budget=${STAGE}s remaining=$(( STAGE - elapsed ))s"
    ;;
  report)
    [[ -r "$LEDGER_FILE" ]] || { print -u2 "release ledger is unreadable: $LEDGER_FILE"; exit 1; }
    /bin/cat "$LEDGER_FILE"
    print "TOTAL_USER_WALL_SECONDS=$elapsed"
    ;;
esac
