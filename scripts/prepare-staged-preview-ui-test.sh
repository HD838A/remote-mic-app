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
BASELINE_TAG="${PREVIEW_UI_BASELINE_TAG:-}"

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

if [[ -z "$BASELINE_TAG" ]]; then
  baseline_release="$($GH_BIN api "repos/$REPOSITORY/releases/latest")" || {
    echo "unable to resolve the current stable latest Release" >&2
    exit 1
  }
  BASELINE_TAG="$(printf '%s\n' "$baseline_release" | jq -r '.tag_name')"
else
  baseline_release="$($GH_BIN api "repos/$REPOSITORY/releases/tags/$BASELINE_TAG")" || {
    echo "unable to resolve the requested Preview UI baseline Release: $BASELINE_TAG" >&2
    exit 1
  }
fi
printf '%s\n' "$baseline_release" | jq -e \
  --arg tag "$BASELINE_TAG" \
  '.tag_name == $tag and ($tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and .draft == false and .prerelease == false' >/dev/null || {
  echo "Preview UI baseline is not a formal stable Release: $BASELINE_TAG" >&2
  exit 1
}

run_json="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$RUN_ID")"
printf '%s\n' "$run_json" | jq -e '
  .event == "workflow_dispatch" and
  .path == ".github/workflows/mac-release-package.yml" and
  .status == "completed" and .conclusion == "success" and
  .head_branch == "main" and (.head_sha | test("^[0-9a-f]{40}$"))
' >/dev/null || { echo "source Run is not a successful main-controlled staging workflow" >&2; exit 1; }
run_attempt="$(printf '%s\n' "$run_json" | jq -r '.run_attempt')"
workflow_commit="$(printf '%s\n' "$run_json" | jq -r '.head_sha')"
artifacts="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$RUN_ID/artifacts?per_page=100")"
payload_record="$(printf '%s\n' "$artifacts" | jq -r '
  [.artifacts[] | select(.name | startswith("mac-preview-payload-")) | select(.expired == false)] |
  if length == 1 then .[0] | [.id,.digest,.name] | @tsv else empty end
')"
[[ -n "$payload_record" ]] || { echo "successful Run has no unique payload artifact" >&2; exit 1; }
IFS=$'\t' read -r artifact_id artifact_digest artifact_name <<< "$payload_record"
[[ "$artifact_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
commit="${artifact_name##*-}"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "payload artifact has no source Commit identity" >&2; exit 1; }

resolved="$OUTPUT_DIR/resolved"
"$ROOT/scripts/recover-preview-stage.sh" "$RUN_ID" "$run_attempt" "$artifact_id" "$artifact_digest" "$commit" "$resolved" > "$OUTPUT_DIR/recovery.txt"
manifest="$resolved/bundle/staged-assets.json"
public_dir="$resolved/bundle/public"
stage_record="$resolved/stage-record/preview-stage-record.json"
[[ "$(jq -r '.sourceWorkflowCommit' "$stage_record")" == "$workflow_commit" ]] || exit 1
if [[ "$(jq -r '.sourceKind' "$stage_record")" == hotfix ]]; then
  [[ "$(jq -r '.sourceBaseTag' "$stage_record")" == "$BASELINE_TAG" ]] || {
    echo "Hotfix UI baseline must match the stable Tag used to create the Hotfix branch" >&2
    exit 1
  }
fi
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

printf '%s\n' "$baseline_release" | jq -e --arg tag "$BASELINE_TAG" '.tag_name == $tag and .draft == false and .prerelease == false' >/dev/null
baseline_version="$(printf '%s' "$BASELINE_TAG" | sed 's/^v//')"
jq -n -e --arg baseline "$baseline_version" --arg candidate "$version" \
  '($baseline | split(".") | map(tonumber)) < ($candidate | split(".") | map(tonumber))' >/dev/null
baseline_asset_id="$(printf '%s\n' "$baseline_release" | jq -r --arg name "Remote-Mic-$baseline_version.zip" '[.assets[] | select(.name == $name)] | if length == 1 then .[0].id else empty end')"
baseline_asset_digest="$(printf '%s\n' "$baseline_release" | jq -r --arg name "Remote-Mic-$baseline_version.zip" '[.assets[] | select(.name == $name)] | if length == 1 then .[0].digest else empty end')"
baseline_asset_url="$(printf '%s\n' "$baseline_release" | jq -r --arg name "Remote-Mic-$baseline_version.zip" '[.assets[] | select(.name == $name)] | if length == 1 then .[0].browser_download_url else empty end')"
expected_baseline_asset_url="https://github.com/$REPOSITORY/releases/download/$BASELINE_TAG/Remote-Mic-$baseline_version.zip"
[[ "$baseline_asset_id" =~ ^[1-9][0-9]*$ &&
   "$baseline_asset_digest" =~ ^sha256:[0-9a-f]{64}$ &&
   "$baseline_asset_url" == "$expected_baseline_asset_url" ]] || exit 1
baseline_zip="$OUTPUT_DIR/baseline/Remote-Mic-$baseline_version.zip"
curl --fail --silent --show-error --location "$baseline_asset_url" --output "$baseline_zip"
[[ "sha256:$(shasum -a 256 "$baseline_zip" | awk '{print $1}')" == "$baseline_asset_digest" ]] || exit 1
ditto -x -k "$baseline_zip" "$OUTPUT_DIR/baseline"
baseline_app="$(find "$OUTPUT_DIR/baseline" -maxdepth 1 -name '*.app' -type d -print -quit)"
[[ -n "$baseline_app" ]] || exit 1
baseline_executable="$(plutil -extract CFBundleExecutable raw -o - "$baseline_app/Contents/Info.plist")"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$baseline_app/Contents/Info.plist")" = "$baseline_version"
codesign --verify --deep --strict "$baseline_app"
test "$(codesign -dv --verbose=4 "$baseline_app" 2>&1 | awk -F= '$1 == "TeamIdentifier" {print $2; exit}')" = L3QHLDRPAY
xcrun stapler validate "$baseline_app"
spctl -a -vv -t exec "$baseline_app"

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
  --arg stableTag "$BASELINE_TAG" --argjson stableAssetId "$baseline_asset_id" \
  --arg stableAssetDigest "$baseline_asset_digest" --arg stableVersion "$baseline_version" \
  --arg stableAppPath "$baseline_app" '
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
echo "UI_BASELINE_APP: $baseline_app"
echo "UI_BASELINE_APP_EXECUTABLE: $baseline_app/Contents/MacOS/$baseline_executable"
echo "CANDIDATE_FEED: $test_prefix""appcast.xml"
echo "UI_TEST_ENV: REMOTE_MIC_UI_TEST_MODE=1 REMOTE_MIC_UI_TEST_FEED_URL=$test_prefix""appcast.xml REMOTE_MIC_UI_TEST_VERSION=$version"
echo "START_FEED_SERVER: cd '$OUTPUT_DIR/feed' && python3 -m http.server $FEED_PORT --bind 127.0.0.1"
