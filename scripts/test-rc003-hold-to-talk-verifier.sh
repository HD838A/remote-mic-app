#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
verifier="$root/scripts/verify-rc003-hold-to-talk.sh"
work_dir=$(/usr/bin/mktemp -d /private/tmp/sayall-rc003-verifier.XXXXXX)
trap '/bin/rm -rf -- "$work_dir"' EXIT

run_case() {
  local name=$1 expected_status=$2 expected_result=$3
  local log_file="$work_dir/$name.log"
  shift 3
  /usr/bin/printf '%s\n' "$@" > "$log_file"

  set +e
  output=$("$verifier" --log "$log_file" 2>&1)
  exit_code=$?
  set -e

  [[ "$exit_code" == "$expected_status" ]] || {
    print -u2 "FAIL $name: expected status $expected_status, got $exit_code"
    print -u2 -- "$output"
    exit 1
  }
  [[ "$output" == *"result=$expected_result"* ]] || {
    print -u2 "FAIL $name: expected result $expected_result"
    print -u2 -- "$output"
    exit 1
  }
  print "PASS $name"
}

run_case requires_button 0 requires_voice_button \
  "KARAOKE MODE enabled trigger=button_mapping" \
  "ATVV CAPS runtime_applied version=256 codec=2 interaction=0 requested=0" \
  "ATVV STREAM START session=0 origin=host_mic_open" \
  "ATVV STREAM summary trace=1 model=rc003 duration_ms=2600 batches=0 samples=0" \
  "ATVV STREAM STOP session=0 origin=host_mic_open reason=0" \
  "ATVV STREAM START session=68 origin=remote_htt" \
  "ATVV STREAM summary trace=2 model=rc003 duration_ms=1400 batches=84 samples=20160" \
  "ATVV STREAM STOP session=68 origin=remote_htt reason=2"

run_case continuous_supported 1 continuous_microphone_supported \
  "KARAOKE MODE enabled trigger=settings" \
  "ATVV CAPS runtime_applied version=256 codec=2 interaction=0 requested=0" \
  "ATVV STREAM START session=0 origin=host_mic_open" \
  "ATVV STREAM summary trace=1 model=rc003 duration_ms=70000 batches=4000 samples=960000"

run_case missing_physical_control 2 inconclusive \
  "KARAOKE MODE enabled trigger=settings" \
  "ATVV CAPS runtime_applied version=256 codec=2 interaction=0 requested=0" \
  "ATVV STREAM START session=0 origin=host_mic_open" \
  "ATVV STREAM summary trace=1 model=rc003 duration_ms=2600 batches=0 samples=0"

run_case physical_only 2 inconclusive \
  "KARAOKE MODE enabled trigger=settings" \
  "ATVV STREAM START session=70 origin=remote_htt" \
  "ATVV STREAM summary trace=1 model=rc003 duration_ms=1200 batches=70 samples=16800"

run_case non_rc003_is_not_proof 2 inconclusive \
  "KARAOKE MODE enabled trigger=settings" \
  "ATVV CAPS runtime_applied version=256 codec=2 interaction=0 requested=0" \
  "ATVV STREAM START session=0 origin=host_mic_open" \
  "ATVV STREAM summary trace=1 model=rc001 duration_ms=2600 batches=0 samples=0" \
  "ATVV STREAM START session=70 origin=remote_htt" \
  "ATVV STREAM summary trace=2 model=rc001 duration_ms=1200 batches=70 samples=16800"

run_case physical_before_host_is_not_control 2 inconclusive \
  "KARAOKE MODE enabled trigger=settings" \
  "ATVV CAPS runtime_applied version=256 codec=2 interaction=0 requested=0" \
  "ATVV STREAM START session=70 origin=remote_htt" \
  "ATVV STREAM summary trace=1 model=rc003 duration_ms=1200 batches=70 samples=16800" \
  "ATVV STREAM START session=0 origin=host_mic_open" \
  "ATVV STREAM summary trace=2 model=rc003 duration_ms=2600 batches=0 samples=0"

run_case latest_session_wins 2 inconclusive \
  "KARAOKE MODE enabled trigger=settings" \
  "ATVV CAPS runtime_applied version=256 codec=2 interaction=0 requested=0" \
  "ATVV STREAM START session=0 origin=host_mic_open" \
  "ATVV STREAM summary trace=1 model=rc003 duration_ms=2600 batches=0 samples=0" \
  "ATVV STREAM START session=70 origin=remote_htt" \
  "ATVV STREAM summary trace=2 model=rc003 duration_ms=1200 batches=70 samples=16800" \
  "KARAOKE MODE disabled reason=settings" \
  "KARAOKE MODE enabled trigger=settings" \
  "ATVV CAPS runtime_applied version=256 codec=2 interaction=0 requested=0" \
  "ATVV STREAM START session=0 origin=host_mic_open" \
  "ATVV STREAM summary trace=3 model=rc003 duration_ms=2600 batches=0 samples=0"

print "RC003 HOLD-TO-TALK VERIFIER TESTS PASSED"
