#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
QUALIFICATION_REMOTE_NAME="${RELEASE_QUALIFICATION_REMOTE_NAME:-origin}"
EXPECTED_DIGEST="${1:-${EXPECTED_PIPELINE_DIGEST:-}}"
PROOF_OUTPUT="${RELEASE_READY_PROOF_OUTPUT:-}"
QUALIFICATION_BRANCH_PREFIX="${RELEASE_PIPELINE_QUALIFICATION_BRANCH_PREFIX:-release/pipeline-qualification/}"
WORK_DIR="${RELEASE_QUALIFICATION_WORK_DIR:-$(/usr/bin/mktemp -d /private/tmp/sayall-release-qualification.XXXXXX)}"

if [[ "$#" -gt 1 ]]; then
  print -u2 "usage: $0 [expected-pipeline-digest]"
  exit 2
fi
if [[ ! "$EXPECTED_DIGEST" =~ '^[0-9a-f]{64}$' ]]; then
  print -u2 "release pipeline qualification requires an exact SHA-256 digest"
  exit 2
fi
for command_name in jq shasum unzip "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

cd "$ROOT"
if [[ "$(./scripts/release-pipeline-digest.sh)" != "$EXPECTED_DIGEST" ]]; then
  print -u2 "current release pipeline digest does not match the requested qualification"
  exit 1
fi

/bin/mkdir -p "$WORK_DIR"
artifact_name="mac-release-pipeline-qualification-$EXPECTED_DIGEST"
artifact_json="$("$GH_BIN" api "repos/$REPOSITORY/actions/artifacts?name=$artifact_name&per_page=100")"
artifact_records=("${(@f)$(print -r -- "$artifact_json" | jq -r '.artifacts | map(select(.expired == false)) | sort_by(.created_at) | reverse | .[] | [.id, .workflow_run.id, .created_at, (.digest // "")] | @tsv')}")

for artifact_record in "${artifact_records[@]}"; do
  [[ -n "$artifact_record" ]] || continue
  IFS=$'\t' read -r artifact_id artifact_run_id artifact_created_at artifact_digest <<< "$artifact_record"
  [[ "$artifact_id" =~ '^[1-9][0-9]*$' &&
     "$artifact_run_id" =~ '^[1-9][0-9]*$' &&
     "$artifact_created_at" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' &&
     "$artifact_digest" =~ '^sha256:[0-9a-f]{64}$' ]] || continue
  artifact_zip="$WORK_DIR/$artifact_id.zip"
  extract_dir="$WORK_DIR/$artifact_id"
  /bin/mkdir -p "$extract_dir"
  "$GH_BIN" api "repos/$REPOSITORY/actions/artifacts/$artifact_id/zip" > "$artifact_zip"
  actual_artifact_digest="sha256:$(/usr/bin/shasum -a 256 "$artifact_zip" | /usr/bin/awk '{ print $1 }')"
  [[ "$actual_artifact_digest" == "$artifact_digest" ]] || continue
  /usr/bin/unzip -q "$artifact_zip" -d "$extract_dir"
  attestation="$extract_dir/release-pipeline-qualification.json"
  [[ -r "$attestation" ]] || continue

  run_id="$(jq -r '.workflowRunId // empty' "$attestation")"
  run_attempt="$(jq -r '.workflowRunAttempt // empty' "$attestation")"
  source_commit="$(jq -r '.sourceCommit // empty' "$attestation")"
  source_branch="$(jq -r '.sourceBranch // empty' "$attestation")"
  source_pull_request="$(jq -r '.sourcePullRequest // empty' "$attestation")"
  qualified_at="$(jq -r '.qualifiedAt // empty' "$attestation")"
  [[ "$run_id" == "$artifact_run_id" ]] || continue
  if ! jq -e \
    --arg digest "$EXPECTED_DIGEST" \
    --arg branchPrefix "$QUALIFICATION_BRANCH_PREFIX" '
      .schemaVersion == 2 and
      .pipelineDigest == $digest and
      (.sourceBranch | startswith($branchPrefix)) and
      (.sourceCommit | test("^[0-9a-f]{40}$")) and
      (.sourcePullRequest | type) == "number" and .sourcePullRequest > 0 and
      (.workflowRunId | type) == "number" and
      (.workflowRunAttempt | type) == "number" and
      (.qualifiedAt | type) == "string" and
      .expectedTeamId == "L3QHLDRPAY" and
      ([.ageVersion, .fastlaneVersion, .xcodeVersion, .xcodeBuild,
        .imageOS, .imageVersion, .jqVersion, .ripgrepVersion,
        .ghVersion, .gitVersion, .swiftVersion] |
        all(.[]; type == "string" and length > 0)) and
      .externalDependencies == {
        actionsCheckoutCommit: "fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
        actionsDownloadArtifactCommit: "634f93cb2916e3fdff6788551b99b062d0335ce0",
        actionsUploadArtifactCommit: "ea165f8d65b6e75b540449e92b4886f43607fa02",
        notarySecretsCommit: "5baaeaf56f6cd5fbd0fb0e08c9290077ba8b5b5d",
        matchCommit: "2e271768593821611c54f3d1b376f39e503f53be",
        sayAllAICommit: "01beeceac9c4091e7e8e122ad1e840ac5e5cee1c",
        sayAllMacroPlatformCommit: "76344d4d1a2d477e8f473c901a9f4d3d7b0f107c",
        sayAllMacRemoteCommit: "3f3c782180eef4024b53941c1f65d80e7cff4c66"
      }
    ' "$attestation" >/dev/null; then
    continue
  fi

  run_json="$("$GH_BIN" api "repos/$REPOSITORY/actions/runs/$run_id/attempts/$run_attempt")"
  if ! print -r -- "$run_json" | jq -e \
    --arg branch "$source_branch" \
    --arg sha "$source_commit" \
    --arg artifactCreatedAt "$artifact_created_at" \
    --arg qualifiedAt "$qualified_at" \
    --argjson attempt "$run_attempt" '
      .event == "workflow_dispatch" and
      .status == "completed" and
      .conclusion == "success" and
      .head_branch == $branch and
      .head_sha == $sha and
      .run_attempt == $attempt and
      .path == ".github/workflows/mac-release-package.yml" and
      (.created_at | type) == "string" and
      (.updated_at | type) == "string" and
      .created_at <= $qualifiedAt and $qualifiedAt <= $artifactCreatedAt and
      $artifactCreatedAt <= .updated_at
    ' >/dev/null; then
    continue
  fi

  source_pr_json="$("$GH_BIN" api "repos/$REPOSITORY/pulls/$source_pull_request")" || continue
  if ! print -r -- "$source_pr_json" | jq -e \
    --arg repository "$REPOSITORY" \
    --arg sha "$source_commit" '
      .base.ref == "main" and
      .head.repo.full_name == $repository and
      .head.sha == $sha and
      .merged_at != null
    ' >/dev/null; then
    continue
  fi
  if ! git fetch --no-tags "$QUALIFICATION_REMOTE_NAME" "refs/pull/$source_pull_request/head" >/dev/null; then
    continue
  fi
  git cat-file -e "$source_commit^{commit}" 2>/dev/null || continue
  source_pipeline_digest="$(REPOSITORY_ROOT="$ROOT" ./scripts/release-pipeline-digest.sh "$source_commit")" || continue
  [[ "$source_pipeline_digest" == "$EXPECTED_DIGEST" ]] || continue

  jobs_json="$("$GH_BIN" api "repos/$REPOSITORY/actions/runs/$run_id/attempts/$run_attempt/jobs?per_page=100")" || continue
  if ! print -r -- "$jobs_json" | jq -e '
    ([.jobs[] | select(
      .name == "Verify exact preview candidate CI and Draft recording PR" and
      .status == "completed" and .conclusion == "success" and
      ([.steps[] | select(
        .name == "Verify exact candidate or pipeline qualification provenance" and
        .conclusion == "success"
      )] | length) == 1
    )] | length) == 1 and
    ([.jobs[] | select(
      .name == "Sign and notarize Apple Silicon and Intel packages" and
      .status == "completed" and .conclusion == "success" and
      ([.steps[] | select(
        .name == "Sign, notarize, staple, and verify both variants" and
        .conclusion == "success"
      )] | length) == 1 and
      ([.steps[] | select(
        .name == "Record protected release pipeline qualification" and
        .conclusion == "success"
      )] | length) == 1 and
      ([.steps[] | select(
        .name == "Upload protected release pipeline qualification" and
        .conclusion == "success"
      )] | length) == 1
    )] | length) == 1
  ' >/dev/null; then
    continue
  fi

  if [[ -n "$PROOF_OUTPUT" ]]; then
    [[ -r "$PROOF_OUTPUT" ]] || {
      print -u2 "release-ready proof must exist before qualification is attached"
      exit 1
    }
    proof_temp="${PROOF_OUTPUT}.qualification.tmp"
    jq \
      --slurpfile qualification "$attestation" \
      --arg pipelineDigest "$EXPECTED_DIGEST" \
      --arg pipelineQualifiedAt "$artifact_created_at" \
      --argjson pipelineQualificationRunId "$run_id" \
      --argjson pipelineQualificationArtifactId "$artifact_id" \
      --arg pipelineQualificationArtifactDigest "$artifact_digest" \
      '. + {
        pipelineDigest: $pipelineDigest,
        pipelineQualifiedAt: $pipelineQualifiedAt,
        pipelineQualificationRunId: $pipelineQualificationRunId,
        pipelineQualificationArtifactId: $pipelineQualificationArtifactId,
        pipelineQualificationArtifactDigest: $pipelineQualificationArtifactDigest,
        ageVersion: $qualification[0].ageVersion,
        fastlaneVersion: $qualification[0].fastlaneVersion,
        xcodeVersion: $qualification[0].xcodeVersion,
        xcodeBuild: $qualification[0].xcodeBuild,
        imageOS: $qualification[0].imageOS,
        imageVersion: $qualification[0].imageVersion,
        jqVersion: $qualification[0].jqVersion,
        ripgrepVersion: $qualification[0].ripgrepVersion,
        ghVersion: $qualification[0].ghVersion,
        gitVersion: $qualification[0].gitVersion,
        swiftVersion: $qualification[0].swiftVersion,
        externalDependencies: $qualification[0].externalDependencies
      }' "$PROOF_OUTPUT" > "$proof_temp"
    /bin/mv "$proof_temp" "$PROOF_OUTPUT"
  fi

  print "RELEASE PIPELINE QUALIFICATION PASS"
  print "PIPELINE_DIGEST: $EXPECTED_DIGEST"
  print "QUALIFICATION_RUN_ID: $run_id"
  print "QUALIFIED_AT: $artifact_created_at"
  exit 0
done

print -u2 "no successful protected qualification exists for release pipeline $EXPECTED_DIGEST"
exit 1
