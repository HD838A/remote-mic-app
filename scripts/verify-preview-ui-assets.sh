#!/usr/bin/env bash
set -euo pipefail
umask 022

MANIFEST="${1:-}"
PUBLIC_DIR="${2:-}"

if [[ "$#" -ne 2 || ! -r "$MANIFEST" || ! -d "$PUBLIC_DIR" ]]; then
  echo "usage: $0 <staged-assets.json> <public-directory>" >&2
  exit 2
fi
for command_name in jq shasum wc tr awk grep; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

fail() {
  echo "preview UI asset check failed: $1" >&2
  exit 1
}

version="$(jq -r '.version // empty' "$MANIFEST")"
build="$(jq -r '.build // empty' "$MANIFEST")"
tag="$(jq -r '.tag // empty' "$MANIFEST")"
source_commit="$(jq -r '.sourceCommit // empty' "$MANIFEST")"
schema_version="$(jq -r '.schemaVersion // empty' "$MANIFEST")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || fail "manifest version/build is invalid"
[[ "$tag" == "v$version" ]] || fail "manifest tag does not match the version"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || fail "manifest source commit is invalid"
case "$schema_version" in
  1) prefix="Remote-Mic-$version" ;;
  2) prefix="SayAll-$version-$build" ;;
  *) fail "unsupported manifest schema: $schema_version" ;;
esac
archive="$prefix.zip"
notes_zh="$prefix.zh.txt"
notes_en="$prefix.en.txt"

for name in appcast.xml "$archive" "$notes_zh" "$notes_en"; do
  path="$PUBLIC_DIR/$name"
  [[ -f "$path" && ! -L "$path" ]] || fail "missing regular UI asset: $name"
  expected="$(jq -r --arg name "$name" '
    [.assets[] | select(.name == $name)] |
    if length == 1 then "\(.[0].sha256) \(.[0].size)" else empty end
  ' "$MANIFEST")"
  [[ -n "$expected" ]] || fail "manifest has no unique entry for $name"
  read -r expected_sha expected_size <<< "$expected"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ && "$expected_size" =~ ^[1-9][0-9]*$ ]] || \
    fail "manifest entry for $name is invalid"
  actual_sha="$(shasum -a 256 "$path" | awk '{print $1}')"
  actual_size="$(wc -c < "$path" | tr -d ' ')"
  [[ "$actual_sha" == "$expected_sha" && "$actual_size" == "$expected_size" ]] || \
    fail "UI asset does not match the manifest: $name"
done

appcast="$PUBLIC_DIR/appcast.xml"
grep -Fq "url=\"https://download.sayall.app/mac/releases/$tag/$archive\"" "$appcast" || \
  fail "appcast does not reference the staged archive"
grep -Fq "$notes_zh" "$appcast" || fail "appcast has no Chinese release notes link"
grep -Fq "$notes_en" "$appcast" || fail "appcast has no English release notes link"

echo "PREVIEW UI ASSETS PASS"
echo "ARCHIVE: $archive"
echo "SOURCE_COMMIT: $source_commit"
