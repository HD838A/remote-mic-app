#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-}"
if [[ -z "$ROOT" ]]; then ROOT="$(cd "$(dirname "$0")/.." && pwd)"; fi
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
RUN_ID="${1:-}"
OUTPUT_DIR="${2:-}"
FEED_PORT="${PREVIEW_UI_FEED_PORT:-8765}"
STABLE_TAG="${EXPECTED_STABLE_TAG:-v1.8.3}"

[[ "$REPOSITORY" == "HD838A/remote-mic-app" ]] || {
  echo "Preview UI preparation is restricted to HD838A/remote-mic-app" >&2
  exit 1
}

if [[ "$#" -ne 2 || ! "$RUN_ID" =~ ^[1-9][0-9]*$ || -z "$OUTPUT_DIR" ]]; then
  echo "usage: $0 <successful-stage-run-id> <output-directory>" >&2
  exit 2
fi
[[ "$FEED_PORT" =~ ^[1-9][0-9]*$ && "$FEED_PORT" -le 65535 ]] || exit 2
[[ ! -e "$OUTPUT_DIR" ]] || { echo "output directory already exists" >&2; exit 1; }
for command_name in "$GH_BIN" jq shasum unzip curl plutil codesign spctl xcrun ditto; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "Missing required command: $command_name" >&2; exit 1; }
done
mkdir -p "$OUTPUT_DIR/feed" "$OUTPUT_DIR/baseline"

run_json="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$RUN_ID")"
printf '%s\n' "$run_json" | jq -e '
  .event == "workflow_dispatch" and
  .path == ".github/workflows/mac-release-package.yml" and
  .status == "completed" and .conclusion == "success" and
  .head_branch == "main" and (.head_sha | test("^[0-9a-f]{40}$"))
' >/dev/null || { echo "source Run is not a successful main-based staging workflow" >&2; exit 1; }
run_attempt="$(printf '%s\n' "$run_json" | jq -r '.run_attempt')"
commit="$(printf '%s\n' "$run_json" | jq -r '.head_sha')"
artifacts="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$RUN_ID/artifacts?per_page=100")"
payload_record="$(printf '%s\n' "$artifacts" | jq -r '
  [.artifacts[] | select(.name | startswith("mac-preview-payload-")) | select(.expired == false)] |
  if length == 1 then .[0] | [.id,.digest,.name] | @tsv else empty end
')"
[[ -n "$payload_record" ]] || { echo "successful Run has no unique payload artifact" >&2; exit 1; }
IFS=$'\t' read -r artifact_id artifact_digest artifact_name <<< "$payload_record"
[[ "$artifact_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1

resolved="$OUTPUT_DIR/resolved"
"$ROOT/scripts/recover-preview-stage.sh" "$RUN_ID" "$run_attempt" "$artifact_id" "$artifact_digest" "$commit" "$resolved" > "$OUTPUT_DIR/recovery.txt"
manifest="$resolved/bundle/staged-assets.json"
public_dir="$resolved/bundle/public"
stage_record="$resolved/stage-record/preview-stage-record.json"
version="$(jq -r '.version' "$manifest")"
tag="$(jq -r '.tag' "$manifest")"
archive="Remote-Mic-$version.zip"
manifest_sha="$(shasum -a 256 "$manifest" | awk '{print $1}')"
production_prefix="https://download.sayall.app/mac/releases/$tag/"
test_prefix="http://127.0.0.1:$FEED_PORT/"
for file_name in appcast.xml "$archive" "Remote-Mic-$version.zh.txt" "Remote-Mic-$version.en.txt"; do
  [[ -f "$public_dir/$file_name" ]] || { echo "staged UI-test asset is missing: $file_name" >&2; exit 1; }
done
for file_name in "$archive" "Remote-Mic-$version.zh.txt" "Remote-Mic-$version.en.txt"; do
  ditto --norsrc --noqtn --noacl "$public_dir/$file_name" "$OUTPUT_DIR/feed/$file_name"
done
sed "s#$production_prefix#$test_prefix#g" "$public_dir/appcast.xml" > "$OUTPUT_DIR/feed/appcast.xml"
grep -Fq "url=\"$test_prefix$archive\"" "$OUTPUT_DIR/feed/appcast.xml"

stable_release="$($GH_BIN api "repos/$REPOSITORY/releases/tags/$STABLE_TAG")"
printf '%s\n' "$stable_release" | jq -e --arg tag "$STABLE_TAG" '.tag_name == $tag and .draft == false and .prerelease == false' >/dev/null
stable_version="$(printf '%s' "$STABLE_TAG" | sed 's/^v//')"
stable_asset_id="$(printf '%s\n' "$stable_release" | jq -r --arg name "Remote-Mic-$stable_version.zip" '[.assets[] | select(.name == $name)] | if length == 1 then .[0].id else empty end')"
stable_asset_digest="$(printf '%s\n' "$stable_release" | jq -r --arg name "Remote-Mic-$stable_version.zip" '[.assets[] | select(.name == $name)] | if length == 1 then .[0].digest else empty end')"
[[ "$stable_asset_id" =~ ^[1-9][0-9]*$ && "$stable_asset_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
stable_zip="$OUTPUT_DIR/baseline/Remote-Mic-$stable_version.zip"
$GH_BIN api --header 'Accept: application/octet-stream' "repos/$REPOSITORY/releases/assets/$stable_asset_id" > "$stable_zip"
[[ "sha256:$(shasum -a 256 "$stable_zip" | awk '{print $1}')" == "$stable_asset_digest" ]] || exit 1
ditto -x -k "$stable_zip" "$OUTPUT_DIR/baseline"
stable_app="$(find "$OUTPUT_DIR/baseline" -maxdepth 1 -name '*.app' -type d -print -quit)"
[[ -n "$stable_app" ]] || exit 1
test "$(plutil -extract CFBundleShortVersionString raw -o - "$stable_app/Contents/Info.plist")" = "$stable_version"
codesign --verify --deep --strict "$stable_app"
test "$(codesign -dv --verbose=4 "$stable_app" 2>&1 | awk -F= '$1 == "TeamIdentifier" {print $2; exit}')" = L3QHLDRPAY
xcrun stapler validate "$stable_app"
spctl -a -vv -t exec "$stable_app"

manifest_sha="$(shasum -a 256 "$manifest" | awk '{print $1}')"
jq -n -S \
  --arg tag "$tag" --arg sourceCommit "$commit" \
  --argjson sourceRunId "$RUN_ID" --argjson sourceRunAttempt "$run_attempt" \
  --argjson signedArtifactId "$artifact_id" --arg signedArtifactDigest "$artifact_digest" \
  --arg assetManifestSHA256 "$manifest_sha" --arg lane apple-silicon \
  --arg feedURL "$test_prefix""appcast.xml" --arg testURLPrefix "$test_prefix" \
  --arg productionURLPrefix "$production_prefix" --arg archiveName "$archive" \
  --arg productionAppcastSHA256 "$(shasum -a 256 "$public_dir/appcast.xml" | awk '{print $1}')" \
  --arg testAppcastSHA256 "$(shasum -a 256 "$OUTPUT_DIR/feed/appcast.xml" | awk '{print $1}')" \
  --arg archiveSHA256 "$(shasum -a 256 "$public_dir/$archive" | awk '{print $1}')" \
  --arg stableTag "$STABLE_TAG" --argjson stableAssetId "$stable_asset_id" \
  --arg stableAssetDigest "$stable_asset_digest" --arg stableVersion "$stable_version" \
  --arg stableAppPath "$stable_app" '
  {schemaVersion:1,tag:$tag,sourceCommit:$sourceCommit,
   sourceRunId:$sourceRunId,sourceRunAttempt:$sourceRunAttempt,
   signedArtifactId:$signedArtifactId,signedArtifactDigest:$signedArtifactDigest,
   assetManifestSHA256:$assetManifestSHA256,lane:$lane,feedURL:$feedURL,
   testURLPrefix:$testURLPrefix,productionURLPrefix:$productionURLPrefix,
   archiveName:$archiveName,productionAppcastSHA256:$productionAppcastSHA256,
   testAppcastSHA256:$testAppcastSHA256,archiveSHA256:$archiveSHA256,
   stable:{tag:$stableTag,assetId:$stableAssetId,assetDigest:$stableAssetDigest,
   version:$stableVersion,appPath:$stableAppPath,signatureVerified:true,
   notarizationValidated:true,gatekeeperAccepted:true}}
' > "$OUTPUT_DIR/ui-test-session.json"

echo "STAGED PREVIEW UI TEST INPUT PASS"
echo "PREVIEW_TAG: $tag"
echo "SOURCE_COMMIT: $commit"
echo "UI_TEST_SESSION: $OUTPUT_DIR/ui-test-session.json"
echo "PREVIEW_STAGE_RECORD: $stage_record"
echo "STABLE_BASELINE_APP: $stable_app"
echo "CANDIDATE_FEED: $test_prefix""appcast.xml"
echo "START_FEED_SERVER: cd '$OUTPUT_DIR/feed' && python3 -m http.server $FEED_PORT --bind 127.0.0.1"
