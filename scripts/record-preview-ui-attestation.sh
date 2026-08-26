#!/usr/bin/env bash
set -euo pipefail
umask 077

STAGE="${1:-}"
SESSION="${2:-}"
OBSERVATION="${3:-}"
APP="${4:-}"
OUTPUT="${5:-}"

if [[ "$#" -ne 5 ]]; then
  echo "usage: $0 <stage.json> <ui-test-session.json> <ui-observation.json> <installed-app> <output.json>" >&2
  exit 2
fi
for command_name in jq plutil codesign spctl xcrun shasum stat readlink; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "Missing required command: $command_name" >&2; exit 1; }
done
for input_file in "$STAGE" "$SESSION" "$OBSERVATION"; do
  [[ -r "$input_file" ]] || { echo "unreadable UI evidence input: $input_file" >&2; exit 1; }
done
[[ -d "$APP/Contents" ]] || { echo "installed App is invalid: $APP" >&2; exit 1; }

jq -e '
  .schemaVersion == 1 and .mode == "preview" and
  (.tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
  (.sourceCommit | test("^[0-9a-f]{40}$")) and
  (.sourceRunId | type == "number" and . > 0) and
  (.sourceRunAttempt | type == "number" and . > 0) and
  (.signedArtifactId | type == "number" and . > 0) and
  (.signedArtifactDigest | test("^sha256:[0-9a-f]{64}$")) and
  (.assetManifestSHA256 | test("^[0-9a-f]{64}$")) and
  (.stagedAt | fromdateiso8601 > 0)
' "$STAGE" >/dev/null || { echo "staging record is invalid" >&2; exit 1; }

version="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
build="$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
expected_version="$(jq -r '.version' "$STAGE")"
expected_build="$(jq -r '.build' "$STAGE")"
[[ "$version" == "$expected_version" && "$build" == "$expected_build" ]] || {
  echo "installed App version/build does not match staged Preview" >&2
  exit 1
}
codesign --verify --deep --strict "$APP"
team_id="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
[[ "$team_id" == L3QHLDRPAY ]] || exit 1
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"
main_name="$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist")"
main_executable="$APP/Contents/MacOS/$main_name"
[[ -x "$main_executable" ]] || exit 1
sparkle="$APP/Contents/Frameworks/Sparkle.framework"
for helper in \
  "$sparkle/Versions/B/Sparkle" \
  "$sparkle/Versions/B/Autoupdate" \
  "$sparkle/Versions/B/Updater.app/Contents/MacOS/Updater" \
  "$sparkle/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
  "$sparkle/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
  [[ -x "$helper" && "$(stat -f '%Lp' "$helper")" == 755 ]] || exit 1
done
[[ -L "$sparkle/Versions/Current" && "$(readlink "$sparkle/Versions/Current")" == B ]] || exit 1

jq -e --slurpfile session "$SESSION" '
  .baseline.launched == true and
  (.baseline.launchedAt | fromdateiso8601 > 0) and
  .update.usedSparkleUI == true and
  (.update.checkStartedAt | fromdateiso8601 > 0) and
  (.update.downloadConfirmedAt | fromdateiso8601 > 0) and
  (.update.installConfirmedAt | fromdateiso8601 > 0) and
  .launches.first.succeeded == true and .launches.second.succeeded == true and
  ([.launches.first.startedAt,.launches.first.quitAt,.launches.second.startedAt,
    .crashReports.checkedAt,.recordedAt] | all(.[]; fromdateiso8601 > 0)) and
  .crashReports.newReports == [] and
  (.update.feedURL == $session[0].feedURL or
   .update.feedURL == ("https://github.com/HD838A/remote-mic-app/releases/download/" + $session[0].tag + "/appcast.xml"))
' "$OBSERVATION" >/dev/null || {
  echo "UI observation must contain the real Sparkle sequence and two successful launches" >&2
  exit 1
}

jq -S --slurpfile stage "$STAGE" --slurpfile session "$SESSION" --slurpfile observation "$OBSERVATION" \
  --arg appPath "$APP" --arg teamId "$team_id" \
  --arg mainExecutableSHA256 "$(shasum -a 256 "$main_executable" | awk '{print $1}')" \
  --arg infoPlistSHA256 "$(shasum -a 256 "$APP/Contents/Info.plist" | awk '{print $1}')" '
  $observation[0] + {
    schemaVersion:3, result:"passed", mode:$stage[0].mode,
    tag:$stage[0].tag, sourceCommit:$stage[0].sourceCommit,
    stagedAt:$stage[0].stagedAt,
    sourceRunId:$stage[0].sourceRunId, sourceRunAttempt:$stage[0].sourceRunAttempt,
    signedArtifactId:$stage[0].signedArtifactId,
    signedArtifactDigest:$stage[0].signedArtifactDigest,
    assetManifestSHA256:$stage[0].assetManifestSHA256,
    target:{version:$stage[0].version,build:$stage[0].build},
    testedArtifact:{
      lane:$session[0].lane, feedURL:$session[0].feedURL,
      testURLPrefix:$session[0].testURLPrefix,
      productionURLPrefix:$session[0].productionURLPrefix,
      archiveName:$session[0].archiveName,
      productionAppcastSHA256:$session[0].productionAppcastSHA256,
      testAppcastSHA256:$session[0].testAppcastSHA256,
      archiveSHA256:$session[0].archiveSHA256
    },
    baseline:($session[0].stable + $observation[0].baseline),
    installedApp:{
      path:$appPath, developerTeamId:$teamId,
      codesignDeepStrict:true, notarizationValidated:true,
      gatekeeperAccepted:true, sparkleHelpersExecutable:true,
      sparkleLinksValid:true, mainExecutableSHA256:$mainExecutableSHA256,
      infoPlistSHA256:$infoPlistSHA256
    }
  }
' "$OBSERVATION" > "$OUTPUT"

echo "PREVIEW UI ATTESTATION RECORDED: $OUTPUT"
