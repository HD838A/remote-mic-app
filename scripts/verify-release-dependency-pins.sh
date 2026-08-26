#!/bin/zsh
set -euo pipefail

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
PACKAGE_MANIFEST="$ROOT/Package.swift"
PACKAGE_RESOLVED="$ROOT/Package.resolved"
DEPENDENCY_MANIFEST="$ROOT/config/release-dependencies.json"
WORKFLOWS=(
  "$ROOT/.github/workflows/mac-ci.yml"
  "$ROOT/.github/workflows/mac-release-package.yml"
)
RELEASE_CRITICAL_WORKFLOWS=(
  "$ROOT/.github/workflows/mac-ci.yml"
  "$ROOT/.github/workflows/mac-release-package.yml"
  "$ROOT/.github/workflows/mac-preview-publication.yml"
  "$ROOT/.github/workflows/mac-stable-promote.yml"
)
CREDENTIAL_REPOSITORIES=(
  "ReleaseNotarySecrets|HD838A/remotemic-notary-secrets|5baaeaf56f6cd5fbd0fb0e08c9290077ba8b5b5d"
  "AppleSigningMatch|HD838A/apple-signing-match|2e271768593821611c54f3d1b376f39e503f53be"
)
ACTION_PINS=(
  "actions/checkout|fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"
  "actions/download-artifact|634f93cb2916e3fdff6788551b99b062d0335ce0"
  "actions/upload-artifact|ea165f8d65b6e75b540449e92b4886f43607fa02"
)

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi
for command_name in jq grep; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

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
for workflow in "${RELEASE_CRITICAL_WORKFLOWS[@]}"; do
  test -f "$workflow"
done
test -f "$PACKAGE_MANIFEST"
test -f "$PACKAGE_RESOLVED"

test -f "$DEPENDENCY_MANIFEST"
test -x "$ROOT/scripts/resolve-release-dependencies.sh"
dependencies_json="$(REPOSITORY_ROOT="$ROOT" "$ROOT/scripts/resolve-release-dependencies.sh" json)"
sayall_ai_commit="$(print -r -- "$dependencies_json" | jq -r '.sayAllAI.commit')"
sayall_macro_platform_commit="$(print -r -- "$dependencies_json" | jq -r '.sayAllMacroPlatform.commit')"
sayall_mac_remote_commit="$(print -r -- "$dependencies_json" | jq -r '.sayAllMacRemote.commit')"

for workflow in "${WORKFLOWS[@]}"; do
  grep -Fq 'resolve-release-dependencies.sh' "$workflow" || {
    print -u2 "${workflow:t} must resolve the versioned release dependency manifest"
    exit 1
  }
  for commit in "$sayall_ai_commit" "$sayall_macro_platform_commit" "$sayall_mac_remote_commit"; do
    if grep -Fq "$commit" "$workflow"; then
      print -u2 "${workflow:t} must not duplicate a product dependency commit outside the versioned manifest"
      exit 1
    fi
  done
done

grep -Fq '${{ steps.release-dependencies.outputs.sayall_ai_commit }}' "$ROOT/.github/workflows/mac-ci.yml"
grep -Fq '${{ steps.release-dependencies.outputs.sayall_macro_platform_commit }}' "$ROOT/.github/workflows/mac-ci.yml"
grep -Fq '${{ steps.release-dependencies.outputs.sayall_mac_remote_commit }}' "$ROOT/.github/workflows/mac-ci.yml"
grep -Fq '${{ steps.release-dependencies.outputs.sayall_ai_commit }}' "$ROOT/.github/workflows/mac-release-package.yml"
grep -Fq '${{ steps.release-dependencies.outputs.sayall_macro_platform_commit }}' "$ROOT/.github/workflows/mac-release-package.yml"
grep -Fq '${{ steps.release-dependencies.outputs.sayall_mac_remote_commit }}' "$ROOT/.github/workflows/mac-release-package.yml"

manifest_ref="$(extract_manifest_ref)"
resolved_ref="$(extract_resolved_ref)"
if [[ "$manifest_ref" != "$sayall_mac_remote_commit" || "$resolved_ref" != "$sayall_mac_remote_commit" ]]; then
  print -u2 "SayAllMacRemote commit differs across the versioned manifest, Package.swift, and Package.resolved"
  exit 1
fi

print "SayAllAI: $sayall_ai_commit"
print "SayAllMacroPlatform: $sayall_macro_platform_commit"
print "SayAllMacRemote: $sayall_mac_remote_commit"

for credential_repository in "${CREDENTIAL_REPOSITORIES[@]}"; do
  label="${credential_repository%%|*}"
  remainder="${credential_repository#*|}"
  repository="${remainder%%|*}"
  expected_ref="${remainder#*|}"
  pinned_ref="$(extract_ref "$ROOT/.github/workflows/mac-release-package.yml" "$repository" "")"
  if [[ "$pinned_ref" != "$expected_ref" ]]; then
    print -u2 "$label must use reviewed immutable commit $expected_ref in mac-release-package.yml"
    exit 1
  fi
  print "$label: $pinned_ref"
done

typeset -A expected_action_pins
for action_pin in "${ACTION_PINS[@]}"; do
  expected_action_pins["${action_pin%%|*}"]="${action_pin#*|}"
done

for workflow in "${RELEASE_CRITICAL_WORKFLOWS[@]}"; do
  action_refs=("${(@f)$(/usr/bin/awk '
    /^[[:space:]]*uses:[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*uses:[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      print value
    }
  ' "$workflow")}")
  for action_ref in "${action_refs[@]}"; do
    [[ -n "$action_ref" ]] || continue
    [[ "$action_ref" == ./* ]] && continue
    action_name="${action_ref%%@*}"
    action_commit="${action_ref##*@}"
    if [[ "$action_name" == "$action_ref" || ! "$action_commit" =~ '^[0-9a-f]{40}$' ]]; then
      print -u2 "release-critical action must use a full 40-character commit in ${workflow:t}: $action_ref"
      exit 1
    fi
    if (( ${+expected_action_pins[$action_name]} )) && \
       [[ "$action_commit" != "${expected_action_pins[$action_name]}" ]]; then
      print -u2 "$action_name must use reviewed immutable commit ${expected_action_pins[$action_name]} in ${workflow:t}"
      exit 1
    fi
  done
done

print "RELEASE DEPENDENCY PINS PASS"
