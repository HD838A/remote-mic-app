#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PARALLEL_RELEASE_VARIANTS="${PARALLEL_RELEASE_VARIANTS:-0}"
RELEASE_VARIANT_RUNNER="${RELEASE_VARIANT_RUNNER:-$ROOT/scripts/notarize-release.sh}"
RELEASE_STAGE_TIMEOUTS="${RELEASE_STAGE_TIMEOUTS:-0}"
RELEASE_VARIANT_TIMEOUT_SECONDS="${RELEASE_VARIANT_TIMEOUT_SECONDS:-560}"
RELEASE_STAGE_RUNNER="$ROOT/scripts/run-release-stage.sh"
GENERATE_SPARKLE_UPDATE="${GENERATE_SPARKLE_UPDATE:-1}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi
case "$PARALLEL_RELEASE_VARIANTS" in
  0|1) ;;
  *) print -u2 "PARALLEL_RELEASE_VARIANTS must be 0 or 1"; exit 1 ;;
esac
case "$RELEASE_STAGE_TIMEOUTS" in
  0|1) ;;
  *) print -u2 "RELEASE_STAGE_TIMEOUTS must be 0 or 1"; exit 1 ;;
esac
case "$GENERATE_SPARKLE_UPDATE" in
  0|1) ;;
  *) print -u2 "GENERATE_SPARKLE_UPDATE must be 0 or 1"; exit 1 ;;
esac
if [[ ! -x "$RELEASE_VARIANT_RUNNER" ]]; then
  print -u2 "release variant runner is not executable: $RELEASE_VARIANT_RUNNER"
  exit 1
fi
if [[ "$RELEASE_STAGE_TIMEOUTS" == "1" && ! -x "$RELEASE_STAGE_RUNNER" ]]; then
  print -u2 "release stage runner is unavailable"
  exit 1
fi

run_variant() {
  local variant="$1"
  if [[ "$RELEASE_STAGE_TIMEOUTS" == "1" ]]; then
    "$RELEASE_STAGE_RUNNER" "$variant" signed-variant \
      "$RELEASE_VARIANT_TIMEOUT_SECONDS" -- \
      env RELEASE_VARIANT="$variant" "$RELEASE_VARIANT_RUNNER"
  else
    RELEASE_VARIANT="$variant" "$RELEASE_VARIANT_RUNNER"
  fi
}

start_variant() {
  local variant="$1"
  if [[ "$RELEASE_STAGE_TIMEOUTS" == "1" ]]; then
    "$RELEASE_STAGE_RUNNER" "$variant" signed-variant \
      "$RELEASE_VARIANT_TIMEOUT_SECONDS" -- \
      env RELEASE_VARIANT="$variant" "$RELEASE_VARIANT_RUNNER" &
  else
    RELEASE_VARIANT="$variant" "$RELEASE_VARIANT_RUNNER" &
  fi
  REPLY=$!
}

process_finished() {
  local target_pid="$1"
  local process_state
  if ! /bin/kill -0 "$target_pid" 2>/dev/null; then
    return 0
  fi
  process_state="$(/bin/ps -o stat= -p "$target_pid" 2>/dev/null | /usr/bin/tr -d ' ' || true)"
  [[ -z "$process_state" || "$process_state" == Z* ]]
}

stop_variant_job() {
  local target_pid="$1"
  local variant="$2"
  local attempt
  print -u2 "RELEASE VARIANT CANCEL variant=$variant"
  /bin/kill -TERM "$target_pid" 2>/dev/null || true
  for attempt in {1..30}; do
    /bin/kill -0 "$target_pid" 2>/dev/null || break
    /bin/sleep 0.1
  done
  /bin/kill -KILL "$target_pid" 2>/dev/null || true
  wait "$target_pid" 2>/dev/null || true
}

if [[ "$PARALLEL_RELEASE_VARIANTS" == "1" ]]; then
  start_variant apple-silicon
  apple_silicon_pid="$REPLY"
  start_variant intel
  intel_pid="$REPLY"
  apple_silicon_done=0
  intel_done=0
  while (( apple_silicon_done == 0 || intel_done == 0 )); do
    if (( apple_silicon_done == 0 )) && process_finished "$apple_silicon_pid"; then
      if wait "$apple_silicon_pid"; then apple_silicon_status=0; else apple_silicon_status=$?; fi
      apple_silicon_done=1
      if (( apple_silicon_status != 0 )); then
        (( intel_done == 0 )) && stop_variant_job "$intel_pid" intel
        print -u2 "parallel signed release variant packaging failed: apple-silicon exit=$apple_silicon_status"
        exit 1
      fi
    fi
    if (( intel_done == 0 )) && process_finished "$intel_pid"; then
      if wait "$intel_pid"; then intel_status=0; else intel_status=$?; fi
      intel_done=1
      if (( intel_status != 0 )); then
        (( apple_silicon_done == 0 )) && \
          stop_variant_job "$apple_silicon_pid" apple-silicon
        print -u2 "parallel signed release variant packaging failed: intel exit=$intel_status"
        exit 1
      fi
    fi
    (( apple_silicon_done != 0 && intel_done != 0 )) || /bin/sleep 0.2
  done
else
  run_variant apple-silicon
  run_variant intel
fi

if [[ "$GENERATE_SPARKLE_UPDATE" == "1" ]]; then
  VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
    "$ROOT/Resources/Info.plist")"
  /usr/bin/cmp -s \
    "$ROOT/dist/Remote-Mic-$VERSION.zh.txt" \
    "$ROOT/dist/intel/Remote-Mic-$VERSION-Intel.zh.txt"
  /usr/bin/cmp -s \
    "$ROOT/dist/Remote-Mic-$VERSION.en.txt" \
    "$ROOT/dist/intel/Remote-Mic-$VERSION-Intel.en.txt"
  /usr/bin/grep -Fq \
    "Remote-Mic-$VERSION.zh.txt" \
    "$ROOT/dist/intel/appcast-intel.xml"
  /usr/bin/grep -Fq \
    "Remote-Mic-$VERSION.en.txt" \
    "$ROOT/dist/intel/appcast-intel.xml"
  if /usr/bin/grep -Fq "Remote-Mic-$VERSION-Intel.zh.txt" \
      "$ROOT/dist/intel/appcast-intel.xml" || \
     /usr/bin/grep -Fq "Remote-Mic-$VERSION-Intel.en.txt" \
      "$ROOT/dist/intel/appcast-intel.xml"; then
    print -u2 "Intel appcast must reuse the shared localized release notes"
    exit 1
  fi
fi

print "SIGNED MACOS RELEASE VARIANTS PASS"
