#!/bin/zsh
set -euo pipefail

runtime_log="$HOME/Library/Logs/RemoteMic/runtime.log"

usage() {
  print -u2 "usage: $0 [--log <runtime.log>]"
}

while (( $# > 0 )); do
  case "$1" in
    --log)
      (( $# >= 2 )) || { usage; exit 2; }
      runtime_log="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -f "$runtime_log" ]] || {
  print -u2 "result=inconclusive reason=log_not_found log=$runtime_log"
  exit 2
}

analysis=$(/usr/bin/awk '
  function reset_session() {
    enabled = 1
    on_request_applied = 0
    host_attempts = 0
    host_empty = 0
    host_audio = 0
    htt_streams = 0
    htt_audio = 0
    observed_host_empty = 0
    active_origin = "unknown"
  }

  /KARAOKE MODE enabled/ {
    reset_session()
    next
  }

  enabled && /ATVV CAPS runtime_applied/ && /interaction=0/ && /requested=0/ {
    on_request_applied = 1
    next
  }

  enabled && /ATVV STREAM START/ {
    active_origin = "unknown"
    if ($0 ~ /origin=host_mic_open/ && $0 ~ /session=0/) {
      if (on_request_applied) {
        active_origin = "host_mic_open"
        host_attempts++
      }
    } else if ($0 ~ /origin=remote_htt/ && observed_host_empty) {
      active_origin = "remote_htt"
      htt_streams++
    }
    next
  }

  enabled && /ATVV STREAM summary/ {
    if ($0 !~ /model=rc003/) {
      next
    }
    samples = -1
    if (match($0, /samples=[0-9]+/)) {
      samples = substr($0, RSTART + 8, RLENGTH - 8) + 0
    }
    if (active_origin == "host_mic_open" && samples == 0) {
      host_empty++
      observed_host_empty = 1
    } else if (active_origin == "host_mic_open" && samples > 0) {
      host_audio++
    } else if (active_origin == "remote_htt" && samples > 0) {
      htt_audio++
    }
    next
  }

  enabled && /ATVV STREAM STOP/ {
    active_origin = "unknown"
    next
  }

  END {
    if (!enabled) {
      print "found=0"
      exit
    }
    printf "found=1 on_request=%d host_attempts=%d host_empty=%d host_audio=%d htt_streams=%d htt_audio=%d\n", \
      on_request_applied, host_attempts, host_empty, host_audio, htt_streams, htt_audio
  }
' "$runtime_log")

typeset -A evidence
for item in ${(z)analysis}; do
  key=${item%%=*}
  value=${item#*=}
  evidence[$key]=$value
done

if [[ "${evidence[found]:-0}" != "1" ]]; then
  print "result=inconclusive reason=no_karaoke_session"
  exit 2
fi

print "evidence on_request=${evidence[on_request]:-0} host_attempts=${evidence[host_attempts]:-0} host_empty=${evidence[host_empty]:-0} host_audio=${evidence[host_audio]:-0} htt_streams=${evidence[htt_streams]:-0} htt_audio=${evidence[htt_audio]:-0}"

if (( ${evidence[host_audio]:-0} > 0 )); then
  print "result=continuous_microphone_supported reason=host_mic_open_produced_pcm"
  exit 1
fi

if (( ${evidence[on_request]:-0} == 1 &&
      ${evidence[host_attempts]:-0} > 0 &&
      ${evidence[host_empty]:-0} > 0 &&
      ${evidence[htt_streams]:-0} > 0 &&
      ${evidence[htt_audio]:-0} > 0 )); then
  print "result=requires_voice_button reason=host_open_empty_remote_htt_has_pcm"
  exit 0
fi

missing=()
(( ${evidence[on_request]:-0} == 1 )) || missing+=(on_request_negotiation)
(( ${evidence[host_attempts]:-0} > 0 )) || missing+=(host_mic_open)
(( ${evidence[host_empty]:-0} > 0 )) || missing+=(empty_host_stream)
(( ${evidence[htt_streams]:-0} > 0 )) || missing+=(remote_htt_stream)
(( ${evidence[htt_audio]:-0} > 0 )) || missing+=(remote_htt_pcm)
print "result=inconclusive reason=missing_${(j:,:)missing}"
exit 2
