#!/usr/bin/env bash
set -euo pipefail

ATTESTATION="$1"
STAGE="$2"
DIST="$3"

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 <preview-ui-attestation.json> <stage.json> <signed-dist-directory>" >&2
  exit 2
fi
for command_name in jq shasum sed grep; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "Missing required command: $command_name" >&2; exit 1; }
done
for input_file in "$ATTESTATION" "$STAGE"; do
  [[ -r "$input_file" ]] || exit 1
done
[[ -d "$DIST" ]] || exit 1

jq -e --slurpfile stage "$STAGE" '
  .schemaVersion == 3 and .result == "passed" and .mode == "preview" and
  .tag == $stage[0].tag and .sourceCommit == $stage[0].sourceCommit and
  .sourceRunId == $stage[0].sourceRunId and .sourceRunAttempt == $stage[0].sourceRunAttempt and
  .signedArtifactId == $stage[0].signedArtifactId and
  .signedArtifactDigest == $stage[0].signedArtifactDigest and
  .assetManifestSHA256 == $stage[0].assetManifestSHA256 and
  .stagedAt == $stage[0].stagedAt and (.stagedAt | fromdateiso8601 > 0) and
  .target.version == $stage[0].version and .target.build == $stage[0].build and
  .baseline.tag == "v1.8.3" and .baseline.version == "1.8.3" and
  .baseline.developerTeamId == "L3QHLDRPAY" and
  .baseline.signatureVerified == true and .baseline.notarizationValidated == true and
  .baseline.gatekeeperAccepted == true and .baseline.launched == true and
  .update.usedSparkleUI == true and
  (.observedFeedURL == .update.feedURL) and
  (.update.feedURL == .testedArtifact.feedURL or
   .update.feedURL == ("https://github.com/HD838A/remote-mic-app/releases/download/" + $stage[0].tag + "/appcast.xml")) and
  .testedArtifact.lane == "apple-silicon" and
  (.testedArtifact.feedURL | test("^http://127[.]0[.]0[.]1:[1-9][0-9]*/appcast[.]xml$")) and
  (.testedArtifact.testURLPrefix | test("^http://127[.]0[.]0[.]1:[1-9][0-9]*/$")) and
  (.testedArtifact.productionURLPrefix == ("https://download.sayall.app/mac/releases/" + $stage[0].tag + "/")) and
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
  .installedApp.notarizationValidated == true and .installedApp.gatekeeperAccepted == true and
  .installedApp.sparkleHelpersExecutable == true and .installedApp.sparkleLinksValid == true and
  (.installedApp.mainExecutableSHA256 | test("^[0-9a-f]{64}$")) and
  (.installedApp.infoPlistSHA256 | test("^[0-9a-f]{64}$")) and
  .crashReports.newReports == [] and
  (.recordedAt | fromdateiso8601) >= (.crashReports.checkedAt | fromdateiso8601)
' "$ATTESTATION" >/dev/null || {
  echo "preview UI attestation is incomplete or bound to another staged artifact" >&2
  exit 1
}

archive_name="$(jq -r '.testedArtifact.archiveName' "$ATTESTATION")"
archive="$DIST/$archive_name"
appcast="$DIST/appcast.xml"
[[ -f "$archive" && -f "$appcast" && ! -L "$archive" && ! -L "$appcast" ]] || exit 1
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$(jq -r '.testedArtifact.archiveSHA256' "$ATTESTATION")" ]] || exit 1
[[ "$(shasum -a 256 "$appcast" | awk '{print $1}')" == "$(jq -r '.testedArtifact.productionAppcastSHA256' "$ATTESTATION")" ]] || exit 1
production_prefix="$(jq -r '.testedArtifact.productionURLPrefix' "$ATTESTATION")"
test_prefix="$(jq -r '.testedArtifact.testURLPrefix' "$ATTESTATION")"
grep -Fq "url=\"$production_prefix$archive_name\"" "$appcast"
transformed_sha="$(sed "s#$production_prefix#$test_prefix#g" "$appcast" | shasum -a 256 | awk '{print $1}')"
[[ "$transformed_sha" == "$(jq -r '.testedArtifact.testAppcastSHA256' "$ATTESTATION")" ]] || exit 1

echo "PREVIEW UI ATTESTATION PASS"
