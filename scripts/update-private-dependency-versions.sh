#!/bin/zsh
set -euo pipefail

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
MANIFEST="${RELEASE_DEPENDENCIES_MANIFEST:-$ROOT/config/release-dependencies.json}"

command -v jq >/dev/null 2>&1 || { print -u2 "Missing required command: jq"; exit 1; }
command -v git >/dev/null 2>&1 || { print -u2 "Missing required command: git"; exit 1; }
[[ -r "$MANIFEST" ]] || { print -u2 "release dependency manifest is unreadable: $MANIFEST"; exit 1; }

private_platform_key="${SAYALL_PRIVATE_PLATFORM_DEPLOY_KEY:-}"
sayall_ai_key="${SAYALL_AI_DEPLOY_KEY:-}"

latest_tag() {
  local repository="$1"
  local key="$2"
  [[ -n "$key" ]] || { print -u2 "Missing deploy key for $repository"; exit 1; }

  local agent_pid
  eval "$(ssh-agent -s)" >/dev/null
  agent_pid="$SSH_AGENT_PID"
  trap 'kill "$agent_pid" >/dev/null 2>&1 || true; unset SSH_AUTH_SOCK SSH_AGENT_PID' RETURN
  printf '%s\n' "$key" | ssh-add - >/dev/null
  GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \
    git ls-remote --tags "git@github.com:$repository.git" 'refs/tags/[0-9]*' |
    awk -F/ '/refs\/tags\/[0-9]+\.[0-9]+\.[0-9]+(\^\{\})?$/ {
      tag=$NF
      sub(/\^\{\}$/, "", tag)
      print tag
    }' |
    sort -V |
    tail -n 1
  kill "$agent_pid" >/dev/null 2>&1 || true
  trap - RETURN
}

current_ai="$(jq -r '.dependencies.sayAllAI.version' "$MANIFEST")"
current_private_platform="$(jq -r '.dependencies.sayAllPrivatePlatform.version' "$MANIFEST")"
latest_ai="$(latest_tag "$(jq -r '.dependencies.sayAllAI.repository' "$MANIFEST")" "$sayall_ai_key")"
latest_private_platform="$(latest_tag "$(jq -r '.dependencies.sayAllPrivatePlatform.repository' "$MANIFEST")" "$private_platform_key")"

[[ "$latest_ai" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { print -u2 "No valid SayAllAI SwiftPM version tag found"; exit 1; }
[[ "$latest_private_platform" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { print -u2 "No valid private platform SwiftPM version tag found"; exit 1; }
[[ "$latest_ai" == "$latest_private_platform" ]] || {
  print -u2 "Private repositories must publish the same SwiftPM version: SayAllAI=$latest_ai, SayAllPrivatePlatform=$latest_private_platform"
  exit 1
}

if [[ "$latest_ai" == "$current_ai" && "$latest_ai" == "$current_private_platform" ]]; then
  print "Private dependency version is current: $current_ai"
  exit 0
fi

next_manifest="$MANIFEST.next"
jq --arg version "$latest_ai" \
  '.dependencies.sayAllAI.version = $version |
   .dependencies.sayAllPrivatePlatform.version = $version' \
  "$MANIFEST" > "$next_manifest"
mv -f "$next_manifest" "$MANIFEST"
print "Private dependency version: $current_ai/$current_private_platform -> $latest_ai"
