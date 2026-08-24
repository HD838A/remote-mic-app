#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
STAGE="${1:-}"
SESSION="${2:-}"
OBSERVATION="${3:-}"
APP="${4:-}"
OUTPUT="${5:-}"

if [[ "$#" -ne 5 ]]; then
  print -u2 "usage: $0 <preview-stage.json> <ui-test-session.json> <ui-observation.json> <installed-app> <output.json>"
  exit 2
fi
for command_name in jq plutil codesign spctl xcrun shasum stat readlink; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done
for file in "$STAGE" "$SESSION" "$OBSERVATION"; do
  [[ -r "$file" ]] || {
    print -u2 "UI evidence input is unreadable: $file"
    exit 1
  }
done
[[ -d "$APP/Contents" ]] || {
  print -u2 "installed App is invalid: $APP"
  exit 1
}

version="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
build="$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
expected_version="$(jq -r '.version' "$STAGE")"
expected_build="$(jq -r '.build' "$STAGE")"
[[ "$version" == "$expected_version" && "$build" == "$expected_build" ]] || {
  print -u2 "installed App version/build does not match the staged Preview"
  exit 1
}

codesign --verify --deep --strict --verbose=2 "$APP"
team_id="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
[[ "$team_id" == L3QHLDRPAY ]] || {
  print -u2 "installed App has an unexpected Developer Team ID"
  exit 1
}
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"

main_executable_name="$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist")"
main_executable="$APP/Contents/MacOS/$main_executable_name"
[[ -x "$main_executable" ]] || {
  print -u2 "installed App main executable is not executable"
  exit 1
}
sparkle="$APP/Contents/Frameworks/Sparkle.framework"
for helper in \
  "$sparkle/Versions/B/Sparkle" \
  "$sparkle/Versions/B/Autoupdate" \
  "$sparkle/Versions/B/Updater.app/Contents/MacOS/Updater" \
  "$sparkle/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
  "$sparkle/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
  [[ -x "$helper" && "$(stat -f '%Lp' "$helper")" == 755 ]] || {
    print -u2 "Sparkle helper is missing executable mode 0755: $helper"
    exit 1
  }
done
[[ -L "$sparkle/Versions/Current" && "$(readlink "$sparkle/Versions/Current")" == B ]] || {
  print -u2 "Sparkle Versions/Current link is invalid"
  exit 1
}

jq -e --slurpfile session "$SESSION" '
  .baseline.launched == true and
  (.baseline.launchedAt | fromdateiso8601 > 0) and
  .update.usedSparkleUI == true and
  .update.feedURL == $session[0].feedURL and
  ([.update.checkStartedAt,.update.downloadConfirmedAt,.update.installConfirmedAt,
    .launches.first.startedAt,.launches.first.quitAt,.launches.second.startedAt,
    .crashReports.checkedAt,.recordedAt] | all(.[]; fromdateiso8601 > 0)) and
  .launches.first.succeeded == true and .launches.second.succeeded == true and
  .crashReports.newReports == []
' "$OBSERVATION" >/dev/null || {
  print -u2 "UI observation must contain the real Sparkle sequence, two launches, and crash-report result"
  exit 1
}

jq -S \
  --slurpfile stage "$STAGE" \
  --slurpfile session "$SESSION" \
  --slurpfile observation "$OBSERVATION" \
  --arg appPath "$APP" \
  --arg teamId "$team_id" \
  --arg mainExecutableSHA256 "$(shasum -a 256 "$main_executable" | awk '{print $1}')" \
  --arg infoPlistSHA256 "$(shasum -a 256 "$APP/Contents/Info.plist" | awk '{print $1}')" '
    $observation[0] + {
      schemaVersion: 2,
      result: "passed",
      requestId: $stage[0].requestId,
      tag: $stage[0].tag,
      candidateBranch: $stage[0].candidateBranch,
      candidateCommit: $stage[0].candidateCommit,
      pipelineDigest: $stage[0].pipelineDigest,
      sourceRunId: $stage[0].sourceRunId,
      sourceRunAttempt: $stage[0].sourceRunAttempt,
      signedArtifactId: $stage[0].signedArtifactId,
      signedArtifactDigest: $stage[0].signedArtifactDigest,
      requestStartedAt: $stage[0].requestStartedAt,
      releaseReadyAt: $stage[0].releaseReadyAt,
      target: {version:$stage[0].version,build:$stage[0].build},
      testedArtifact: {
        lane:$session[0].lane,
        feedURL:$session[0].feedURL,
        productionURLPrefix:$session[0].productionURLPrefix,
        testURLPrefix:$session[0].testURLPrefix,
        productionAppcast:$session[0].productionAppcast,
        productionAppcastSHA256:$session[0].productionAppcastSHA256,
        testAppcastSHA256:$session[0].testAppcastSHA256,
        archiveName:$session[0].archiveName,
        archiveSHA256:$session[0].archiveSHA256
      },
      baseline: $session[0].stable + $observation[0].baseline,
      installedApp: {
        path:$appPath,
        developerTeamId:$teamId,
        codesignDeepStrict:true,
        notarizationValidated:true,
        gatekeeperAccepted:true,
        sparkleHelpersExecutable:true,
        sparkleLinksValid:true,
        mainExecutableSHA256:$mainExecutableSHA256,
        infoPlistSHA256:$infoPlistSHA256
      }
    }
  ' > "$OUTPUT"

"$ROOT/scripts/verify-preview-ui-attestation.sh" \
  "$OUTPUT" "$STAGE" "$(dirname "$SESSION")/resolved/candidate/dist"
print "PREVIEW UI ATTESTATION RECORDED: $OUTPUT"
