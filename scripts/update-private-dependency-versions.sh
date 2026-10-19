#!/bin/zsh
set -euo pipefail

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
MANIFEST="${RELEASE_DEPENDENCIES_MANIFEST:-$ROOT/config/release-dependencies.json}"

command -v jq >/dev/null 2>&1 || { print -u2 "Missing required command: jq"; exit 1; }
command -v git >/dev/null 2>&1 || { print -u2 "Missing required command: git"; exit 1; }
[[ -r "$MANIFEST" ]] || { print -u2 "release dependency manifest is unreadable: $MANIFEST"; exit 1; }

if [[ "${1:-}" == --publish ]]; then
  [[ "$#" == 1 ]] || { print -u2 "usage: $0 [--publish]"; exit 2; }
  branch="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)" || {
    print -u2 "Create a host PR branch before publishing and updating its dependency pin"; exit 1
  }
  [[ "$branch" != main ]] || {
    print -u2 "Do not update dependency pins on main; create a host PR branch"; exit 1
  }
  # Release only an already reviewed VERSION on private main. It never pushes main.
  python3 "$ROOT/scripts/prepare-private-platform.py" release >/dev/null
elif [[ "$#" != 0 ]]; then
  print -u2 "usage: $0 [--publish]"; exit 2
fi

private_platform_key="${SAYALL_PRIVATE_PLATFORM_DEPLOY_KEY:-}"
sayall_ai_key="${SAYALL_AI_DEPLOY_KEY:-}"

latest_tag() {
  local repository="$1"
  local key="$2"
  if [[ -z "$key" ]]; then
    git ls-remote --tags "https://github.com/$repository.git" 'refs/tags/[0-9]*' |
      awk -F/ '/refs\/tags\/[0-9]+\.[0-9]+\.[0-9]+$/ { print $NF }' | sort -V | tail -n 1
    return
  fi

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
latest_private_platform="$(latest_tag "$(jq -r '.dependencies.sayAllPrivatePlatform.repository' "$MANIFEST")" "$private_platform_key")"
[[ "$latest_private_platform" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { print -u2 "No valid private platform SwiftPM version tag found"; exit 1; }

latest_ai="$current_ai"
if [[ -n "$sayall_ai_key" ]]; then
  latest_ai="$(latest_tag "$(jq -r '.dependencies.sayAllAI.repository' "$MANIFEST")" "$sayall_ai_key")"
  [[ "$latest_ai" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { print -u2 "No valid SayAllAI SwiftPM version tag found"; exit 1; }
else
  print "SayAllAI deploy key unavailable; keeping the optional AI version at $current_ai"
fi

if [[ "$latest_ai" == "$current_ai" && "$latest_private_platform" == "$current_private_platform" ]]; then
  print "Private dependency versions are current: platform=$current_private_platform, ai=$current_ai"
  exit 0
fi

next_manifest="$MANIFEST.next"
jq --arg ai_version "$latest_ai" \
  --arg platform_version "$latest_private_platform" \
  '.dependencies.sayAllAI.version = $ai_version |
   .dependencies.sayAllPrivatePlatform.version = $platform_version' \
  "$MANIFEST" > "$next_manifest"
mv -f "$next_manifest" "$MANIFEST"
print "Private dependency versions: platform=$current_private_platform -> $latest_private_platform, ai=$current_ai -> $latest_ai"
