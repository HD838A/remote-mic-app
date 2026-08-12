#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

RELEASE_VARIANT=apple-silicon "$ROOT/scripts/notarize-release.sh"
RELEASE_VARIANT=intel "$ROOT/scripts/notarize-release.sh"

print "SIGNED MACOS RELEASE VARIANTS PASS"
