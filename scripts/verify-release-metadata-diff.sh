#!/usr/bin/env bash
set -euo pipefail

BASE_SHA="${1:-}"
HEAD_SHA="${2:-}"
BRANCH="${3:-}"

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 <base-sha> <head-sha> <release/pre-vX.Y.Z>" >&2
  exit 2
fi
if [[ ! "$BASE_SHA" =~ ^[0-9a-f]{40}$ || ! "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "release metadata verification requires full base and head SHAs" >&2
  exit 2
fi
if [[ ! "$BRANCH" =~ ^release/pre-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release metadata verification requires release/pre-vX.Y.Z" >&2
  exit 1
fi
if [[ "$(git rev-parse "$HEAD_SHA^")" != "$BASE_SHA" ||
      "$(git rev-list --count "$BASE_SHA..$HEAD_SHA")" != "1" ]]; then
  echo "release metadata candidate must be one direct commit after base main" >&2
  exit 1
fi

required_info_plist=false
required_en_history=false
required_zh_history=false
while IFS= read -r changed_path; do
  [[ -n "$changed_path" ]] || continue
  case "$changed_path" in
    Resources/Info.plist) required_info_plist=true ;;
    Resources/en.lproj/ReleaseHistory.md) required_en_history=true ;;
    Resources/zh-Hans.lproj/ReleaseHistory.md) required_zh_history=true ;;
    Testing/*.md) ;;
    *)
      echo "release metadata candidate contains non-release change: $changed_path" >&2
      exit 1
      ;;
  esac
done < <(git diff --name-only "$BASE_SHA...$HEAD_SHA")

if [[ "$required_info_plist" != "true" ||
      "$required_en_history" != "true" ||
      "$required_zh_history" != "true" ]]; then
  echo "release metadata candidate requires Info.plist and both ReleaseHistory files" >&2
  exit 1
fi

echo "RELEASE METADATA DIFF PASS"
