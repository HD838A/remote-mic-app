#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
PACKAGE_WORKFLOW="$ROOT/.github/workflows/mac-release-package.yml"
PUBLICATION_WORKFLOW="$ROOT/.github/workflows/mac-preview-publication.yml"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-release-resume-test.XXXXXX)"

cleanup() {
  local trash_root="$HOME/.Trash"
  local trash_target="$trash_root/remotemic-release-resume-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$trash_root"
  if [[ -d "$WORK_DIR" ]]; then
    /bin/mv "$WORK_DIR" "$trash_target"
  fi
}
trap cleanup EXIT

for required in \
  '- stage-preview' \
  'Record staged preview identity' \
  'Upload staged preview identity' \
  'preview-stage-${{ inputs.tag }}-${{ inputs.expected_commit }}'; do
  /usr/bin/grep -Fq -- "$required" "$PACKAGE_WORKFLOW"
done
if /usr/bin/grep -Eq 'publish-release[.]sh|resume-preview-publication[.]sh|contents:[[:space:]]*write|gh release|git tag' "$PACKAGE_WORKFLOW"; then
  print -u2 "protected signing workflow still contains publication control-plane mutations"
  exit 1
fi

for required in \
  'Publish exact UI-tested staged Preview bytes' \
  'publication_mode' \
  'PUBLICATION_MODE' \
  'gh auth setup-git --hostname github.com' \
  'test "$GITHUB_REF_NAME" = main' \
  'SOURCE_RUN_REQUIRED_CONCLUSION=success' \
  'REQUIRE_EXISTING_TAG=0 REQUIRE_STAGED_SOURCE=1' \
  'verify-preview-ui-attestation.sh' \
  'publication_command=resume-draft' \
  'publication_command=resume-prerelease' \
  'Publish or resume the exact staged bytes'; do
  /usr/bin/grep -Fq -- "$required" "$PUBLICATION_WORKFLOW"
done
if /usr/bin/grep -Eq 'environment:[[:space:]]*mac-release|secrets[.]' "$PUBLICATION_WORKFLOW"; then
  print -u2 "publication control plane unexpectedly enters the credential Environment"
  exit 1
fi
/usr/bin/grep -Fq -- '--ref main' "$ROOT/scripts/publish-staged-preview.sh"
if /usr/bin/grep -Fq 'release_mode=' "$ROOT/scripts/publish-staged-preview.sh"; then
  print -u2 "staged publication dispatcher still exposes a second publication mode"
  exit 1
fi
/usr/bin/grep -Fq 'resume_existing_release_assets' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'download_draft_release_assets' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'intel_dmg_checksum="$DOWNLOAD_DIR/Remote-Mic-$VERSION-Intel.dmg.sha256"' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq '/usr/bin/awk -v name="$intel_dmg_name"' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq -- '--draft' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'resume-draft' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'gh release download "$RELEASE_TAG"' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'test "$remote_digest" = "sha256:$staged_sha"' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'publication_mode=' "$ROOT/scripts/publish-staged-preview.sh"
draft_block="$(/usr/bin/sed -n '/^if \[\[ "$MODE" == "draft"/,/^if \[\[ "$MODE" == "prerelease"/p' \
  "$ROOT/scripts/publish-release.sh")"
print -r -- "$draft_block" | /usr/bin/grep -Fq -- '--draft'
print -r -- "$draft_block" | /usr/bin/grep -Fq 'download_and_compare_draft_candidate'
print -r -- "$draft_block" | /usr/bin/grep -Fq 'gh release view "$RELEASE_TAG" --repo "$REPOSITORY" --json isDraft,isPrerelease'
if print -r -- "$draft_block" | /usr/bin/grep -Fq 'gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG"'; then
  print -u2 "private Draft path still queries the REST release-by-tag endpoint"
  exit 1
fi
if print -r -- "$draft_block" | /usr/bin/grep -Eq 'dispatch_preview_recording_guard|verify_cdn_assets'; then
  print -u2 "private Draft path unexpectedly publishes to the public Preview delivery plane"
  exit 1
fi

/usr/bin/grep -Fq 'SOURCE_RUN_REQUIRED_CONCLUSION="${SOURCE_RUN_REQUIRED_CONCLUSION:-failure}"' \
  "$ROOT/scripts/resume-preview-publication.sh"
/usr/bin/grep -Fq 'REQUIRE_EXISTING_TAG="${REQUIRE_EXISTING_TAG:-1}"' \
  "$ROOT/scripts/resume-preview-publication.sh"
/usr/bin/grep -Fq 'REQUIRE_STAGED_SOURCE="${REQUIRE_STAGED_SOURCE:-0}"' \
  "$ROOT/scripts/resume-preview-publication.sh"
/usr/bin/grep -Fq '/bin/mkdir -p "$WORK_DIR"' \
  "$ROOT/scripts/resume-preview-publication.sh"
/usr/bin/grep -Fq '.conclusion == $conclusion' "$ROOT/scripts/resume-preview-publication.sh"
/usr/bin/grep -Fq 'remote_tag_commit' \
  "$ROOT/scripts/resume-preview-publication.sh"
/usr/bin/grep -Fq 'staged candidate tag points to a different commit' \
  "$ROOT/scripts/resume-preview-publication.sh"
/usr/bin/grep -Fq 'refs/tags/${TAG}:refs/tags/${TAG}' \
  "$ROOT/scripts/resume-preview-publication.sh"

/usr/bin/grep -Fq '.github/workflows/mac-preview-publication.yml' \
  "$ROOT/scripts/verify-release-control-plane-diff.sh"
if /usr/bin/grep -Fq '.github/workflows/mac-preview-publication.yml' \
    "$ROOT/scripts/release-pipeline-digest.sh"; then
  print -u2 "publication workflow unexpectedly changes the artifact-closure digest"
  exit 1
fi
if /usr/bin/grep -Fq 'config/release-dependencies.json' \
    "$ROOT/scripts/release-pipeline-digest.sh"; then
  print -u2 "product dependency values unexpectedly invalidate toolchain qualification"
  exit 1
fi

TAG_ORIGIN="$WORK_DIR/tag-origin.git"
TAG_SOURCE="$WORK_DIR/tag-source"
TAG_CANDIDATE="$WORK_DIR/tag-candidate"
FIXTURE_TAG="v9.9.9"
/usr/bin/git init -q --bare "$TAG_ORIGIN"
/usr/bin/git clone -q "$TAG_ORIGIN" "$TAG_SOURCE"
print -r -- 'exact tag fixture' > "$TAG_SOURCE/fixture.txt"
/usr/bin/git -C "$TAG_SOURCE" add fixture.txt
/usr/bin/git -C "$TAG_SOURCE" \
  -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -q -m fixture
/usr/bin/git -C "$TAG_SOURCE" tag "$FIXTURE_TAG"
/usr/bin/git -C "$TAG_SOURCE" push -q origin HEAD:main "$FIXTURE_TAG"
fixture_commit="$(/usr/bin/git -C "$TAG_SOURCE" rev-parse HEAD)"
/usr/bin/git init -q "$TAG_CANDIDATE"
/usr/bin/git -C "$TAG_CANDIDATE" remote add origin "$TAG_ORIGIN"
remote_tag_commit="$(/usr/bin/git -C "$TAG_CANDIDATE" ls-remote origin \
  "refs/tags/$FIXTURE_TAG" | /usr/bin/awk 'NR == 1 { print $1 }')"
test "$remote_tag_commit" = "$fixture_commit"
/usr/bin/git -C "$TAG_CANDIDATE" fetch --quiet --no-tags origin \
  "refs/tags/${FIXTURE_TAG}:refs/tags/${FIXTURE_TAG}"
test "$(/usr/bin/git -C "$TAG_CANDIDATE" rev-parse --verify "$FIXTURE_TAG^{commit}")" = "$fixture_commit"

stage="$WORK_DIR/preview-stage.json"
attestation="$WORK_DIR/preview-ui-attestation.json"
dist="$WORK_DIR/dist"
/bin/mkdir -p "$dist"
print -rn -- 'exact staged archive bytes' > "$dist/Remote-Mic-9.9.9.zip"
print -r -- '<enclosure url="https://download.sayall.app/mac/releases/v9.9.9/Remote-Mic-9.9.9.zip" />' \
  > "$dist/appcast.xml"
archive_sha="$(/usr/bin/shasum -a 256 "$dist/Remote-Mic-9.9.9.zip" | /usr/bin/awk '{print $1}')"
appcast_sha="$(/usr/bin/shasum -a 256 "$dist/appcast.xml" | /usr/bin/awk '{print $1}')"
test_appcast_sha="$(/usr/bin/sed 's#https://download.sayall.app/mac/releases/v9.9.9/#http://127.0.0.1:8765/#g' "$dist/appcast.xml" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
jq -n '{
  schemaVersion:1,
  tag:"v9.9.9",
  candidateBranch:"release/pre-v9.9.9",
  candidateCommit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  pipelineDigest:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  requestId:"request-9999",
  version:"9.9.9",
  build:"999",
  sourceRunId:101,
  sourceRunAttempt:1,
  signedArtifactId:202,
  signedArtifactDigest:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  requestStartedAt:1787590000,
  releaseReadyAt:1787590060,
  stagedAt:"2026-08-24T10:00:00Z"
}' > "$stage"

jq -n \
  --arg archiveSHA256 "$archive_sha" \
  --arg productionAppcastSHA256 "$appcast_sha" \
  --arg testAppcastSHA256 "$test_appcast_sha" '{
  schemaVersion:2,
  result:"passed",
  requestId:"request-9999",
  tag:"v9.9.9",
  candidateBranch:"release/pre-v9.9.9",
  candidateCommit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  pipelineDigest:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  sourceRunId:101,
  sourceRunAttempt:1,
  signedArtifactId:202,
  signedArtifactDigest:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  requestStartedAt:1787590000,
  releaseReadyAt:1787590060,
  target:{version:"9.9.9",build:"999"},
  observedFeedURL:"http://127.0.0.1:8765/appcast.xml",
  baseline:{
    tag:"v1.8.3",assetId:303,
    assetDigest:"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    version:"1.8.3",build:"64",developerTeamId:"L3QHLDRPAY",
    signatureVerified:true,notarizationValidated:true,gatekeeperAccepted:true,
    launched:true,launchedAt:"2026-08-24T10:00:30Z"
  },
  testedArtifact:{
    lane:"apple-silicon",
    feedURL:"http://127.0.0.1:8765/appcast.xml",
    productionURLPrefix:"https://download.sayall.app/mac/releases/v9.9.9/",
    testURLPrefix:"http://127.0.0.1:8765/",
    productionAppcast:"appcast.xml",
    productionAppcastSHA256:$productionAppcastSHA256,
    testAppcastSHA256:$testAppcastSHA256,
    archiveName:"Remote-Mic-9.9.9.zip",
    archiveSHA256:$archiveSHA256
  },
  update:{
    usedSparkleUI:true,
    feedURL:"http://127.0.0.1:8765/appcast.xml",
    checkStartedAt:"2026-08-24T10:01:00Z",
    downloadConfirmedAt:"2026-08-24T10:02:00Z",
    installConfirmedAt:"2026-08-24T10:03:00Z"
  },
  launches:{
    first:{startedAt:"2026-08-24T10:04:00Z",quitAt:"2026-08-24T10:05:00Z",succeeded:true},
    second:{startedAt:"2026-08-24T10:06:00Z",succeeded:true}
  },
  installedApp:{
    developerTeamId:"L3QHLDRPAY",
    codesignDeepStrict:true,
    notarizationValidated:true,
    gatekeeperAccepted:true,
    sparkleHelpersExecutable:true,
    sparkleLinksValid:true,
    mainExecutableSHA256:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    infoPlistSHA256:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  },
  crashReports:{checkedAt:"2026-08-24T10:07:00Z",newReports:[]},
  recordedAt:"2026-08-24T10:08:00Z"
}' > "$attestation"

"$ROOT/scripts/verify-preview-ui-attestation.sh" "$attestation" "$stage" "$dist" \
  > "$WORK_DIR/ui-pass.txt"
/usr/bin/grep -Fq 'PREVIEW UI ATTESTATION PASS' "$WORK_DIR/ui-pass.txt"

jq '.observedFeedURL = "https://github.com/HD838A/remote-mic-app/releases/download/v9.9.9/appcast.xml" | .update.feedURL = .observedFeedURL' \
  "$attestation" > "$WORK_DIR/ui-github-feed.json"
"$ROOT/scripts/verify-preview-ui-attestation.sh" \
  "$WORK_DIR/ui-github-feed.json" "$stage" "$dist" \
  > "$WORK_DIR/ui-github-feed-pass.txt"
/usr/bin/grep -Fq 'PREVIEW UI ATTESTATION PASS' "$WORK_DIR/ui-github-feed-pass.txt"

jq '.signedArtifactId = 999' "$attestation" > "$WORK_DIR/ui-wrong-artifact.json"
if "$ROOT/scripts/verify-preview-ui-attestation.sh" \
    "$WORK_DIR/ui-wrong-artifact.json" "$stage" "$dist" \
    > "$WORK_DIR/ui-wrong-artifact.txt" 2>&1; then
  print -u2 "UI attestation unexpectedly accepted another signed artifact"
  exit 1
fi

zsh -n \
  "$ROOT/scripts/resume-preview-publication.sh" \
  "$ROOT/scripts/prepare-staged-preview-ui-test.sh" \
  "$ROOT/scripts/record-preview-ui-attestation.sh" \
  "$ROOT/scripts/publish-staged-preview.sh"

print "RELEASE RESUME AND STAGED PUBLICATION TESTS PASS"
