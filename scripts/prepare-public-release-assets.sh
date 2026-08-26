#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
DIST="${1:-}"
BUNDLE="${2:-}"

if [[ "$#" -ne 2 || ! -d "$DIST" || -z "$BUNDLE" ]]; then
  print -u2 "usage: $0 <signed-dist-directory> <new-bundle-directory>"
  exit 2
fi
[[ ! -e "$BUNDLE" ]] || {
  print -u2 "bundle directory already exists: $BUNDLE"
  exit 1
}
for command_name in git jq plutil rg shasum stat ditto; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

version="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
build="$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
source_commit="$(git -C "$ROOT" rev-parse HEAD)"
tag="v$version"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || {
  print -u2 "release version/build is invalid"
  exit 1
}
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || {
  print -u2 "release source commit is invalid"
  exit 1
}

public_dir="$BUNDLE/public"
/bin/mkdir -p "$public_dir"

copy_asset() {
  local source_file="$1" published_name="$2"
  [[ -f "$source_file" && ! -L "$source_file" ]] || {
    print -u2 "required signed release asset is missing or unsafe: $source_file"
    exit 1
  }
  /usr/bin/ditto --norsrc --noqtn --noacl "$source_file" "$public_dir/$published_name"
  /usr/bin/cmp -s "$source_file" "$public_dir/$published_name"
}

copy_asset "$DIST/Uninstall Remote Mic.pkg" "Remote-Mic-$version-Uninstaller.pkg"
copy_asset "$DIST/Remote-Mic-$version.dmg" "Remote-Mic-$version.dmg"
copy_asset "$DIST/Remote-Mic-$version.zip" "Remote-Mic-$version.zip"
copy_asset "$DIST/appcast.xml" appcast.xml
copy_asset "$DIST/Remote-Mic-$version.zh.txt" "Remote-Mic-$version.zh.txt"
copy_asset "$DIST/Remote-Mic-$version.en.txt" "Remote-Mic-$version.en.txt"
copy_asset "$DIST/intel/Uninstall Remote Mic Intel.pkg" "Remote-Mic-$version-Intel-Uninstaller.pkg"
copy_asset "$DIST/intel/Remote-Mic-$version-Intel.dmg" "Remote-Mic-$version-Intel.dmg"
copy_asset "$DIST/intel/Remote-Mic-$version-Intel.zip" "Remote-Mic-$version-Intel.zip"
copy_asset "$DIST/intel/appcast-intel.xml" appcast-intel.xml

(
  cd "$public_dir"
  /usr/bin/shasum -a 256 \
    "Remote-Mic-$version.dmg" \
    "Remote-Mic-$version-Intel.dmg" \
    > "Remote-Mic-$version.dmg.sha256"
  /usr/bin/shasum -a 256 -c "Remote-Mic-$version.dmg.sha256"
)

production_prefix="https://download.sayall.app/mac/releases/$tag/"
/usr/bin/grep -Fq "url=\"$production_prefix" "$public_dir/appcast.xml"
/usr/bin/grep -Fq "url=\"$production_prefix" "$public_dir/appcast-intel.xml"
/usr/bin/grep -Fq "<sparkle:version>$build</sparkle:version>" "$public_dir/appcast.xml"
/usr/bin/grep -Fq "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" "$public_dir/appcast.xml"
/usr/bin/grep -Fq "<sparkle:version>$build</sparkle:version>" "$public_dir/appcast-intel.xml"
/usr/bin/grep -Fq "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" "$public_dir/appcast-intel.xml"

{
  print "## 更新内容"
  print
  /usr/bin/awk -v version="$version" '
    index($0, "## " version) == 1 { active = 1; next }
    active && /^## / { exit }
    active { print }
  ' "$ROOT/Resources/zh-Hans.lproj/ReleaseHistory.md"
} > "$BUNDLE/release-notes.md"
rg -q '^- ' "$BUNDLE/release-notes.md"
if rg -i -q \
  '((连续|连点|点击|轻点).{0,24}(版本号|当前版本).{0,24}(次|隐藏|入口))|((tap|click).{0,24}(version|build).{0,24}(times|hidden|secret|invite|enrollment))|(隐藏入口|秘密手势|secret gesture|hidden entry|invitation-code entry)' \
  "$ROOT/Resources/zh-Hans.lproj/ReleaseHistory.md" \
  "$ROOT/Resources/en.lproj/ReleaseHistory.md" \
  "$BUNDLE/release-notes.md"; then
  print -u2 "release notes contain an internal trigger or confidential enrollment detail"
  exit 1
fi

asset_jsonl="$(/usr/bin/mktemp /private/tmp/sayall-release-assets.XXXXXX)"
for file_path in "$public_dir"/*(N); do
  [[ -f "$file_path" && ! -L "$file_path" ]] || {
    print -u2 "public bundle contains a non-regular asset: ${file_path:t}"
    exit 1
  }
  jq -cn \
    --arg name "${file_path:t}" \
    --argjson size "$(/usr/bin/stat -f '%z' "$file_path")" \
    --arg sha256 "$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{print $1}')" \
    '{name:$name,size:$size,sha256:$sha256}' >> "$asset_jsonl"
done

jq -s -S \
  --arg repository HD838A/remote-mic-app \
  --arg tag "$tag" \
  --arg sourceCommit "$source_commit" \
  --arg version "$version" \
  --arg build "$build" \
  '{schemaVersion:1,repository:$repository,tag:$tag,sourceCommit:$sourceCommit,version:$version,build:$build,assets:(sort_by(.name))}' \
  "$asset_jsonl" > "$BUNDLE/staged-assets.json"

# The line-oriented generator input is deliberately outside the staged bundle.
# Only the canonical public payload and its signed manifest may enter the artifact.
/bin/mv "$asset_jsonl" "/private/tmp/sayall-release-assets-consumed.$$.jsonl"

jq -e '
  .schemaVersion == 1 and
  .repository == "HD838A/remote-mic-app" and
  (.tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
  (.sourceCommit | test("^[0-9a-f]{40}$")) and
  (.version | test("^[0-9]+[.][0-9]+[.][0-9]+$")) and
  .tag == ("v" + .version) and
  (.build | test("^[1-9][0-9]*$")) and
  (.assets | length == 11) and
  ([.assets[].name] | length == (unique | length)) and
  all(.assets[];
    (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.size | type == "number" and . >= 0 and floor == .) and
    (.sha256 | test("^[0-9a-f]{64}$")))
' "$BUNDLE/staged-assets.json" >/dev/null

"$ROOT/scripts/verify-staged-release-assets.sh" \
  "$BUNDLE/staged-assets.json" "$public_dir"

print "PUBLIC RELEASE ASSET BUNDLE PASS"
print "TAG: $tag"
print "SOURCE_COMMIT: $source_commit"
print "ASSET_COUNT: 11"
print "BUNDLE: $BUNDLE"
