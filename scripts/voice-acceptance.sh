#!/bin/zsh
set -euo pipefail

voice_acceptance_script=${0:A}
root=${voice_acceptance_script:h:h}
runtime_log="${VOICE_ACCEPTANCE_RUNTIME_LOG:-$HOME/Library/Logs/RemoteMic/runtime.log}"
acceptance_root="${VOICE_ACCEPTANCE_ROOT:-$root/.build/voice-acceptance}"
build_run_script="${VOICE_ACCEPTANCE_BUILD_RUN_SCRIPT:-$root/script/build_and_run.sh}"
unified_log_command="${VOICE_ACCEPTANCE_LOG_COMMAND:-/usr/bin/log}"
current_file="$acceptance_root/current"
command=${1:-status}

current_session() {
  [[ -f "$current_file" ]] || {
    print -u2 "No active voice acceptance session. Run: $0 prepare"
    exit 2
  }
  print -r -- "$(<"$current_file")"
}

runtime_identity_and_size() {
  local path=$1
  [[ -f "$path" ]] || return 1
  /usr/bin/stat -f '%d:%i %z' "$path"
}

runtime_cursor_is_valid() {
  local cursor=$1
  local cursor_id=${cursor%% *}
  local cursor_offset=${cursor##* }
  [[ "$cursor" == "$cursor_id $cursor_offset" &&
     "$cursor_id" == <->:<-> &&
     "$cursor_offset" == <-> ]]
}

append_log_range() {
  setopt localoptions no_pipefail
  local source=$1
  local offset=$2
  local length=$3
  local destination=$4
  local size_before size_after
  (( length >= 0 && offset >= 0 )) || return 1
  (( length == 0 )) && return 0

  size_before=$(/usr/bin/stat -f '%z' "$destination") || return $?
  /usr/bin/tail -c "+$(( offset + 1 ))" "$source" |
    /usr/bin/head -c "$length" >> "$destination" || return $?
  size_after=$(/usr/bin/stat -f '%z' "$destination") || return $?
  if (( size_after - size_before != length )); then
    print -u2 "Runtime log changed while reading: $source"
    return 1
  fi
}

archive_session_directory() {
  local source=$1
  local archive_root=$2
  local label=$3
  local container
  mkdir -p "$archive_root" || return $?
  container=$(/usr/bin/mktemp -d "$archive_root/$label.XXXXXX") || return $?
  [[ -n "$container" && -d "$container" ]] || return 2
  /bin/mv "$source" "$container/item" || return $?
}

apply_runtime_transaction() {
  local session=$1
  local transaction=$2
  local cursor_file="$session/runtime-cursors.log"
  local runtime_output="$session/runtime.log"
  local chunk="$transaction/chunk"
  local old_cursor new_cursor runtime_before_size chunk_size
  local runtime_size expected_size appended_size remaining_size current_cursor actual_size
  local required_file

  for required_file in old-cursor new-cursor runtime-before-size chunk-size chunk ready; do
    [[ -e "$transaction/$required_file" ]] || {
      print -u2 "Incomplete runtime transaction: $transaction"
      return 2
    }
  done
  old_cursor=$(<"$transaction/old-cursor")
  new_cursor=$(<"$transaction/new-cursor")
  runtime_before_size=$(<"$transaction/runtime-before-size")
  chunk_size=$(<"$transaction/chunk-size")
  runtime_cursor_is_valid "$old_cursor" && runtime_cursor_is_valid "$new_cursor" || {
    print -u2 "Invalid runtime transaction cursor: $transaction"
    return 2
  }
  [[ "$runtime_before_size" == <-> && "$chunk_size" == <-> ]] || {
    print -u2 "Invalid runtime transaction sizes: $transaction"
    return 2
  }
  actual_size=$(/usr/bin/stat -f '%z' "$chunk") || return $?
  [[ "$actual_size" == "$chunk_size" ]] || {
    print -u2 "Runtime transaction chunk size changed: $transaction"
    return 2
  }

  : >> "$runtime_output" || return $?
  runtime_size=$(/usr/bin/stat -f '%z' "$runtime_output") || return $?
  expected_size=$(( runtime_before_size + chunk_size ))
  if (( runtime_size < runtime_before_size || runtime_size > expected_size )); then
    print -u2 "Runtime snapshot output diverged from pending transaction: $transaction"
    return 2
  fi

  appended_size=$(( runtime_size - runtime_before_size ))
  if (( appended_size > 0 )); then
    /usr/bin/cmp -s -n "$appended_size" \
      "$runtime_output" "$chunk" "$runtime_before_size" 0 || {
      print -u2 "Runtime snapshot output does not match pending chunk: $transaction"
      return 2
    }
  fi
  if (( appended_size < chunk_size )); then
    remaining_size=$(( chunk_size - appended_size ))
    append_log_range "$chunk" "$appended_size" "$remaining_size" "$runtime_output" || return $?
  fi
  actual_size=$(/usr/bin/stat -f '%z' "$runtime_output") || return $?
  [[ "$actual_size" == "$expected_size" ]] || {
    print -u2 "Runtime snapshot output did not reach the committed size: $transaction"
    return 2
  }
  if (( chunk_size > 0 )); then
    /usr/bin/cmp -s -n "$chunk_size" \
      "$runtime_output" "$chunk" "$runtime_before_size" 0 || {
      print -u2 "Runtime snapshot output failed final transaction verification: $transaction"
      return 2
    }
  fi

  if [[ "${VOICE_ACCEPTANCE_TEST_FAILPOINT:-}" == "after_runtime_append" ]]; then
    print -u2 "Injected failure after runtime append: $transaction"
    return 99
  fi

  current_cursor=$(/usr/bin/tail -n 1 "$cursor_file") || return $?
  runtime_cursor_is_valid "$current_cursor" || {
    print -u2 "Invalid current runtime cursor: $cursor_file"
    return 2
  }
  if [[ "$current_cursor" == "$new_cursor" ]]; then
    :
  elif [[ "$current_cursor" == "$old_cursor" ]]; then
    print -r -- "$new_cursor" >> "$cursor_file" || return $?
  else
    print -u2 "Runtime cursor diverged from pending transaction: $transaction"
    return 2
  fi

  archive_session_directory \
    "$transaction" \
    "$session/runtime-transactions/committed" \
    "transaction" || return $?
}

recover_pending_runtime_transactions() {
  local session=$1
  local pending_root="$session/runtime-transactions/pending"
  local transaction
  local -a pending_transactions
  mkdir -p "$pending_root" || return $?
  pending_transactions=("$pending_root"/transaction.*(N/))
  for transaction in "${pending_transactions[@]}"; do
    if [[ ! -e "$transaction/ready" ]]; then
      archive_session_directory \
        "$transaction" \
        "$session/runtime-transactions/abandoned" \
        "incomplete" || return $?
      continue
    fi
    apply_runtime_transaction "$session" "$transaction" || return $?
  done
}

snapshot_runtime_log_locked() {
  local session=$1
  local cursor_file="$session/runtime-cursors.log"
  local cursor_line cursor_id cursor_offset source_log identity
  local current_identity current_id current_size transaction chunk runtime_before_size
  local start_index=0 index offset length
  local -a source_paths source_ids source_sizes

  recover_pending_runtime_transactions "$session" || return $?
  [[ -s "$cursor_file" ]] || {
    print -u2 "Missing runtime log cursor. Run: $0 prepare"
    return 2
  }
  cursor_line=$(/usr/bin/tail -n 1 "$cursor_file") || return $?
  cursor_id=${cursor_line%% *}
  cursor_offset=${cursor_line##* }
  runtime_cursor_is_valid "$cursor_line" || {
    print -u2 "Invalid runtime log cursor: $cursor_line"
    return 2
  }

  for source_log in "$runtime_log.3" "$runtime_log.2" "$runtime_log.1" "$runtime_log"; do
    [[ -f "$source_log" ]] || continue
    identity=$(runtime_identity_and_size "$source_log") || continue
    source_paths+=("$source_log")
    source_ids+=("${identity%% *}")
    source_sizes+=("${identity##* }")
  done
  (( ${#source_paths[@]} > 0 )) || {
    print -u2 "No retained runtime logs found for cursor $cursor_id"
    return 2
  }

  for (( index = 1; index <= ${#source_paths[@]}; index++ )); do
    if [[ "${source_ids[index]}" == "$cursor_id" ]]; then
      start_index=$index
      break
    fi
  done
  (( start_index > 0 )) || {
    print -u2 "Starting runtime log inode $cursor_id is no longer retained; snapshot aborted"
    return 2
  }
  (( cursor_offset <= source_sizes[start_index] )) || {
    print -u2 "Starting runtime log inode $cursor_id shrank below offset $cursor_offset"
    return 2
  }

  mkdir -p "$session/runtime-transactions/pending" || return $?
  transaction=$(/usr/bin/mktemp -d \
    "$session/runtime-transactions/pending/transaction.XXXXXX") || return $?
  [[ -n "$transaction" && -d "$transaction" ]] || return 2
  chunk="$transaction/chunk"
  : >> "$chunk" || return $?
  for (( index = start_index; index <= ${#source_paths[@]}; index++ )); do
    source_log=${source_paths[index]}
    offset=0
    (( index == start_index )) && offset=$cursor_offset
    length=$(( source_sizes[index] - offset ))

    current_identity=$(runtime_identity_and_size "$source_log") || {
      print -u2 "Runtime log moved before it could be read: $source_log"
      return 2
    }
    current_id=${current_identity%% *}
    current_size=${current_identity##* }
    if [[ "$current_id" != "${source_ids[index]}" ]] ||
       (( current_size < source_sizes[index] )); then
      print -u2 "Runtime log changed before it could be read: $source_log"
      return 2
    fi

    append_log_range "$source_log" "$offset" "$length" "$chunk" || return $?

    current_identity=$(runtime_identity_and_size "$source_log") || {
      print -u2 "Runtime log moved while it was being read: $source_log"
      return 2
    }
    current_id=${current_identity%% *}
    current_size=${current_identity##* }
    if [[ "$current_id" != "${source_ids[index]}" ]] ||
       (( current_size < source_sizes[index] )); then
      print -u2 "Runtime log changed while it was being read: $source_log"
      return 2
    fi
  done

  : >> "$session/runtime.log" || return $?
  runtime_before_size=$(/usr/bin/stat -f '%z' "$session/runtime.log") || return $?
  print -r -- "$cursor_line" > "$transaction/old-cursor" || return $?
  print -r -- "${source_ids[-1]} ${source_sizes[-1]}" > "$transaction/new-cursor" || return $?
  print -r -- "$runtime_before_size" > "$transaction/runtime-before-size" || return $?
  /usr/bin/stat -f '%z' "$chunk" > "$transaction/chunk-size" || return $?
  : >> "$transaction/ready" || return $?
  apply_runtime_transaction "$session" "$transaction" || return $?
}

snapshot_runtime_log() {
  local session=$1
  local lock_file="$session/.runtime-snapshot.lockfile"
  local lock_status
  /usr/bin/lockf -k -s -t 10 \
    "$lock_file" "$voice_acceptance_script" __snapshot-runtime-locked "$session" || {
    lock_status=$?
    if (( lock_status == 75 )); then
      print -u2 "Another runtime snapshot is still active for session: $session"
    fi
    return "$lock_status"
  }
}

snapshot_unified_log() {
  local session=$1
  local start_local=$2
  local unified_log unified_error
  unified_log=$(/usr/bin/mktemp \
    "$session/unified-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
  unified_error="$unified_log.stderr"
  : >> "$unified_error"
  if ! "$unified_log_command" show --style compact --start "$start_local" \
      --predicate 'process == "RemoteMic"' >> "$unified_log" 2>> "$unified_error"; then
    print -r -- "$unified_log" >> "$session/unified-failures.log"
    print -u2 "Unified log snapshot failed; previous evidence was preserved: $unified_log"
    return 3
  fi
  print -r -- "$unified_log" >> "$session/unified-snapshots.log"
  print -r -- "$unified_log"
}

snapshot() {
  local session start_local unified_log
  session=$(current_session)
  start_local=$(<"$session/start-local")
  snapshot_runtime_log "$session"
  unified_log=$(snapshot_unified_log "$session" "$start_local")
  print -r -- "session=$session"
  print -r -- "runtime=$session/runtime.log"
  print -r -- "steps=$session/steps.log"
  print -r -- "unified=$unified_log"
}

case "$command" in
  __snapshot-runtime-locked)
    (( $# == 2 )) || {
      print -u2 "Invalid internal runtime snapshot invocation"
      exit 2
    }
    snapshot_runtime_log_locked "$2"
    ;;
  prepare)
    mkdir -p "$acceptance_root"
    session=$(/usr/bin/mktemp -d "$acceptance_root/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    print -r -- "$session" > "$current_file"
    mkdir -p "${runtime_log:h}"
    if [[ ! -e "$runtime_log" ]]; then
      (umask 077; : >> "$runtime_log")
    fi
    identity=$(runtime_identity_and_size "$runtime_log") || {
      print -u2 "Unable to record runtime log identity: $runtime_log"
      exit 2
    }
    print -r -- "${identity%% *}" > "$session/start-log-id"
    print -r -- "${identity##* }" > "$session/start-log-offset"
    print -r -- "$identity" >> "$session/runtime-cursors.log"
    date -u '+%Y-%m-%dT%H:%M:%S.000Z' > "$session/start-utc"
    date '+%Y-%m-%d %H:%M:%S' > "$session/start-local"
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) PREPARE" > "$session/steps.log"
    "$build_run_script" --verify | tee "$session/build-run.log"
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
