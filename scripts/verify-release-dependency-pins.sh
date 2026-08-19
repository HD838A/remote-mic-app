#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PACKAGE_MANIFEST="$ROOT/Package.swift"
PACKAGE_RESOLVED="$ROOT/Package.resolved"
WORKFLOWS=(
  "$ROOT/.github/workflows/mac-ci.yml"
  "$ROOT/.github/workflows/mac-preview-candidate.yml"
  "$ROOT/.github/workflows/mac-release-package.yml"
)
DEPENDENCIES=(
  "SayAllAI|GetSayAll/sayall-ai|SAYALL_AI_RELEASE_REF"
  "SayAllMacroPlatform|GetSayAll/sayall-macro-platform|SAYALL_MACRO_PLATFORM_RELEASE_REF"
  "SayAllMacRemote|GetSayAll/sayall-mac-remote|SAYALL_MAC_REMOTE_RELEASE_REF"
)

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

extract_ref() {
  local workflow="$1"
  local repository="$2"
  local variable_name="$3"
  /usr/bin/awk -v repository="$repository" -v variable_name="$variable_name" '
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
    $0 ~ "^[[:space:]]*" variable_name ":[[:space:]]*" {
      value = $0
      sub("^[[:space:]]*" variable_name ":[[:space:]]*", "", value)
      gsub(/[[:space:]]+$/, "", value)
      fallback = value
    }
    END {
      if (!found && fallback != "") print fallback
    }
  ' "$workflow"
}

extract_manifest_ref() {
  /usr/bin/awk '
    /url:[[:space:]]*"https:\/\/github.com\/GetSayAll\/sayall-mac-remote.git"/ {
      found = 1
      next
    }
    found && /revision:[[:space:]]*"/ {
      sub(/^.*revision:[[:space:]]*"/, "")
      sub(/".*$/, "")
      print
      exit
    }
  ' "$PACKAGE_MANIFEST"
}

extract_resolved_ref() {
  /usr/bin/awk '
    /"identity"[[:space:]]*:[[:space:]]*"sayall-mac-remote"/ {
      found = 1
      next
    }
    found && /"revision"[[:space:]]*:/ {
      sub(/^.*"revision"[[:space:]]*:[[:space:]]*"/, "")
      sub(/".*$/, "")
      print
      exit
    }
  ' "$PACKAGE_RESOLVED"
}

for workflow in "${WORKFLOWS[@]}"; do
  test -f "$workflow"
done
test -f "$PACKAGE_MANIFEST"
test -f "$PACKAGE_RESOLVED"

for dependency in "${DEPENDENCIES[@]}"; do
  label="${dependency%%|*}"
  remainder="${dependency#*|}"
  repository="${remainder%%|*}"
  variable_name="${remainder#*|}"
  expected_ref=""

  for workflow in "${WORKFLOWS[@]}"; do
    pinned_ref="$(extract_ref "$workflow" "$repository" "$variable_name")"
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

  if [[ "$label" == "SayAllMacRemote" ]]; then
    manifest_ref="$(extract_manifest_ref)"
    resolved_ref="$(extract_resolved_ref)"
    if [[ ! "$manifest_ref" =~ '^[0-9a-f]{40}$' ]]; then
      print -u2 "$label must use a full 40-character revision in Package.swift"
      exit 1
    fi
    if [[ ! "$resolved_ref" =~ '^[0-9a-f]{40}$' ]]; then
      print -u2 "$label must use a full 40-character revision in Package.resolved"
      exit 1
    fi
    if [[ "$manifest_ref" != "$expected_ref" || "$resolved_ref" != "$expected_ref" ]]; then
      print -u2 "$label commit differs across Package.swift, Package.resolved, and macOS workflows"
      exit 1
    fi
  fi

  print "$label: $expected_ref"
done

print "RELEASE DEPENDENCY PINS PASS"
