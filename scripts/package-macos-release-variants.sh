#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PARALLEL_RELEASE_VARIANTS="${PARALLEL_RELEASE_VARIANTS:-0}"
RELEASE_VARIANT_RUNNER="${RELEASE_VARIANT_RUNNER:-$ROOT/scripts/notarize-release.sh}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi
case "$PARALLEL_RELEASE_VARIANTS" in
  0|1) ;;
  *) print -u2 "PARALLEL_RELEASE_VARIANTS must be 0 or 1"; exit 1 ;;
esac
if [[ ! -x "$RELEASE_VARIANT_RUNNER" ]]; then
  print -u2 "release variant runner is not executable: $RELEASE_VARIANT_RUNNER"
  exit 1
fi

run_variant() {
  local variant="$1"
  RELEASE_VARIANT="$variant" "$RELEASE_VARIANT_RUNNER"
}

if [[ "$PARALLEL_RELEASE_VARIANTS" == "1" ]]; then
  variant_failed=0
  run_variant apple-silicon &
  apple_silicon_pid=$!
  run_variant intel &
  intel_pid=$!
  wait "$apple_silicon_pid" || variant_failed=1
  wait "$intel_pid" || variant_failed=1
  if (( variant_failed != 0 )); then
    print -u2 "parallel signed release variant packaging failed"
    exit 1
  fi
else
  run_variant apple-silicon
  run_variant intel
fi

print "SIGNED MACOS RELEASE VARIANTS PASS"
