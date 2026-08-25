#!/bin/zsh
set -euo pipefail

ATTESTATION="${1:-}"
STAGE="${2:-}"
DIST="${3:-}"

if [[ "$#" -ne 3 ]]; then
  print -u2 "usage: $0 <preview-ui-attestation.json> <preview-stage.json> <signed-dist-directory>"
  exit 2
fi
for file in "$ATTESTATION" "$STAGE"; do
  [[ -r "$file" ]] || {
    print -u2 "attestation input is unreadable: $file"
    exit 1
  }
done
[[ -d "$DIST" ]] || {
  print -u2 "signed dist directory is unavailable: $DIST"
  exit 1
}
for command_name in jq shasum sed grep; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

jq -e --slurpfile stage "$STAGE" '
  .schemaVersion == 2 and .result == "passed" and
  .requestId == $stage[0].requestId and
  .tag == $stage[0].tag and
  .candidateBranch == $stage[0].candidateBranch and
  .candidateCommit == $stage[0].candidateCommit and
  .pipelineDigest == $stage[0].pipelineDigest and
  .sourceRunId == $stage[0].sourceRunId and
  .sourceRunAttempt == $stage[0].sourceRunAttempt and
  .signedArtifactId == $stage[0].signedArtifactId and
  .signedArtifactDigest == $stage[0].signedArtifactDigest and
  .requestStartedAt == $stage[0].requestStartedAt and
  .releaseReadyAt == $stage[0].releaseReadyAt and
  (.requestStartedAt | type == "number") and (.releaseReadyAt | type == "number") and
  .target.version == $stage[0].version and .target.build == $stage[0].build and
  .baseline.tag == "v1.8.3" and
  .baseline.version == "1.8.3" and .baseline.build == "64" and
  .baseline.developerTeamId == "L3QHLDRPAY" and
  (.baseline.assetId | type == "number" and . > 0) and
  (.baseline.assetDigest | test("^sha256:[0-9a-f]{64}$")) and
  .baseline.signatureVerified == true and
  .baseline.notarizationValidated == true and
  .baseline.gatekeeperAccepted == true and
  .baseline.launched == true and
  (.baseline.launchedAt | fromdateiso8601 > 0) and
  .update.usedSparkleUI == true and
  (.observedFeedURL // .update.feedURL) == .update.feedURL and
  ((.observedFeedURL // .update.feedURL) == .testedArtifact.feedURL or
    (.observedFeedURL // .update.feedURL) ==
      ("https://github.com/HD838A/remote-mic-app/releases/download/" + $stage[0].tag + "/appcast.xml")) and
  .testedArtifact.lane == "apple-silicon" and
  (.testedArtifact.feedURL | test("^http://127[.]0[.]0[.]1:[1-9][0-9]*/appcast[.]xml$")) and
  (.testedArtifact.testURLPrefix | test("^http://127[.]0[.]0[.]1:[1-9][0-9]*/$")) and
  .testedArtifact.productionURLPrefix == ("https://download.sayall.app/mac/releases/" + $stage[0].tag + "/") and
  .testedArtifact.productionAppcast == "appcast.xml" and
  .testedArtifact.archiveName == ("Remote-Mic-" + $stage[0].version + ".zip") and
  (.testedArtifact.productionAppcastSHA256 | test("^[0-9a-f]{64}$")) and
  (.testedArtifact.testAppcastSHA256 | test("^[0-9a-f]{64}$")) and
  (.testedArtifact.archiveSHA256 | test("^[0-9a-f]{64}$")) and
  (.update.checkStartedAt | fromdateiso8601) <= (.update.downloadConfirmedAt | fromdateiso8601) and
  (.update.downloadConfirmedAt | fromdateiso8601) <= (.update.installConfirmedAt | fromdateiso8601) and
  (.update.installConfirmedAt | fromdateiso8601) <= (.launches.first.startedAt | fromdateiso8601) and
  (.launches.first.startedAt | fromdateiso8601) <= (.launches.first.quitAt | fromdateiso8601) and
  (.launches.first.quitAt | fromdateiso8601) <= (.launches.second.startedAt | fromdateiso8601) and
  .launches.first.succeeded == true and .launches.second.succeeded == true and
  .installedApp.developerTeamId == "L3QHLDRPAY" and
  .installedApp.codesignDeepStrict == true and
  .installedApp.notarizationValidated == true and
  .installedApp.gatekeeperAccepted == true and
  .installedApp.sparkleHelpersExecutable == true and
  .installedApp.sparkleLinksValid == true and
  (.installedApp.mainExecutableSHA256 | test("^[0-9a-f]{64}$")) and
  (.installedApp.infoPlistSHA256 | test("^[0-9a-f]{64}$")) and
  .crashReports.newReports == [] and
  (.crashReports.checkedAt | fromdateiso8601) >= (.launches.second.startedAt | fromdateiso8601) and
  (.recordedAt | fromdateiso8601) >= (.crashReports.checkedAt | fromdateiso8601)
' "$ATTESTATION" >/dev/null || {
  print -u2 "preview UI attestation is incomplete, out of order, or bound to another staged artifact"
  exit 1
}

archive_name="$(jq -r '.testedArtifact.archiveName' "$ATTESTATION")"
archive="$DIST/$archive_name"
production_appcast="$DIST/$(jq -r '.testedArtifact.productionAppcast' "$ATTESTATION")"
for file_path in "$archive" "$production_appcast"; do
  [[ -f "$file_path" && ! -L "$file_path" ]] || {
    print -u2 "tested staged asset is missing or unsafe: $file_path"
    exit 1
  }
done
test "$(shasum -a 256 "$archive" | awk '{print $1}')" = \
  "$(jq -r '.testedArtifact.archiveSHA256' "$ATTESTATION")"
test "$(shasum -a 256 "$production_appcast" | awk '{print $1}')" = \
  "$(jq -r '.testedArtifact.productionAppcastSHA256' "$ATTESTATION")"
production_prefix="$(jq -r '.testedArtifact.productionURLPrefix' "$ATTESTATION")"
test_prefix="$(jq -r '.testedArtifact.testURLPrefix' "$ATTESTATION")"
grep -Fq "url=\"$production_prefix$archive_name\"" "$production_appcast"
transformed_sha="$(sed "s#${production_prefix}#${test_prefix}#g" "$production_appcast" | shasum -a 256 | awk '{print $1}')"
test "$transformed_sha" = "$(jq -r '.testedArtifact.testAppcastSHA256' "$ATTESTATION")"

print "PREVIEW UI ATTESTATION PASS"
