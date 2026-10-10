#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${1:-}"
PUBLIC_DIR="${2:-}"

if [[ "$#" -ne 2 || ! -r "$MANIFEST" || ! -d "$PUBLIC_DIR" ]]; then
  echo "usage: $0 <staged-assets.json> <public-assets-directory>" >&2
  exit 2
fi
for command_name in jq shasum sort python3; do
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
  (.schemaVersion == 1 or .schemaVersion == 2) and
  .repository == "HD838A/remote-mic-app" and
  (.tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
  (.sourceCommit | test("^[0-9a-f]{40}$")) and
  (.version | test("^[0-9]+[.][0-9]+[.][0-9]+$")) and
  .tag == ("v" + .version) and
  (.build | test("^[1-9][0-9]*$")) and
  (.assets | type == "array" and length == 10) and
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
asset_prefix=SayAll
if [[ "$(jq -r '.schemaVersion' "$MANIFEST")" == 1 ]]; then
  asset_prefix=Remote-Mic
fi
expected_names="$(printf '%s\n' \
  "SayAll-$version-Intel-Uninstaller.pkg" \
  "SayAll-$version-Intel-Installer.pkg" \
  "$asset_prefix-$version-Intel.zip" \
  "SayAll-$version-Uninstaller.pkg" \
  "SayAll-$version-Installer.pkg" \
  "$asset_prefix-$version.en.txt" \
  "$asset_prefix-$version.zh.txt" \
  "$asset_prefix-$version.zip" \
  "appcast-intel.xml" \
  "appcast.xml" | LC_ALL=C /usr/bin/sort)"
manifest_names="$(jq -r '.assets[].name' "$MANIFEST" | LC_ALL=C /usr/bin/sort)"
[[ "$manifest_names" == "$expected_names" ]] || {
  echo "staged asset manifest does not contain the canonical 13 public payload assets" >&2
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

# Check parsed URLs and metadata, not text that can also occur in comments.
python3 - "$MANIFEST" "$PUBLIC_DIR" "$asset_prefix" <<'PYTHON'
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

manifest = json.loads(Path(sys.argv[1]).read_text())
public = Path(sys.argv[2])
prefix = sys.argv[3]
version, build = manifest["version"], manifest["build"]
url_prefix = f"https://download.sayall.app/mac/releases/{manifest['tag']}/"
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
try:
    for feed, suffix in [("appcast.xml", ""), ("appcast-intel.xml", "-Intel")]:
        root = ET.parse(public / feed).getroot()
        items = root.findall("./channel/item")
        assert len(items) == 1, "expected one candidate item"
        item = items[0]
        assert item.findtext(ns + "version") == build, "wrong Build"
        assert item.findtext(ns + "shortVersionString") == version, "wrong version"
        enclosures = item.findall("enclosure")
        assert len(enclosures) == 1, "expected one enclosure"
        enclosure = enclosures[0]
        archive = f"{prefix}-{version}{suffix}.zip"
        assert enclosure.get("url") == url_prefix + archive, "wrong archive URL or architecture"
        assert enclosure.get("length") == str((public / archive).stat().st_size), "wrong archive length"
        assert enclosure.get("type") == "application/octet-stream", "wrong archive type"
        assert re.fullmatch(r"[A-Za-z0-9+/]{86}==", enclosure.get(ns + "edSignature", "")), "missing archive signature"
        notes = item.findall(ns + "releaseNotesLink")
        assert len(notes) == 2, "expected shared English and Chinese notes"
        assert {note.text for note in notes} == {
            url_prefix + f"{prefix}-{version}.en.txt",
            url_prefix + f"{prefix}-{version}.zh.txt",
        }, "wrong release notes URLs"
        if manifest["schemaVersion"] == 2:
            assert "Remote-Mic-" not in (public / feed).read_text(), "legacy asset name in new feed"
except (AssertionError, ET.ParseError, OSError) as error:
    sys.exit(f"Sparkle appcast validation failed: {error}")
PYTHON

echo "STAGED RELEASE ASSETS PASS"
