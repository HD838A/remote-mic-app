#!/bin/zsh
set -euo pipefail

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
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
  (.dependencies | keys | sort) == ["sayAllAI", "sayAllMacRemote", "sayAllMacroPlatform"] and
  .dependencies.sayAllAI.repository == "GetSayAll/sayall-ai" and
  .dependencies.sayAllMacroPlatform.repository == "GetSayAll/sayall-macro-platform" and
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
      print "sayall_macro_platform_repository=$(jq -r '.dependencies.sayAllMacroPlatform.repository' "$MANIFEST")"
      print "sayall_macro_platform_commit=$(jq -r '.dependencies.sayAllMacroPlatform.commit' "$MANIFEST")"
      print "sayall_mac_remote_repository=$(jq -r '.dependencies.sayAllMacRemote.repository' "$MANIFEST")"
      print "sayall_mac_remote_commit=$(jq -r '.dependencies.sayAllMacRemote.commit' "$MANIFEST")"
    } >> "$GITHUB_OUTPUT"
    ;;
  *)
    print -u2 "mode must be json or github-output"
    exit 2
    ;;
esac
