#!/bin/zsh
set -euo pipefail

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"

# One configuration checker; keep resolve, token and pin checks independent.
case "${1:-pins}" in
  resolve)
    shift
    MANIFEST="${RELEASE_DEPENDENCIES_MANIFEST:-$ROOT/config/release-dependencies.json}"
    MODE="${1:-json}"

    if [[ "$#" -gt 1 ]]; then
      print -u2 "usage: $0 [json|github-output]"
      exit 2
    fi
    command -v jq >/dev/null 2>&1 || { print -u2 "Missing required command: jq"; exit 1; }
    [[ -r "$MANIFEST" ]] || { print -u2 "release dependency manifest is unreadable: $MANIFEST"; exit 1; }

    jq -e '
      .schemaVersion == 1 and
      (.dependencies | keys | sort) == ["sayAllAI", "sayAllMacRemote", "sayAllPrivatePlatform"] and
      .dependencies.sayAllAI.repository == "GetSayAll/sayall-ai" and
      .dependencies.sayAllPrivatePlatform.repository == "GetSayAll/sayall-private-platform" and
      .dependencies.sayAllMacRemote.repository == "GetSayAll/sayall-mac-remote" and
      ([.dependencies[] | .commit] | all(.[]; type == "string" and test("^[0-9a-f]{40}$")))
    ' "$MANIFEST" >/dev/null || {
      print -u2 "release dependency manifest has an invalid schema, repository, or commit"
      exit 1
    }

    case "$MODE" in
      json)
        jq -S -c '.dependencies' "$MANIFEST"
        ;;
      github-output)
        [[ -n "${GITHUB_OUTPUT:-}" ]] || { print -u2 "GITHUB_OUTPUT is required"; exit 2; }
        {
          print "sayall_ai_repository=$(jq -r '.dependencies.sayAllAI.repository' "$MANIFEST")"
          print "sayall_ai_commit=$(jq -r '.dependencies.sayAllAI.commit' "$MANIFEST")"
          print "sayall_private_platform_repository=$(jq -r '.dependencies.sayAllPrivatePlatform.repository' "$MANIFEST")"
          print "sayall_private_platform_commit=$(jq -r '.dependencies.sayAllPrivatePlatform.commit' "$MANIFEST")"
          print "sayall_mac_remote_repository=$(jq -r '.dependencies.sayAllMacRemote.repository' "$MANIFEST")"
          print "sayall_mac_remote_commit=$(jq -r '.dependencies.sayAllMacRemote.commit' "$MANIFEST")"
        } >> "$GITHUB_OUTPUT"
        ;;
      *)
        print -u2 "mode must be json or github-output"
        exit 2
        ;;
    esac

    exit 0
    ;;
  tokens)
    shift
    [[ "$#" -eq 0 ]] || { print -u2 "usage: $0 tokens"; exit 2; }
    umask 077
    setopt null_glob
    WORKFLOW_DIR="$ROOT/.github/workflows"

    for workflow in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
      [[ -f "$workflow" ]] || continue
      /usr/bin/awk -v workflow="$workflow" '
        function check_step() {
          if (index(step, "gh ") > 0 || index(step, "gh\t") > 0 || index(step, "gh\n") > 0) {
            if (step !~ /GH_TOKEN:[[:space:]]*\$\{\{[^}]+\}\}/) {
              print workflow ":" start_line ": a step invokes gh without an explicit step-scoped GH_TOKEN" > "/dev/stderr"
              failed = 1
            }
          }
        }
        /^      - name:/ {
          check_step()
          step = $0 "\n"
          start_line = NR
          next
        }
        { step = step $0 "\n" }
        END {
          check_step()
          exit failed
        }
      ' "$workflow"
    done

    print "RELEASE WORKFLOW GH_TOKEN PASS"

    exit 0
    ;;
  pins)
    [[ "$#" -eq 0 ]] || shift
    ;;
  *) print -u2 "usage: $0 [pins|tokens|resolve [json|github-output]]"; exit 2 ;;
esac
CONTROL_ROOT="${RELEASE_CONTROL_ROOT:-$ROOT}"
PACKAGE_MANIFEST="$ROOT/Package.swift"
PACKAGE_RESOLVED="$ROOT/Package.resolved"
DEPENDENCY_MANIFEST="$ROOT/config/release-dependencies.json"
WORKFLOWS=(
  "$CONTROL_ROOT/.github/workflows/mac-ci.yml"
  "$CONTROL_ROOT/.github/workflows/mac-release-package.yml"
)
RELEASE_CRITICAL_WORKFLOWS=(
  "$CONTROL_ROOT/.github/workflows/mac-ci.yml"
  "$CONTROL_ROOT/.github/workflows/mac-release-package.yml"
  "$CONTROL_ROOT/.github/workflows/mac-preview-publication.yml"
  "$CONTROL_ROOT/.github/workflows/mac-stable-promote.yml"
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

for workflow in "${WORKFLOWS[@]}"; do
  test -f "$workflow"
done
for workflow in "${RELEASE_CRITICAL_WORKFLOWS[@]}"; do
  test -f "$workflow"
done
test -f "$PACKAGE_MANIFEST"
test -f "$PACKAGE_RESOLVED"

test -f "$DEPENDENCY_MANIFEST"
test -x "$ROOT/scripts/verify-release-dependency-pins.sh"
dependencies_json="$(REPOSITORY_ROOT="$ROOT" "$ROOT/scripts/verify-release-dependency-pins.sh" resolve json)"
sayall_ai_commit="$(print -r -- "$dependencies_json" | jq -r '.sayAllAI.commit')"
sayall_private_platform_commit="$(print -r -- "$dependencies_json" | jq -r '.sayAllPrivatePlatform.commit')"
sayall_mac_remote_commit="$(print -r -- "$dependencies_json" | jq -r '.sayAllMacRemote.commit')"

for workflow in "${WORKFLOWS[@]}"; do
  grep -Fq 'verify-release-dependency-pins.sh resolve' "$workflow" || {
    print -u2 "${workflow:t} must resolve the versioned release dependency manifest"
    exit 1
  }
  for commit in "$sayall_ai_commit" "$sayall_private_platform_commit" "$sayall_mac_remote_commit"; do
    if grep -Fq "$commit" "$workflow"; then
      print -u2 "${workflow:t} must not duplicate a product dependency commit outside the versioned manifest"
      exit 1
    fi
  done
done

grep -Fq '${{ steps.release-dependencies.outputs.sayall_ai_commit }}' "$CONTROL_ROOT/.github/workflows/mac-ci.yml"
grep -Fq '${{ steps.release-dependencies.outputs.sayall_private_platform_commit }}' "$CONTROL_ROOT/.github/workflows/mac-ci.yml"
grep -Fq '${{ steps.release-dependencies.outputs.sayall_mac_remote_commit }}' "$CONTROL_ROOT/.github/workflows/mac-ci.yml"
grep -Fq '${{ steps.release-dependencies.outputs.sayall_ai_commit }}' "$CONTROL_ROOT/.github/workflows/mac-release-package.yml"
grep -Fq '${{ steps.release-dependencies.outputs.sayall_private_platform_commit }}' "$CONTROL_ROOT/.github/workflows/mac-release-package.yml"
grep -Fq '${{ steps.release-dependencies.outputs.sayall_mac_remote_commit }}' "$CONTROL_ROOT/.github/workflows/mac-release-package.yml"

grep -Fq 'SAYALL_MAC_REMOTE_PACKAGE_PATH' "$PACKAGE_MANIFEST"
grep -Fq 'SAYALL_MAC_REMOTE_PACKAGE_PATH=$GITHUB_WORKSPACE/.private-dependencies/sayall-mac-remote' \
  "$CONTROL_ROOT/.github/workflows/mac-release-package.yml"
if grep -Fq 'https://github.com/GetSayAll/sayall-mac-remote.git' "$PACKAGE_MANIFEST" || \
   grep -Fq '"identity" : "sayall-mac-remote"' "$PACKAGE_RESOLVED"; then
  print -u2 "public SwiftPM metadata must not resolve the private SayAllMacRemote repository"
  exit 1
fi

print "SayAllAI: $sayall_ai_commit"
print "SayAllPrivatePlatform: $sayall_private_platform_commit"
print "SayAllMacRemote: $sayall_mac_remote_commit"

for credential_repository in "${CREDENTIAL_REPOSITORIES[@]}"; do
  label="${credential_repository%%|*}"
  remainder="${credential_repository#*|}"
  repository="${remainder%%|*}"
  expected_ref="${remainder#*|}"
  pinned_ref="$(extract_ref "$CONTROL_ROOT/.github/workflows/mac-release-package.yml" "$repository" "")"
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
