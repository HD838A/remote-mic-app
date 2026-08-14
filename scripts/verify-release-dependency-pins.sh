#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORKFLOWS=(
  "$ROOT/.github/workflows/mac-ci.yml"
  "$ROOT/.github/workflows/mac-preview-candidate.yml"
  "$ROOT/.github/workflows/mac-release-package.yml"
)
DEPENDENCIES=(
  "SayAllAI|GetSayAll/sayall-ai"
  "SayAllMacroPlatform|GetSayAll/sayall-macro-platform"
  "SayAllMacRemote|GetSayAll/sayall-mac-remote"
)

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

extract_ref() {
  local workflow="$1"
  local repository="$2"
  /usr/bin/awk -v repository="$repository" '
    $0 ~ "repository:[[:space:]]*" repository "[[:space:]]*$" {
      found = 1
      next
    }
    found && /^[[:space:]]*ref:[[:space:]]*/ {
      sub(/^[[:space:]]*ref:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }
    found && /repository:[[:space:]]*/ { exit 1 }
  ' "$workflow"
}

for workflow in "${WORKFLOWS[@]}"; do
  test -f "$workflow"
done

for dependency in "${DEPENDENCIES[@]}"; do
  label="${dependency%%|*}"
  repository="${dependency#*|}"
  expected_ref=""

  for workflow in "${WORKFLOWS[@]}"; do
    pinned_ref="$(extract_ref "$workflow" "$repository")"
    if [[ ! "$pinned_ref" =~ '^[0-9a-f]{40}$' ]]; then
      print -u2 "$label must use a full 40-character commit in ${workflow:t}"
      exit 1
    fi
    if [[ -z "$expected_ref" ]]; then
      expected_ref="$pinned_ref"
    elif [[ "$pinned_ref" != "$expected_ref" ]]; then
      print -u2 "$label commit differs across macOS CI, preview, and signed release workflows"
      exit 1
    fi
  done

  print "$label: $expected_ref"
done

print "RELEASE DEPENDENCY PINS PASS"
