#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
TAG="${RELEASE_TAG:?RELEASE_TAG is required}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:?EXPECTED_COMMIT is required}"
REQUEST_ID="${RELEASE_REQUEST_ID:?RELEASE_REQUEST_ID is required}"
SOURCE_RUN_ID="${SOURCE_RUN_ID:?SOURCE_RUN_ID is required}"
SOURCE_RUN_ATTEMPT="${SOURCE_RUN_ATTEMPT:?SOURCE_RUN_ATTEMPT is required}"
SOURCE_ARTIFACT_ID="${SOURCE_ARTIFACT_ID:?SOURCE_ARTIFACT_ID is required}"
SOURCE_ARTIFACT_DIGEST="${SOURCE_ARTIFACT_DIGEST:?SOURCE_ARTIFACT_DIGEST is required}"
REQUEST_STARTED_AT="${RELEASE_REQUEST_STARTED_AT:?RELEASE_REQUEST_STARTED_AT is required}"
BRANCH="release/pre-$TAG"
ALLOW_LATE_RECOVERY="${ALLOW_LATE_RECOVERY:-0}"
SOURCE_RUN_REQUIRED_CONCLUSION="${SOURCE_RUN_REQUIRED_CONCLUSION:-failure}"
REQUIRE_EXISTING_TAG="${REQUIRE_EXISTING_TAG:-1}"
REQUIRE_STAGED_SOURCE="${REQUIRE_STAGED_SOURCE:-0}"

[[ "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]]
[[ "$EXPECTED_COMMIT" =~ '^[0-9a-f]{40}$' ]]
[[ "$REQUEST_STARTED_AT" =~ '^[0-9]+$' ]]
[[ "$SOURCE_RUN_ID" =~ '^[1-9][0-9]*$' ]]
[[ "$SOURCE_RUN_ATTEMPT" =~ '^[1-9][0-9]*$' ]]
[[ "$SOURCE_ARTIFACT_ID" =~ '^[1-9][0-9]*$' ]]
[[ "$SOURCE_ARTIFACT_DIGEST" =~ '^sha256:[0-9a-f]{64}$' ]]
[[ "$ALLOW_LATE_RECOVERY" == 0 || "$ALLOW_LATE_RECOVERY" == 1 ]]
[[ "$SOURCE_RUN_REQUIRED_CONCLUSION" == failure || "$SOURCE_RUN_REQUIRED_CONCLUSION" == success ]]
[[ "$REQUIRE_EXISTING_TAG" == 0 || "$REQUIRE_EXISTING_TAG" == 1 ]]
[[ "$REQUIRE_STAGED_SOURCE" == 0 || "$REQUIRE_STAGED_SOURCE" == 1 ]]

for command_name in gh git jq shasum unzip sort uniq find; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

WORK_DIR="${RESUME_WORK_DIR:-$(/usr/bin/mktemp -d /private/tmp/sayall-preview-resume.XXXXXX)}"
CANDIDATE_DIR="$WORK_DIR/candidate"
ARTIFACT_ZIP="$WORK_DIR/signed-artifact.zip"
ARTIFACT_DIR="$WORK_DIR/signed-artifact"
ATTESTATION_DIR="$WORK_DIR/request-attestation"
STAGE_DIR="$WORK_DIR/preview-stage"

fail() { print -u2 -- "$*"; exit 1; }

now="$(date +%s)"
(( now - REQUEST_STARTED_AT >= 0 )) || fail "request_started_at is in the future"

source_run_json="$(gh api "repos/$REPOSITORY/actions/runs/$SOURCE_RUN_ID/attempts/$SOURCE_RUN_ATTEMPT")"
print -r -- "$source_run_json" | jq -e \
  --arg repository "$REPOSITORY" \
  --arg branch "$BRANCH" \
  --arg commit "$EXPECTED_COMMIT" \
  --arg conclusion "$SOURCE_RUN_REQUIRED_CONCLUSION" \
  --argjson attempt "$SOURCE_RUN_ATTEMPT" '
    .repository.full_name == $repository and
    .event == "workflow_dispatch" and
    .path == ".github/workflows/mac-release-package.yml" and
    .head_branch == $branch and
    .head_sha == $commit and
    .run_attempt == $attempt and
    .status == "completed" and
    .conclusion == $conclusion
  ' >/dev/null || fail "source release Run is not the exact candidate Run with conclusion $SOURCE_RUN_REQUIRED_CONCLUSION"

artifact_json="$(gh api "repos/$REPOSITORY/actions/artifacts/$SOURCE_ARTIFACT_ID")"
print -r -- "$artifact_json" | jq -e \
  --arg name "remote-mic-${TAG}-signed-macos" \
  --arg digest "$SOURCE_ARTIFACT_DIGEST" \
  --argjson run "$SOURCE_RUN_ID" \
  --arg branch "$BRANCH" \
  --arg commit "$EXPECTED_COMMIT" '
    .expired == false and .name == $name and .digest == $digest and
    .workflow_run.id == $run and
    .workflow_run.head_branch == $branch and
    .workflow_run.head_sha == $commit
  ' >/dev/null || fail "signed artifact identity does not match the source Run"

jobs_json="$(gh api "repos/$REPOSITORY/actions/runs/$SOURCE_RUN_ID/attempts/$SOURCE_RUN_ATTEMPT/jobs?per_page=100")"
print -r -- "$jobs_json" | jq -e '
  ([.jobs[] | select(
    .name == "Sign and notarize Apple Silicon and Intel packages" and
    .status == "completed" and .conclusion == "success" and
    ([.steps[] | select(.name == "Sign, notarize, staple, and verify both variants" and .conclusion == "success")] | length) == 1 and
    ([.steps[] | select(.name == "Upload signed release packages" and .conclusion == "success")] | length) == 1
  )] | length) == 1
' >/dev/null || fail "source Run did not produce a successful signed package Job"

if [[ "$REQUIRE_STAGED_SOURCE" == 1 ]]; then
  print -r -- "$jobs_json" | jq -e '
    ([.jobs[] | select(
      .name == "Sign and notarize Apple Silicon and Intel packages" and
      ([.steps[] | select(.name == "Record staged preview identity" and .conclusion == "success")] | length) == 1 and
      ([.steps[] | select(.name == "Upload staged preview identity" and .conclusion == "success")] | length) == 1
    )] | length) == 1
  ' >/dev/null || fail "source Run did not complete the staged preview identity handoff"

  stage_name="preview-stage-$TAG-$EXPECTED_COMMIT"
  stage_records="$(gh api "repos/$REPOSITORY/actions/runs/$SOURCE_RUN_ID/artifacts?per_page=100" | jq -r --arg name "$stage_name" '.artifacts[] | select(.name == $name and .expired == false) | [.id, (.digest // "")] | @tsv')"
  [[ "$(print -r -- "$stage_records" | awk 'NF {n++} END {print n+0}')" == 1 ]] || fail "staged preview identity artifact is not unique"
  IFS=$'\t' read -r stage_artifact_id stage_artifact_digest <<< "$stage_records"
  [[ "$stage_artifact_id" =~ ^[1-9][0-9]*$ && "$stage_artifact_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "staged preview identity metadata is invalid"
  stage_zip="$WORK_DIR/preview-stage.zip"
  gh api "repos/$REPOSITORY/actions/artifacts/$stage_artifact_id/zip" > "$stage_zip"
  [[ "sha256:$(shasum -a 256 "$stage_zip" | awk '{print $1}')" == "$stage_artifact_digest" ]] || fail "staged preview identity download digest mismatch"
  /bin/mkdir -p "$STAGE_DIR"
  unzip -q "$stage_zip" -d "$STAGE_DIR"
  stage_file="$STAGE_DIR/preview-stage.json"
  test -r "$stage_file" || fail "preview-stage.json is missing"
  jq -e \
    --arg tag "$TAG" \
    --arg branch "$BRANCH" \
    --arg commit "$EXPECTED_COMMIT" \
    --arg requestId "$REQUEST_ID" \
    --argjson run "$SOURCE_RUN_ID" \
    --argjson attempt "$SOURCE_RUN_ATTEMPT" \
    --argjson signedArtifactId "$SOURCE_ARTIFACT_ID" \
    --arg signedArtifactDigest "$SOURCE_ARTIFACT_DIGEST" '
      .schemaVersion == 1 and
      .tag == $tag and .candidateBranch == $branch and .candidateCommit == $commit and
      .requestId == $requestId and
      .sourceRunId == $run and .sourceRunAttempt == $attempt and
      .signedArtifactId == $signedArtifactId and
      .signedArtifactDigest == $signedArtifactDigest and
      (.pipelineDigest | test("^[0-9a-f]{64}$")) and
      (.version | type == "string" and length > 0) and
      (.build | test("^[0-9]+$")) and
      (.requestStartedAt | type == "number") and
      (.releaseReadyAt | type == "number") and
      (.stagedAt | type == "string")
    ' "$stage_file" >/dev/null || fail "staged preview identity does not match the signed artifact"
fi

gh api "repos/$REPOSITORY/actions/artifacts/$SOURCE_ARTIFACT_ID/zip" > "$ARTIFACT_ZIP"
actual_digest="sha256:$(shasum -a 256 "$ARTIFACT_ZIP" | awk '{print $1}')"
[[ "$actual_digest" == "$SOURCE_ARTIFACT_DIGEST" ]] || fail "signed artifact download digest mismatch"
/bin/mkdir -p "$ARTIFACT_DIR"
unzip -q "$ARTIFACT_ZIP" -d "$ARTIFACT_DIR"
entries=("${(@f)$(unzip -Z1 "$ARTIFACT_ZIP")}")
(( ${#entries[@]} > 0 )) || fail "signed artifact is empty"
duplicates="$(print -l -- "${entries[@]}" | sort | uniq -d)"
[[ -z "$duplicates" ]] || fail "signed artifact contains duplicate entries"
for entry in "${entries[@]}"; do
  [[ "$entry" != /* && "$entry" != *'../'* && "$entry" != ../* ]] || fail "signed artifact contains an unsafe path"
done
[[ -z "$(find "$ARTIFACT_DIR" -type l -print -quit)" ]] || fail "signed artifact contains a symlink"
[[ -z "$(find "$ARTIFACT_DIR" ! -type f ! -type d -print -quit)" ]] || fail "signed artifact contains a non-regular entry"

/bin/mkdir -p "$CANDIDATE_DIR"
git -C "$CANDIDATE_DIR" init -q
git -C "$CANDIDATE_DIR" remote add origin "https://github.com/$REPOSITORY.git"
if [[ "$REQUIRE_EXISTING_TAG" == 1 ]]; then
  git -C "$CANDIDATE_DIR" fetch --quiet --no-tags origin \
    "refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" \
    "refs/heads/main:refs/remotes/origin/main" \
    "refs/tags/${TAG}:refs/tags/${TAG}"
else
  git -C "$CANDIDATE_DIR" fetch --quiet --no-tags origin \
    "refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" \
    "refs/heads/main:refs/remotes/origin/main"
fi
git -C "$CANDIDATE_DIR" checkout -q --detach "$EXPECTED_COMMIT"
git -C "$CANDIDATE_DIR" rev-parse --verify "refs/remotes/origin/$BRANCH" | grep -Fxq "$EXPECTED_COMMIT" || fail "candidate branch changed"
if [[ "$REQUIRE_EXISTING_TAG" == 1 ]]; then
  git -C "$CANDIDATE_DIR" rev-parse --verify "$TAG^{commit}" | grep -Fxq "$EXPECTED_COMMIT" || fail "candidate tag changed"
else
  remote_tag_commit="$(git -C "$CANDIDATE_DIR" ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}" | awk '$2 ~ /\^\{\}$/ {print $1; found=1; exit} $2 !~ /\^\{\}$/ {fallback=$1} END {if (!found && fallback != "") print fallback}')"
  if [[ -n "$remote_tag_commit" ]]; then
    [[ "$remote_tag_commit" == "$EXPECTED_COMMIT" ]] || fail "staged candidate tag points to a different commit"
    git -C "$CANDIDATE_DIR" fetch --quiet --no-tags origin \
      "refs/tags/${TAG}:refs/tags/${TAG}"
    git -C "$CANDIDATE_DIR" rev-parse --verify "$TAG^{commit}" | grep -Fxq "$EXPECTED_COMMIT" || \
      fail "staged candidate tag could not be fetched locally"
  fi
fi

attestation_name="release-request-attestation-$TAG-$EXPECTED_COMMIT"
attestation_records="$(gh api "repos/$REPOSITORY/actions/runs/$SOURCE_RUN_ID/artifacts?per_page=100" | jq -r --arg name "$attestation_name" '.artifacts[] | select(.name == $name and .expired == false) | [.id, (.digest // "")] | @tsv')"
[[ "$(print -r -- "$attestation_records" | awk 'NF {n++} END {print n+0}')" == 1 ]] || fail "source request attestation artifact is not unique"
IFS=$'\t' read -r attestation_id attestation_digest <<< "$attestation_records"
[[ "$attestation_digest" =~ '^sha256:[0-9a-f]{64}$' ]] || fail "request attestation artifact digest is invalid"
attestation_zip="$WORK_DIR/request-attestation.zip"
gh api "repos/$REPOSITORY/actions/artifacts/$attestation_id/zip" > "$attestation_zip"
[[ "sha256:$(shasum -a 256 "$attestation_zip" | awk '{print $1}')" == "$attestation_digest" ]] || fail "request attestation download digest mismatch"
/bin/mkdir -p "$ATTESTATION_DIR"
unzip -q "$attestation_zip" -d "$ATTESTATION_DIR"
attestation="$ATTESTATION_DIR/release-request-attestation.json"
test -r "$attestation" || fail "request attestation JSON is missing"
jq -e \
  --arg requestId "$REQUEST_ID" \
  --arg tag "$TAG" \
  --arg commit "$EXPECTED_COMMIT" \
  --argjson started "$REQUEST_STARTED_AT" \
  '(.requestId == $requestId) and (.tag == $tag) and (.candidateCommit == $commit) and (.requestStartedAt == $started) and (.releaseReadyAt | type == "number" and floor == .)' \
  "$attestation" >/dev/null || fail "request attestation does not match the requested candidate"
release_ready_at="$(jq -r '.releaseReadyAt' "$attestation")"
(( now - release_ready_at >= 0 )) || fail "release_ready_at is in the future"
if (( now - release_ready_at >= 1740 )); then
  [[ "$ALLOW_LATE_RECOVERY" == 1 ]] || fail "the original release-ready preview budget is exhausted"
  print -u2 "LATE RECOVERY: original release-ready preview budget is exhausted; immutable clocks remain unchanged"
fi

candidate_pipeline_digest="$(jq -r '.pipelineDigest' "$attestation")"
[[ "$candidate_pipeline_digest" =~ '^[0-9a-f]{64}$' ]] || fail "candidate pipeline digest is invalid"
# Recompute with the exact candidate manifest; main may have added release files since it was signed.
REPOSITORY_ROOT="$CANDIDATE_DIR" "$CANDIDATE_DIR/scripts/release-pipeline-digest.sh" | grep -Fxq "$candidate_pipeline_digest" || fail "candidate pipeline digest changed"

/bin/mkdir -p "$CANDIDATE_DIR/dist"
/usr/bin/ditto --norsrc --noqtn --noacl "$ARTIFACT_DIR/" "$CANDIDATE_DIR/dist/"

print -r -- "candidate=$CANDIDATE_DIR"
print -r -- "request_attestation=$attestation"
print -r -- "candidate_pipeline_digest=$candidate_pipeline_digest"
print -r -- "release_ready_at=$release_ready_at"
if [[ "$REQUIRE_STAGED_SOURCE" == 1 ]]; then
  print -r -- "preview_stage=$stage_file"
fi
