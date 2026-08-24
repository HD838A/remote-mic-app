#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
RUN_ID="${1:-}"
OUTPUT_DIR="${2:-}"
FEED_PORT="${PREVIEW_UI_FEED_PORT:-8765}"
STABLE_TAG="v1.8.3"
STABLE_VERSION="1.8.3"
STABLE_BUILD="64"

if [[ "$#" -ne 2 || ! "$RUN_ID" =~ ^[1-9][0-9]*$ || -z "$OUTPUT_DIR" ]]; then
  print -u2 "usage: $0 <successful-stage-run-id> <output-directory>"
  exit 2
fi
[[ "$FEED_PORT" =~ ^[1-9][0-9]*$ ]] && (( FEED_PORT <= 65535 )) || {
  print -u2 "PREVIEW_UI_FEED_PORT must be between 1 and 65535"
  exit 2
}
for command_name in "$GH_BIN" jq shasum unzip ditto codesign spctl xcrun plutil python3 sed; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done
[[ ! -e "$OUTPUT_DIR" ]] || {
  print -u2 "output directory already exists: $OUTPUT_DIR"
  exit 1
}
/bin/mkdir -p "$OUTPUT_DIR/stage" "$OUTPUT_DIR/feed" "$OUTPUT_DIR/baseline"

run_json="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$RUN_ID")"
print -r -- "$run_json" | jq -e '
  .event == "workflow_dispatch" and
  .path == ".github/workflows/mac-release-package.yml" and
  .status == "completed" and .conclusion == "success" and
  (.head_branch | test("^release/pre-v[0-9]+[.][0-9]+[.][0-9]+$")) and
  (.head_sha | test("^[0-9a-f]{40}$"))
' >/dev/null || {
  print -u2 "source Run is not a successful staged candidate workflow"
  exit 1
}
run_attempt="$(print -r -- "$run_json" | jq -r '.run_attempt')"
branch="$(print -r -- "$run_json" | jq -r '.head_branch')"
commit="$(print -r -- "$run_json" | jq -r '.head_sha')"
tag="${branch#release/pre-}"

artifacts="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$RUN_ID/artifacts?per_page=100")"
stage_record="$(print -r -- "$artifacts" | jq -r --arg name "preview-stage-$tag-$commit" '[.artifacts[] | select(.name == $name and .expired == false)] | if length == 1 then .[0] | [.id,.digest] | @tsv else empty end')"
[[ -n "$stage_record" ]] || {
  print -u2 "successful Run has no unique staged preview identity"
  exit 1
}
IFS=$'\t' read -r stage_id stage_digest <<< "$stage_record"
stage_zip="$OUTPUT_DIR/stage.zip"
$GH_BIN api "repos/$REPOSITORY/actions/artifacts/$stage_id/zip" > "$stage_zip"
[[ "sha256:$(shasum -a 256 "$stage_zip" | awk '{print $1}')" == "$stage_digest" ]] || {
  print -u2 "stage artifact digest mismatch"
  exit 1
}
unzip -q "$stage_zip" -d "$OUTPUT_DIR/stage"
stage_file="$OUTPUT_DIR/stage/preview-stage.json"
signed_id="$(jq -r '.signedArtifactId' "$stage_file")"
signed_digest="$(jq -r '.signedArtifactDigest' "$stage_file")"
request_id="$(jq -r '.requestId' "$stage_file")"
request_started_at="$(jq -r '.requestStartedAt' "$stage_file")"
version="$(jq -r '.version' "$stage_file")"

RESUME_WORK_DIR="$OUTPUT_DIR/resolved" \
REPOSITORY_ROOT="$ROOT" GITHUB_REPOSITORY="$REPOSITORY" \
RELEASE_TAG="$tag" EXPECTED_COMMIT="$commit" RELEASE_REQUEST_ID="$request_id" \
SOURCE_RUN_ID="$RUN_ID" SOURCE_RUN_ATTEMPT="$run_attempt" \
SOURCE_ARTIFACT_ID="$signed_id" SOURCE_ARTIFACT_DIGEST="$signed_digest" \
RELEASE_REQUEST_STARTED_AT="$request_started_at" \
SOURCE_RUN_REQUIRED_CONCLUSION=success REQUIRE_EXISTING_TAG=0 REQUIRE_STAGED_SOURCE=1 \
ALLOW_LATE_RECOVERY=1 "$ROOT/scripts/resume-preview-publication.sh" \
  > "$OUTPUT_DIR/resolved.txt"

dist="$OUTPUT_DIR/resolved/candidate/dist"
production_appcast="$dist/appcast.xml"
archive="$dist/Remote-Mic-$version.zip"
zh_notes="$dist/Remote-Mic-$version.zh.txt"
en_notes="$dist/Remote-Mic-$version.en.txt"
for file_path in "$production_appcast" "$archive" "$zh_notes" "$en_notes"; do
  [[ -f "$file_path" ]] || {
    print -u2 "staged Apple Silicon UI-test asset is missing: $file_path"
    exit 1
  }
done

production_prefix="https://download.sayall.app/mac/releases/$tag/"
test_prefix="http://127.0.0.1:$FEED_PORT/"
grep -Fq "url=\"$production_prefix${archive:t}\"" "$production_appcast"
grep -Fq "$production_prefix${zh_notes:t}" "$production_appcast"
grep -Fq "$production_prefix${en_notes:t}" "$production_appcast"
/usr/bin/ditto --norsrc --noqtn --noacl "$archive" "$OUTPUT_DIR/feed/${archive:t}"
/usr/bin/ditto --norsrc --noqtn --noacl "$zh_notes" "$OUTPUT_DIR/feed/${zh_notes:t}"
/usr/bin/ditto --norsrc --noqtn --noacl "$en_notes" "$OUTPUT_DIR/feed/${en_notes:t}"
/usr/bin/cmp -s "$archive" "$OUTPUT_DIR/feed/${archive:t}"
/usr/bin/cmp -s "$zh_notes" "$OUTPUT_DIR/feed/${zh_notes:t}"
/usr/bin/cmp -s "$en_notes" "$OUTPUT_DIR/feed/${en_notes:t}"
/usr/bin/sed "s#${production_prefix}#${test_prefix}#g" \
  "$production_appcast" > "$OUTPUT_DIR/feed/appcast.xml"
grep -Fq "url=\"$test_prefix${archive:t}\"" "$OUTPUT_DIR/feed/appcast.xml"

stable_release="$($GH_BIN api "repos/$REPOSITORY/releases/tags/$STABLE_TAG")"
print -r -- "$stable_release" | jq -e \
  --arg tag "$STABLE_TAG" '.tag_name == $tag and .draft == false and .prerelease == false' >/dev/null
stable_record="$(print -r -- "$stable_release" | jq -r --arg name "Remote-Mic-$STABLE_VERSION.zip" '[.assets[] | select(.name == $name)] | if length == 1 then .[0] | [.id,.digest] | @tsv else empty end')"
[[ -n "$stable_record" ]] || {
  print -u2 "stable baseline archive is missing or ambiguous"
  exit 1
}
IFS=$'\t' read -r stable_asset_id stable_asset_digest <<< "$stable_record"
[[ "$stable_asset_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  print -u2 "stable baseline archive has no API digest"
  exit 1
}
stable_zip="$OUTPUT_DIR/baseline/Remote-Mic-$STABLE_VERSION.zip"
$GH_BIN api \
  --header 'Accept: application/octet-stream' \
  "repos/$REPOSITORY/releases/assets/$stable_asset_id" > "$stable_zip"
[[ "sha256:$(shasum -a 256 "$stable_zip" | awk '{print $1}')" == "$stable_asset_digest" ]] || {
  print -u2 "stable baseline archive digest mismatch"
  exit 1
}
/bin/mkdir -p "$OUTPUT_DIR/baseline/extracted"
/usr/bin/ditto -x -k "$stable_zip" "$OUTPUT_DIR/baseline/extracted"
stable_apps=("$OUTPUT_DIR"/baseline/extracted/*.app(/N))
(( ${#stable_apps[@]} == 1 )) || {
  print -u2 "stable baseline archive must contain exactly one App"
  exit 1
}
stable_app="${stable_apps[1]}"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$stable_app/Contents/Info.plist")" = "$STABLE_VERSION"
test "$(plutil -extract CFBundleVersion raw -o - "$stable_app/Contents/Info.plist")" = "$STABLE_BUILD"
codesign --verify --deep --strict --verbose=2 "$stable_app"
stable_team_id="$(codesign -dv --verbose=4 "$stable_app" 2>&1 | awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
test "$stable_team_id" = L3QHLDRPAY
xcrun stapler validate "$stable_app"
spctl -a -vv -t exec "$stable_app"

jq -n -S \
  --slurpfile stage "$stage_file" \
  --arg lane apple-silicon \
  --arg feedURL "${test_prefix}appcast.xml" \
  --arg productionURLPrefix "$production_prefix" \
  --arg testURLPrefix "$test_prefix" \
  --arg productionAppcast "appcast.xml" \
  --arg productionAppcastSHA256 "$(shasum -a 256 "$production_appcast" | awk '{print $1}')" \
  --arg testAppcastSHA256 "$(shasum -a 256 "$OUTPUT_DIR/feed/appcast.xml" | awk '{print $1}')" \
  --arg archiveName "${archive:t}" \
  --arg archiveSHA256 "$(shasum -a 256 "$archive" | awk '{print $1}')" \
  --arg stableTag "$STABLE_TAG" \
  --argjson stableAssetId "$stable_asset_id" \
  --arg stableAssetDigest "$stable_asset_digest" \
  --arg stableVersion "$STABLE_VERSION" \
  --arg stableBuild "$STABLE_BUILD" \
  --arg stableTeamId "$stable_team_id" \
  --arg stableAppPath "$stable_app" '
    {
      schemaVersion:1,
      requestId:$stage[0].requestId,
      tag:$stage[0].tag,
      candidateCommit:$stage[0].candidateCommit,
      signedArtifactId:$stage[0].signedArtifactId,
      signedArtifactDigest:$stage[0].signedArtifactDigest,
      lane:$lane,
      feedURL:$feedURL,
      productionURLPrefix:$productionURLPrefix,
      testURLPrefix:$testURLPrefix,
      productionAppcast:$productionAppcast,
      productionAppcastSHA256:$productionAppcastSHA256,
      testAppcastSHA256:$testAppcastSHA256,
      archiveName:$archiveName,
      archiveSHA256:$archiveSHA256,
      stable:{
        tag:$stableTag,
        assetId:$stableAssetId,
        assetDigest:$stableAssetDigest,
        version:$stableVersion,
        build:$stableBuild,
        developerTeamId:$stableTeamId,
        appPath:$stableAppPath,
        signatureVerified:true,
        notarizationValidated:true,
        gatekeeperAccepted:true
      }
    }
  ' > "$OUTPUT_DIR/ui-test-session.json"

print "STAGED PREVIEW UI TEST INPUT PASS"
print "PREVIEW_STAGE: $stage_file"
print "UI_TEST_SESSION: $OUTPUT_DIR/ui-test-session.json"
print "STABLE_BASELINE_APP: $stable_app"
print "CANDIDATE_FEED: ${test_prefix}appcast.xml"
print "START_FEED_SERVER: cd '$OUTPUT_DIR/feed' && python3 -m http.server $FEED_PORT --bind 127.0.0.1"
print "The temporary appcast changes only URLs; its enclosure references the exact staged ZIP bytes."
