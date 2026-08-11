#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

for forbidden_path in \
  Apps/RemoteMicIOS \
  Apps/MobileWeb \
  .github/workflows/ios-ci.yml \
  .github/workflows/web-ci.yml; do
  if [[ -n "$(git ls-files -- "$forbidden_path")" ]]; then
    print -u2 "migrated component path returned to Mac repository: $forbidden_path"
    exit 1
  fi
done

print "REPOSITORY BOUNDARY PASS"
