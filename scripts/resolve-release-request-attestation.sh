#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
REQUEST_ID="${1:-}"
RELEASE_TAG="${2:-}"
REQUEST_STARTED_AT="${3:-}"
CANDIDATE_COMMIT="${4:-}"
MAIN_CI_PROOF="${5:-}"
OUTPUT_FILE="${6:-}"
ATTESTATION_RUN_ID="${GITHUB_RUN_ID:-}"
ATTESTATION_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-}"
ATTESTATION_BRANCH="${GITHUB_REF_NAME:-}"

if [[ "$#" -ne 6 ]]; then
  print -u2 "usage: $0 <request-id> <tag> <request-started-epoch> <candidate-commit> <main-ci-proof.json> <output.json>"
  exit 2
fi
if [[ ! "$REQUEST_ID" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$' ||
      ! "$RELEASE_TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
      ! "$REQUEST_STARTED_AT" =~ '^[0-9]+$' ||
      ! "$CANDIDATE_COMMIT" =~ '^[0-9a-f]{40}$' ||
      ! "$ATTESTATION_RUN_ID" =~ '^[1-9][0-9]*$' ||
      ! "$ATTESTATION_RUN_ATTEMPT" =~ '^[1-9][0-9]*$' ||
      ! "$ATTESTATION_BRANCH" =~ '^release/pre-v[0-9]+\.[0-9]+\.[0-9]+$' ||
      "$ATTESTATION_BRANCH" != "release/pre-$RELEASE_TAG" ]]; then
  print -u2 "invalid release request attestation input"
  exit 2
fi
for command_name in jq unzip "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done
for required in "$MAIN_CI_PROOF"; do
  [[ -r "$required" ]] || { print -u2 "release request proof is unreadable"; exit 1; }
done
product_dependencies="$(REPOSITORY_ROOT="$ROOT" "$ROOT/scripts/resolve-release-dependencies.sh" json)"

completed_at="$(jq -r '.mainCiCompletedAt // empty' "$MAIN_CI_PROOF")"
candidate_gate_completed_at="$(jq -r '.candidateGateCompletedAt // empty' "$MAIN_CI_PROOF")"
pipeline_qualified_at="$(jq -r '.pipelineQualifiedAt // empty' "$MAIN_CI_PROOF")"
pipeline_digest="$(jq -r '.pipelineDigest // empty' "$MAIN_CI_PROOF")"
pipeline_qualification_run_id="$(jq -r '.pipelineQualificationRunId // empty' "$MAIN_CI_PROOF")"
pipeline_qualification_artifact_id="$(jq -r '.pipelineQualificationArtifactId // empty' "$MAIN_CI_PROOF")"
pipeline_qualification_artifact_digest="$(jq -r '.pipelineQualificationArtifactDigest // empty' "$MAIN_CI_PROOF")"
base_main_commit="$(jq -r '.baseMainCommit // empty' "$MAIN_CI_PROOF")"
proof_candidate_commit="$(jq -r '.candidateCommit // empty' "$MAIN_CI_PROOF")"
if [[ -z "$completed_at" || -z "$candidate_gate_completed_at" ||
      -z "$pipeline_qualified_at" ||
      ! "$pipeline_digest" =~ '^[0-9a-f]{64}$' ||
      ! "$pipeline_qualification_run_id" =~ '^[1-9][0-9]*$' ||
      ! "$pipeline_qualification_artifact_id" =~ '^[1-9][0-9]*$' ||
      ! "$pipeline_qualification_artifact_digest" =~ '^sha256:[0-9a-f]{64}$' ||
      ! "$base_main_commit" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "release proof lacks a trusted main/candidate/pipeline qualification timestamp or identity"
  exit 1
fi
if ! jq -e '
  ([.ageVersion, .fastlaneVersion, .xcodeVersion, .xcodeBuild,
    .imageOS, .imageVersion, .jqVersion, .ripgrepVersion,
    .ghVersion, .gitVersion, .swiftVersion] |
    all(.[]; type == "string" and length > 0)) and
  .externalDependencies == {
    actionsCheckoutCommit: "fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
    actionsDownloadArtifactCommit: "634f93cb2916e3fdff6788551b99b062d0335ce0",
    actionsUploadArtifactCommit: "ea165f8d65b6e75b540449e92b4886f43607fa02",
    notarySecretsCommit: "5baaeaf56f6cd5fbd0fb0e08c9290077ba8b5b5d",
    matchCommit: "2e271768593821611c54f3d1b376f39e503f53be"
  }
' "$MAIN_CI_PROOF" >/dev/null; then
  print -u2 "release proof lacks the exact qualified toolchain or external dependency commits"
  exit 1
fi
qualified_toolchain="$(jq -c '{
  ageVersion,
  fastlaneVersion,
  xcodeVersion,
  xcodeBuild,
  imageOS,
  imageVersion,
  jqVersion,
  ripgrepVersion,
  ghVersion,
  gitVersion,
  swiftVersion,
  externalDependencies
}' "$MAIN_CI_PROOF")"
if [[ "$proof_candidate_commit" != "$CANDIDATE_COMMIT" ]]; then
  print -u2 "main CI proof does not belong to the exact candidate commit"
  exit 1
fi
parse_timestamp() {
  local timestamp="$1"
  if /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" +%s 2>/dev/null; then
    return 0
  fi
  /bin/date -u -d "$timestamp" +%s 2>/dev/null
}

main_ci_epoch="$(parse_timestamp "$completed_at")" || {
  print -u2 "cannot parse main CI completion timestamp: $completed_at"
  exit 1
}
candidate_gate_epoch="$(parse_timestamp "$candidate_gate_completed_at")" || {
  print -u2 "cannot parse candidate gate completion timestamp: $candidate_gate_completed_at"
  exit 1
}
pipeline_qualified_epoch="$(parse_timestamp "$pipeline_qualified_at")" || {
  print -u2 "cannot parse pipeline qualification timestamp: $pipeline_qualified_at"
  exit 1
}
ready_epoch="$REQUEST_STARTED_AT"
(( main_ci_epoch > ready_epoch )) && ready_epoch="$main_ci_epoch"
(( candidate_gate_epoch > ready_epoch )) && ready_epoch="$candidate_gate_epoch"
(( pipeline_qualified_epoch > ready_epoch )) && ready_epoch="$pipeline_qualified_epoch"

artifact_name="release-request-attestation-$RELEASE_TAG-$CANDIDATE_COMMIT"
work_dir="$(/usr/bin/mktemp -d /private/tmp/sayall-release-attestation.XXXXXX)"
artifact_json="$($GH_BIN api "repos/$REPOSITORY/actions/artifacts?name=$artifact_name&per_page=100")"
artifact_records=("${(@f)$(print -r -- "$artifact_json" | jq -r '.artifacts[] | select(.expired == false) | [.id, .workflow_run.id] | @tsv')}")

expected_json="$(jq -n \
  --arg requestId "$REQUEST_ID" \
  --arg tag "$RELEASE_TAG" \
  --argjson requestStartedAt "$REQUEST_STARTED_AT" \
  --argjson releaseReadyAt "$ready_epoch" \
  --arg candidateCommit "$CANDIDATE_COMMIT" \
  --arg attemptId "$CANDIDATE_COMMIT" \
  --arg baseMainCommit "$base_main_commit" \
  --arg mainCiCompletedAt "$completed_at" \
  --arg candidateGateCompletedAt "$candidate_gate_completed_at" \
  --arg pipelineDigest "$pipeline_digest" \
  --arg pipelineQualifiedAt "$pipeline_qualified_at" \
  --argjson pipelineQualificationRunId "$pipeline_qualification_run_id" \
  --argjson pipelineQualificationArtifactId "$pipeline_qualification_artifact_id" \
  --arg pipelineQualificationArtifactDigest "$pipeline_qualification_artifact_digest" \
  --argjson qualifiedToolchain "$qualified_toolchain" \
  --argjson productDependencies "$product_dependencies" \
  --argjson attestationRunId "$ATTESTATION_RUN_ID" \
  --argjson attestationRunAttempt "$ATTESTATION_RUN_ATTEMPT" \
  --arg attestationBranch "$ATTESTATION_BRANCH" \
  '({schemaVersion:5,requestId:$requestId,attemptId:$attemptId,tag:$tag,requestStartedAt:$requestStartedAt,releaseReadyAt:$releaseReadyAt,candidateCommit:$candidateCommit,baseMainCommit:$baseMainCommit,mainCiCompletedAt:$mainCiCompletedAt,candidateGateCompletedAt:$candidateGateCompletedAt,pipelineDigest:$pipelineDigest,pipelineQualifiedAt:$pipelineQualifiedAt,pipelineQualificationRunId:$pipelineQualificationRunId,pipelineQualificationArtifactId:$pipelineQualificationArtifactId,pipelineQualificationArtifactDigest:$pipelineQualificationArtifactDigest,productDependencies:$productDependencies,attestationRunId:$attestationRunId,attestationRunAttempt:$attestationRunAttempt,attestationBranch:$attestationBranch} + $qualifiedToolchain)')"

locked_payload=""
for artifact_record in "${artifact_records[@]}"; do
  [[ -n "$artifact_record" ]] || continue
  IFS=$'\t' read -r artifact_id artifact_run_id <<< "$artifact_record"
  if [[ ! "$artifact_id" =~ '^[1-9][0-9]*$' || ! "$artifact_run_id" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "release request attestation artifact metadata is malformed"
    exit 1
  fi
  zip_path="$work_dir/$artifact_id.zip"
  extract_dir="$work_dir/$artifact_id"
  "$GH_BIN" api "repos/$REPOSITORY/actions/artifacts/$artifact_id/zip" > "$zip_path"
  /bin/mkdir -p "$extract_dir"
  /usr/bin/unzip -q "$zip_path" -d "$extract_dir"
  existing_file="$extract_dir/release-request-attestation.json"
  [[ -r "$existing_file" ]] || { print -u2 "existing release attestation artifact is malformed"; exit 1; }
  existing_json="$(jq -S . "$existing_file")" || {
    print -u2 "existing release attestation artifact is malformed"
    exit 1
  }
  if [[ "$(print -r -- "$existing_json" | jq -r '.schemaVersion // empty')" != "5" ]]; then
    print -u2 "legacy exact-candidate request attestation requires explicit migration; refusing to reset its clock"
    exit 1
  fi
  existing_run_id="$(print -r -- "$existing_json" | jq -r '.attestationRunId // empty')"
  existing_run_attempt="$(print -r -- "$existing_json" | jq -r '.attestationRunAttempt // empty')"
  existing_branch="$(print -r -- "$existing_json" | jq -r '.attestationBranch // empty')"
  if [[ "$existing_run_id" != "$artifact_run_id" ||
        ! "$existing_run_attempt" =~ '^[1-9][0-9]*$' ||
        "$existing_branch" != "release/pre-$RELEASE_TAG" ]]; then
    print -u2 "release request attestation artifact is not bound to its workflow run"
    exit 1
  fi

  existing_run_json="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$existing_run_id/attempts/$existing_run_attempt")" || {
    print -u2 "cannot verify the workflow run that issued the release request attestation"
    exit 1
  }
  if ! print -r -- "$existing_run_json" | jq -e \
    --arg branch "$existing_branch" \
    --arg sha "$CANDIDATE_COMMIT" \
    --argjson attempt "$existing_run_attempt" '
      .event == "workflow_dispatch" and
      .head_branch == $branch and
      .head_sha == $sha and
      .run_attempt == $attempt and
      .path == ".github/workflows/mac-release-package.yml"
    ' >/dev/null; then
    print -u2 "release request attestation was issued by an unexpected workflow run"
    exit 1
  fi
  existing_jobs_json="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$existing_run_id/attempts/$existing_run_attempt/jobs?per_page=100")" || {
    print -u2 "cannot verify the job that issued the release request attestation"
    exit 1
  }
  if ! print -r -- "$existing_jobs_json" | jq -e '
    ([.jobs[] | select(
      .name == "Verify exact preview candidate CI and Draft recording PR" and
      .status == "completed" and .conclusion == "success" and
      ([.steps[] | select(.name == "Resolve immutable request attestation" and .conclusion == "success")] | length) == 1 and
      ([.steps[] | select(.name == "Persist first request timestamps" and .conclusion == "success")] | length) == 1
    )] | length) == 1
  ' >/dev/null; then
    print -u2 "release request attestation was not produced by the successful validation job"
    exit 1
  fi

  existing_payload="$(print -r -- "$existing_json" | jq -S 'del(.attestationRunId, .attestationRunAttempt, .attestationBranch)')"
  if [[ -n "$locked_payload" && "$existing_payload" != "$locked_payload" ]]; then
    print -u2 "release request attestation artifacts disagree for $RELEASE_TAG"
    exit 1
  fi
  locked_payload="$existing_payload"
done

if [[ -n "$locked_payload" ]]; then
  if ! print -r -- "$locked_payload" | jq -e \
    --arg requestId "$REQUEST_ID" \
    --arg tag "$RELEASE_TAG" \
    --argjson requestStartedAt "$REQUEST_STARTED_AT" \
    --arg candidateCommit "$CANDIDATE_COMMIT" \
    --arg baseMainCommit "$base_main_commit" \
    --arg pipelineDigest "$pipeline_digest" \
    --argjson pipelineQualificationArtifactId "$pipeline_qualification_artifact_id" \
    --arg pipelineQualificationArtifactDigest "$pipeline_qualification_artifact_digest" \
    --argjson qualifiedToolchain "$qualified_toolchain" \
    --argjson productDependencies "$product_dependencies" '
      .schemaVersion == 5 and
      .requestId == $requestId and .tag == $tag and
      .requestStartedAt == $requestStartedAt and
      .attemptId == $candidateCommit and
      .candidateCommit == $candidateCommit and
      .baseMainCommit == $baseMainCommit and
      .pipelineDigest == $pipelineDigest and
      .pipelineQualificationArtifactId == $pipelineQualificationArtifactId and
      .pipelineQualificationArtifactDigest == $pipelineQualificationArtifactDigest and
      .productDependencies == $productDependencies and
      ({ageVersion,fastlaneVersion,xcodeVersion,xcodeBuild,imageOS,imageVersion,
        jqVersion,ripgrepVersion,ghVersion,gitVersion,swiftVersion,externalDependencies} == $qualifiedToolchain) and
      (.releaseReadyAt | type) == "number" and
      .releaseReadyAt >= .requestStartedAt and
      (.mainCiCompletedAt | type) == "string" and
      (.candidateGateCompletedAt | type) == "string" and
      (.pipelineDigest | test("^[0-9a-f]{64}$")) and
      (.pipelineQualifiedAt | type) == "string" and
      (.pipelineQualificationRunId | type) == "number" and
      (.pipelineQualificationArtifactId | type) == "number" and
      (.pipelineQualificationArtifactDigest | test("^sha256:[0-9a-f]{64}$"))
    ' >/dev/null; then
    print -u2 "release request timestamps/identity are immutable for candidate $CANDIDATE_COMMIT"
    exit 1
  fi

  locked_main_ci_epoch="$(parse_timestamp "$(print -r -- "$locked_payload" | jq -r '.mainCiCompletedAt')")" || exit 1
  locked_candidate_gate_epoch="$(parse_timestamp "$(print -r -- "$locked_payload" | jq -r '.candidateGateCompletedAt')")" || exit 1
  locked_pipeline_qualified_epoch="$(parse_timestamp "$(print -r -- "$locked_payload" | jq -r '.pipelineQualifiedAt')")" || exit 1
  locked_ready_epoch="$REQUEST_STARTED_AT"
  (( locked_main_ci_epoch > locked_ready_epoch )) && locked_ready_epoch="$locked_main_ci_epoch"
  (( locked_candidate_gate_epoch > locked_ready_epoch )) && locked_ready_epoch="$locked_candidate_gate_epoch"
  (( locked_pipeline_qualified_epoch > locked_ready_epoch )) && locked_ready_epoch="$locked_pipeline_qualified_epoch"
  if [[ "$(print -r -- "$locked_payload" | jq -r '.releaseReadyAt')" != "$locked_ready_epoch" ]]; then
    print -u2 "stored releaseReadyAt does not equal the trusted readiness maximum"
    exit 1
  fi
  ready_epoch="$locked_ready_epoch"
  expected_json="$(print -r -- "$locked_payload" | jq \
    --argjson attestationRunId "$ATTESTATION_RUN_ID" \
    --argjson attestationRunAttempt "$ATTESTATION_RUN_ATTEMPT" \
    --arg attestationBranch "$ATTESTATION_BRANCH" \
    '. + {attestationRunId:$attestationRunId,attestationRunAttempt:$attestationRunAttempt,attestationBranch:$attestationBranch}')"
fi

/bin/mkdir -p "${OUTPUT_FILE:h}"
print -r -- "$expected_json" | jq -S . > "$OUTPUT_FILE"
print "RELEASE REQUEST ATTESTATION PASS"
print "REQUEST_ID: $REQUEST_ID"
print "REQUEST_STARTED_AT: $REQUEST_STARTED_AT"
print "RELEASE_READY_AT: $ready_epoch"
