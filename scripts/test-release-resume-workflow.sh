#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORKFLOW="$ROOT/.github/workflows/mac-release-package.yml"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-release-resume-test.XXXXXX)"
STEP_SCRIPT="$WORK_DIR/resolve-existing-preview.sh"
RECOVERY_CONTROL_SCRIPT="$WORK_DIR/recovery-control-plane.sh"
FAKE_BIN="$WORK_DIR/bin"
EXPECTED_COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_COMMIT="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RELEASE_TAG="v9.9.9"
REQUEST_ID="request-9999"
PIPELINE_DIGEST="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
QUALIFICATION_ARTIFACT_DIGEST="sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

cleanup() {
  local trash_root="$HOME/.Trash"
  local trash_target
  trash_target="$trash_root/remotemic-release-resume-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$trash_root"
  if [[ -d "$WORK_DIR" ]]; then
    /bin/mv "$WORK_DIR" "$trash_target"
  fi
}
trap cleanup EXIT

for required_text in \
  'preview_release_action: ${{ steps.preview-publication-state.outputs.action }}' \
  "if: \${{ inputs.release_mode == 'qualification' || needs.validate-candidate.outputs.preview_release_action == 'package' }}" \
  'needs.validate-candidate.outputs.preview_release_action == '\''verify-only'\''' \
  'Download verification-resume ledger' \
  './scripts/publish-release.sh verify-prerelease' \
  'ALLOW_LATE_RECOVERY: 1' \
  'LATE RECOVERY: original release-ready preview SLO is failed and will be reported as overrun.' \
  'late-recovery-after-slo' \
  'Preview requires stable latest $EXPECTED_STABLE_TAG; found $actual_stable_tag' \
  'Existing exact Pre-release found; protected packaging will be skipped and public bytes verified in place.'; do
  /usr/bin/grep -Fq -- "$required_text" "$WORKFLOW"
done

/usr/bin/grep -Fq -- '(.state == \"open\" or .merged_at != null)' "$WORKFLOW"
/usr/bin/grep -Fq -- 'qualification_open_or_merged' \
  "$ROOT/scripts/verify-release-control-plane-diff.sh"
/usr/bin/grep -Fq -- 'PRODUCT_PROOF_COMMIT' \
  "$ROOT/scripts/verify-release-ready-main-ci.sh"
/usr/bin/grep -Fq -- 'verify-release-control-plane-diff.sh' \
  "$ROOT/scripts/verify-release-ready-main-ci.sh"

/usr/bin/grep -Fq -- '      - name: Validate recovery control plane' "$WORKFLOW"
/usr/bin/awk '
  $0 == "      - name: Validate recovery control plane" {
    in_step = 1
    next
  }
  in_step && $0 == "        run: |" {
    in_run = 1
    next
  }
  in_run && $0 ~ /^      - name:/ { exit }
  in_run {
    sub(/^          /, "")
    print
  }
' "$WORKFLOW" > "$RECOVERY_CONTROL_SCRIPT"
test -s "$RECOVERY_CONTROL_SCRIPT"
/usr/bin/grep -Fq -- 'test -r scripts/resume-preview-publication.sh' "$RECOVERY_CONTROL_SCRIPT"
if /usr/bin/grep -Eq 'release-pipeline-digest\.sh|verify-release-pipeline-qualification\.sh|environment: mac-release|secrets\.' "$RECOVERY_CONTROL_SCRIPT"; then
  print -u2 "recovery control-plane validation must not require artifact qualification or release credentials"
  exit 1
fi

/usr/bin/grep -Fq -- \
  'REPOSITORY_ROOT="$CANDIDATE_DIR" "$CANDIDATE_DIR/scripts/release-pipeline-digest.sh"' \
  "$ROOT/scripts/resume-preview-publication.sh"
/usr/bin/grep -Fq -- \
  'branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq -- \
  'branch="${branch:-${RELEASE_CANDIDATE_BRANCH:-${GITHUB_REF_NAME:-}}}"' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq -- '"$SOURCE_ROOT/scripts/verify-app.sh"' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq -- '"$SOURCE_ROOT/scripts/verify-doubao-driver-pkg.sh"' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq -- '"$SOURCE_ROOT/scripts/verify-dmg.sh"' "$ROOT/scripts/publish-release.sh"

package_if_line="$(/usr/bin/grep -nF "if: \${{ inputs.release_mode == 'qualification' || needs.validate-candidate.outputs.preview_release_action == 'package' }}" "$WORKFLOW" | /usr/bin/awk -F: 'NR == 1 { print $1 }')"
package_environment_line="$(/usr/bin/awk '/^  package:$/ { in_package = 1; next } in_package && /environment: mac-release/ { print NR; exit }' "$WORKFLOW")"
if [[ ! "$package_if_line" =~ ^[0-9]+$ ||
      ! "$package_environment_line" =~ ^[0-9]+$ ||
      "$package_if_line" -ge "$package_environment_line" ]]; then
  print -u2 "protected package job is not gated before the mac-release Environment"
  exit 1
fi

/usr/bin/awk '
  $0 == "      - name: Resolve existing Preview publication state" {
    in_step = 1
    next
  }
  in_step && $0 == "        run: |" {
    in_run = 1
    next
  }
  in_run && $0 ~ /^      - name:/ { exit }
  in_run {
    sub(/^          /, "")
    print
  }
' "$WORKFLOW" > "$STEP_SCRIPT"
test -s "$STEP_SCRIPT"

if /usr/bin/grep -Eq 'secrets\.|RELEASE_AGE_IDENTITY|DEPLOY_KEY|MATCH_PASSWORD|notary' "$STEP_SCRIPT"; then
  print -u2 "pre-credential Preview recovery step unexpectedly references release credentials"
  exit 1
fi

/bin/mkdir -p "$FAKE_BIN"
{
  print '#!/bin/bash'
  print 'set -euo pipefail'
  print 'scenario="${FAKE_GH_SCENARIO:?}"'
  print 'expected_commit="${EXPECTED_COMMIT:?}"'
  print 'other_commit="${OTHER_COMMIT:?}"'
  print 'if [[ "${1:-}" == "api" ]]; then'
  print '  shift'
  print '  if [[ "${1:-}" == "--include" ]]; then'
  print '    case "$scenario" in'
  print '      not-found) printf '\''HTTP/2.0 404 Not Found\n\n{}\n'\''; exit 1 ;;'
  print '      api-error) printf '\''HTTP/2.0 500 Internal Server Error\n\n{}\n'\''; exit 1 ;;'
  print '      *) printf '\''HTTP/2.0 200 OK\n\n{}\n'\''; exit 0 ;;'
  print '    esac'
  print '  fi'
  print '  endpoint="${1:-}"'
  print '  case "$endpoint" in'
  print '    */releases/latest)'
  print '      if [[ "$scenario" == "wrong-latest" ]]; then printf '\''v1.9.9\n'\''; else printf '\''v1.8.3\n'\''; fi'
  print '      ;;'
  print '    */releases/tags/*)'
  print '      case "$scenario" in'
  print '        stable) draft=false; prerelease=false; asset_name=candidate-provenance.json ;;'
  print '        draft) draft=true; prerelease=true; asset_name=candidate-provenance.json ;;'
  print '        missing-provenance) draft=false; prerelease=true; asset_name=other.txt ;;'
  print '        *) draft=false; prerelease=true; asset_name=candidate-provenance.json ;;'
  print '      esac'
  print '      printf '\''{"tag_name":"v9.9.9","draft":%s,"prerelease":%s,"assets":[{"name":"%s"}]}\n'\'' "$draft" "$prerelease" "$asset_name"'
  print '      ;;'
  print '    */git/ref/heads/*)'
  print '      if [[ "$scenario" == "branch-mismatch" ]]; then printf '\''%s\n'\'' "$other_commit"; else printf '\''%s\n'\'' "$expected_commit"; fi'
  print '      ;;'
  print '    */git/ref/tags/*)'
  print '      if [[ "$scenario" == "tag-mismatch" ]]; then printf '\''commit\t%s\n'\'' "$other_commit"; else printf '\''commit\t%s\n'\'' "$expected_commit"; fi'
  print '      ;;'
  print '    *) printf '\''unexpected gh api endpoint: %s\n'\'' "$endpoint" >&2; exit 2 ;;'
  print '  esac'
  print '  exit 0'
  print 'fi'
  print 'if [[ "${1:-}" == "release" && "${2:-}" == "download" ]]; then'
  print '  destination=""'
  print '  while (( $# != 0 )); do'
  print '    if [[ "$1" == "--dir" ]]; then destination="$2"; shift 2; else shift; fi'
  print '  done'
  print '  test -n "$destination"'
  print '  /bin/cp "$FAKE_PROVENANCE" "$destination/candidate-provenance.json"'
  print '  exit 0'
  print 'fi'
  print 'printf '\''unexpected gh invocation: %s\n'\'' "$*" >&2'
  print 'exit 2'
} > "$FAKE_BIN/gh"
/bin/chmod 755 "$FAKE_BIN/gh"

write_provenance() {
  local scenario="$1"
  local commit="$EXPECTED_COMMIT"
  local branch="release/pre-$RELEASE_TAG"
  local version="${RELEASE_TAG#v}"
  local schema_version=3
  local request_id="$REQUEST_ID"
  local pipeline_digest="$PIPELINE_DIGEST"
  local qualification_artifact_id=202
  case "$scenario" in
    matching-legacy-schema2) schema_version=2 ;;
    provenance-commit-mismatch) commit="$OTHER_COMMIT" ;;
    provenance-branch-mismatch) branch="release/pre-$RELEASE_TAG-rerun2" ;;
    provenance-version-mismatch) version="9.9.8" ;;
    provenance-request-id-mismatch) request_id="different-request" ;;
    provenance-pipeline-digest-mismatch)
      pipeline_digest="abababababababababababababababababababababababababababababababab"
      ;;
    provenance-qualification-artifact-mismatch) qualification_artifact_id=999 ;;
  esac
  jq -n \
    --argjson schemaVersion "$schema_version" \
    --arg commit "$commit" \
    --arg branch "$branch" \
    --arg tag "$RELEASE_TAG" \
    --arg version "$version" \
    --arg requestId "$request_id" \
    --arg pipelineDigest "$pipeline_digest" \
    --arg qualificationArtifactDigest "$QUALIFICATION_ARTIFACT_DIGEST" \
    --argjson qualificationArtifactId "$qualification_artifact_id" \
    '{
      schemaVersion: $schemaVersion,
      repository: "HD838A/remote-mic-app",
      candidateBranch: $branch,
      tag: $tag,
      tagCommit: $commit,
      baseMainCommit: "cccccccccccccccccccccccccccccccccccccccc",
      version: $version,
      build: "999",
      payloadAssets: [{
        name: "Remote-Mic-9.9.9.zip",
        size: 123,
        sha256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      }]
    } + (if $schemaVersion == 3 then {
      requestId: $requestId,
      attemptId: $commit,
      requestStartedAt: 1777777000,
      releaseReadyAt: 1777777060,
      pipelineDigest: $pipelineDigest,
      pipelineQualifiedAt: "2026-08-24T10:00:00Z",
      pipelineQualificationRunId: 101,
      pipelineQualificationArtifactId: $qualificationArtifactId,
      pipelineQualificationArtifactDigest: $qualificationArtifactDigest,
      requestAttestationRunId: 303,
      requestAttestationRunAttempt: 1
    } else {} end)' > "$WORK_DIR/provenance-$scenario.json"
}

write_request_attestation() {
  local output_file="$1"
  jq -n \
    --arg requestId "$REQUEST_ID" \
    --arg tag "$RELEASE_TAG" \
    --arg commit "$EXPECTED_COMMIT" \
    --arg pipelineDigest "$PIPELINE_DIGEST" \
    --arg qualificationArtifactDigest "$QUALIFICATION_ARTIFACT_DIGEST" \
    '{
      schemaVersion: 4,
      requestId: $requestId,
      attemptId: $commit,
      tag: $tag,
      candidateCommit: $commit,
      baseMainCommit: "cccccccccccccccccccccccccccccccccccccccc",
      requestStartedAt: 1777777000,
      releaseReadyAt: 1777777060,
      pipelineDigest: $pipelineDigest,
      pipelineQualifiedAt: "2026-08-24T10:00:00Z",
      pipelineQualificationRunId: 101,
      pipelineQualificationArtifactId: 202,
      pipelineQualificationArtifactDigest: $qualificationArtifactDigest,
      attestationRunId: 404,
      attestationRunAttempt: 2
    }' > "$output_file"
}

run_case() {
  local scenario="$1"
  local expected_result="$2"
  local expected_action="${3:-}"
  local case_dir="$WORK_DIR/case-$scenario"
  local output_file="$case_dir/github-output.txt"
  /bin/mkdir -p "$case_dir/runner-temp"
  write_request_attestation "$case_dir/runner-temp/release-request-attestation.json"
  : > "$output_file"
  write_provenance "$scenario"

  set +e
  PATH="$FAKE_BIN:$PATH" \
    FAKE_GH_SCENARIO="$scenario" \
    FAKE_PROVENANCE="$WORK_DIR/provenance-$scenario.json" \
    EXPECTED_COMMIT="$EXPECTED_COMMIT" \
    OTHER_COMMIT="$OTHER_COMMIT" \
    GITHUB_OUTPUT="$output_file" \
    GITHUB_REPOSITORY="HD838A/remote-mic-app" \
    RUNNER_TEMP="$case_dir/runner-temp" \
    RELEASE_TAG="$RELEASE_TAG" \
    RELEASE_REQUEST_ID="$REQUEST_ID" \
    EXPECTED_PIPELINE_DIGEST="$PIPELINE_DIGEST" \
    EXPECTED_STABLE_TAG=v1.8.3 \
    /bin/bash "$STEP_SCRIPT" > "$case_dir/stdout.txt" 2> "$case_dir/stderr.txt"
  local command_status="$?"
  set -e

  if [[ "$expected_result" == "pass" ]]; then
    if [[ "$command_status" != "0" ]]; then
      print -u2 "Preview recovery case $scenario unexpectedly failed"
      /bin/cat "$case_dir/stderr.txt" >&2
      exit 1
    fi
    /usr/bin/grep -Fxq "action=$expected_action" "$output_file"
  elif [[ "$command_status" == "0" ]]; then
    print -u2 "Preview recovery case $scenario unexpectedly passed"
    exit 1
  fi
}

run_case not-found pass package
run_case matching pass verify-only
run_case matching-legacy-schema2 pass verify-only
for rejected_case in \
  api-error \
  wrong-latest \
  stable \
  draft \
  missing-provenance \
  branch-mismatch \
  tag-mismatch \
  provenance-commit-mismatch \
  provenance-branch-mismatch \
  provenance-version-mismatch \
  provenance-request-id-mismatch \
  provenance-pipeline-digest-mismatch \
  provenance-qualification-artifact-mismatch; do
  run_case "$rejected_case" fail
done

print "RELEASE RESUME WORKFLOW TEST PASS"
