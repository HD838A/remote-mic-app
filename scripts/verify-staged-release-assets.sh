#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${1:-}"
PUBLIC_DIR="${2:-}"

if [[ "$#" -ne 2 || ! -r "$MANIFEST" || ! -d "$PUBLIC_DIR" ]]; then
  echo "usage: $0 <staged-assets.json> <public-assets-directory>" >&2
  exit 2
fi
for command_name in jq shasum sort; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

file_size() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    /usr/bin/stat -f '%z' "$1"
  else
    /usr/bin/stat -c '%s' "$1"
  fi
}

jq -e '
  .schemaVersion == 1 and
  .repository == "HD838A/remote-mic-app" and
  (.tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
  (.sourceCommit | test("^[0-9a-f]{40}$")) and
  (.version | test("^[0-9]+[.][0-9]+[.][0-9]+$")) and
  .tag == ("v" + .version) and
  (.build | test("^[1-9][0-9]*$")) and
  (.assets | type == "array" and length == 11) and
  ([.assets[].name] | length == (unique | length)) and
  all(.assets[];
    (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.size | type == "number" and . >= 0 and floor == .) and
    (.sha256 | test("^[0-9a-f]{64}$")))
' "$MANIFEST" >/dev/null || {
  echo "staged asset manifest is invalid" >&2
  exit 1
}

version="$(jq -r '.version' "$MANIFEST")"
expected_names="$(printf '%s\n' \
  "Remote-Mic-$version-Intel-Uninstaller.pkg" \
  "Remote-Mic-$version-Intel.dmg" \
  "Remote-Mic-$version-Intel.zip" \
  "Remote-Mic-$version-Uninstaller.pkg" \
  "Remote-Mic-$version.dmg" \
  "Remote-Mic-$version.dmg.sha256" \
  "Remote-Mic-$version.en.txt" \
  "Remote-Mic-$version.zh.txt" \
  "Remote-Mic-$version.zip" \
  "appcast-intel.xml" \
  "appcast.xml" | LC_ALL=C /usr/bin/sort)"
manifest_names="$(jq -r '.assets[].name' "$MANIFEST" | LC_ALL=C /usr/bin/sort)"
[[ "$manifest_names" == "$expected_names" ]] || {
  echo "staged asset manifest does not contain the canonical 11 public payload assets" >&2
  exit 1
}
actual_names=""
while IFS= read -r file_path; do
  [[ -n "$file_path" ]] || continue
  [[ -f "$file_path" && ! -L "$file_path" ]] || {
    echo "public asset directory contains a non-regular entry: ${file_path##*/}" >&2
    exit 1
  }
  actual_names+="${file_path##*/}"$'\n'
done < <(/usr/bin/find "$PUBLIC_DIR" -mindepth 1 -maxdepth 1 -print)
actual_names="$(printf '%s' "$actual_names" | LC_ALL=C /usr/bin/sort)"
[[ "$actual_names" == "$expected_names" ]] || {
  echo "public asset directory does not exactly match staged-assets.json" >&2
  exit 1
}

while IFS=$'\t' read -r name expected_size expected_sha; do
  file_path="$PUBLIC_DIR/$name"
  actual_size="$(file_size "$file_path")"
  actual_sha="$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{print $1}')"
  [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]] || {
    echo "staged asset mismatch: $name" >&2
    exit 1
  }
done < <(jq -r '.assets[] | [.name, (.size | tostring), .sha256] | @tsv' "$MANIFEST")

echo "STAGED RELEASE ASSETS PASS"
