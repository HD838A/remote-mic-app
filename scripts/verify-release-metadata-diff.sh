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
  echo "release metadata verification requires the single candidate branch release/pre-vX.Y.Z" >&2
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
changed_file_count=0
while IFS= read -r changed_path; do
  [[ -n "$changed_path" ]] || continue
  changed_file_count=$(( changed_file_count + 1 ))
  case "$changed_path" in
    Resources/Info.plist) required_info_plist=true ;;
    Resources/en.lproj/ReleaseHistory.md) required_en_history=true ;;
    Resources/zh-Hans.lproj/ReleaseHistory.md) required_zh_history=true ;;
    *)
      echo "release metadata candidate contains non-release change: $changed_path" >&2
      exit 1
      ;;
  esac
done < <(git diff --name-only "$BASE_SHA...$HEAD_SHA")

if [[ "$required_info_plist" != "true" ||
      "$required_en_history" != "true" ||
      "$required_zh_history" != "true" ||
      "$changed_file_count" -ne 3 ]]; then
  echo "release metadata candidate requires exactly Info.plist and both ReleaseHistory files" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sayall-release-metadata.XXXXXX")"

normalize_info_plist() {
  awk '
    /<key>CFBundleShortVersionString<\/key>/ {
      print
      if (getline <= 0) exit 2
      sub(/<string>[^<]*<\/string>/, "<string>__VERSION__<\/string>")
      print
      next
    }
    /<key>CFBundleVersion<\/key>/ {
      print
      if (getline <= 0) exit 2
      sub(/<string>[^<]*<\/string>/, "<string>__BUILD__<\/string>")
      print
      next
    }
    { print }
  '
}

git show "$BASE_SHA:Resources/Info.plist" | normalize_info_plist > "$WORK_DIR/base.plist"
git show "$HEAD_SHA:Resources/Info.plist" | normalize_info_plist > "$WORK_DIR/head.plist"
if ! cmp -s "$WORK_DIR/base.plist" "$WORK_DIR/head.plist"; then
  echo "release metadata candidate may change only version/build values in Info.plist" >&2
  exit 1
fi

echo "RELEASE METADATA DIFF PASS"
