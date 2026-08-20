#!/bin/zsh
set -euo pipefail
umask 077

REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
REQUEST_ID="${1:-}"
RELEASE_TAG="${2:-}"
REQUEST_STARTED_AT="${3:-}"
CANDIDATE_COMMIT="${4:-}"
MAIN_CI_PROOF="${5:-}"
OUTPUT_FILE="${6:-}"

if [[ "$#" -ne 6 ]]; then
  print -u2 "usage: $0 <request-id> <tag> <request-started-epoch> <candidate-commit> <main-ci-proof.json> <output.json>"
  exit 2
fi
if [[ ! "$REQUEST_ID" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$' ||
      ! "$RELEASE_TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
      ! "$REQUEST_STARTED_AT" =~ '^[0-9]+$' ||
      ! "$CANDIDATE_COMMIT" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "invalid release request attestation input"
  exit 2
fi
for required in "$MAIN_CI_PROOF"; do
  [[ -r "$required" ]] || { print -u2 "release request proof is unreadable"; exit 1; }
done

completed_at="$(jq -r '.mainCiCompletedAt // empty' "$MAIN_CI_PROOF")"
candidate_gate_completed_at="$(jq -r '.candidateGateCompletedAt // empty' "$MAIN_CI_PROOF")"
base_main_commit="$(jq -r '.baseMainCommit // empty' "$MAIN_CI_PROOF")"
proof_candidate_commit="$(jq -r '.candidateCommit // empty' "$MAIN_CI_PROOF")"
if [[ -z "$completed_at" || -z "$candidate_gate_completed_at" ||
      ! "$base_main_commit" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "release proof lacks a trusted main/candidate completion timestamp or base commit"
  exit 1
fi
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
ready_epoch="$REQUEST_STARTED_AT"
(( main_ci_epoch > ready_epoch )) && ready_epoch="$main_ci_epoch"
(( candidate_gate_epoch > ready_epoch )) && ready_epoch="$candidate_gate_epoch"

artifact_name="release-request-attestation-$RELEASE_TAG"
work_dir="$(/usr/bin/mktemp -d /private/tmp/sayall-release-attestation.XXXXXX)"
artifact_json="$($GH_BIN api "repos/$REPOSITORY/actions/artifacts?name=$artifact_name&per_page=100")"
artifact_ids=("${(@f)$(print -r -- "$artifact_json" | jq -r '.artifacts[] | select(.expired == false) | .id')}")

expected_json="$(jq -n \
  --arg requestId "$REQUEST_ID" \
  --arg tag "$RELEASE_TAG" \
  --argjson requestStartedAt "$REQUEST_STARTED_AT" \
  --argjson releaseReadyAt "$ready_epoch" \
  --arg candidateCommit "$CANDIDATE_COMMIT" \
  --arg baseMainCommit "$base_main_commit" \
  --arg mainCiCompletedAt "$completed_at" \
  --arg candidateGateCompletedAt "$candidate_gate_completed_at" \
  '{schemaVersion:2,requestId:$requestId,tag:$tag,requestStartedAt:$requestStartedAt,releaseReadyAt:$releaseReadyAt,candidateCommit:$candidateCommit,baseMainCommit:$baseMainCommit,mainCiCompletedAt:$mainCiCompletedAt,candidateGateCompletedAt:$candidateGateCompletedAt}')"

locked_json=""
for artifact_id in "${artifact_ids[@]}"; do
  [[ -n "$artifact_id" ]] || continue
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
  if [[ -n "$locked_json" && "$existing_json" != "$locked_json" ]]; then
    print -u2 "release request attestation artifacts disagree for $RELEASE_TAG"
    exit 1
  fi
  locked_json="$existing_json"
done

if [[ -n "$locked_json" ]]; then
  if ! print -r -- "$locked_json" | jq -e \
    --arg requestId "$REQUEST_ID" \
    --arg tag "$RELEASE_TAG" \
    --argjson requestStartedAt "$REQUEST_STARTED_AT" \
    --arg candidateCommit "$CANDIDATE_COMMIT" \
    --arg baseMainCommit "$base_main_commit" '
      .schemaVersion == 2 and
      .requestId == $requestId and .tag == $tag and
      .requestStartedAt == $requestStartedAt and
      .candidateCommit == $candidateCommit and
      .baseMainCommit == $baseMainCommit and
      (.releaseReadyAt | type) == "number" and
      .releaseReadyAt >= .requestStartedAt and
      (.mainCiCompletedAt | type) == "string" and
      (.candidateGateCompletedAt | type) == "string"
    ' >/dev/null; then
    public_identity_exists=0
    if "$GH_BIN" release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
      public_identity_exists=1
    fi
    if "$GH_BIN" api "repos/$REPOSITORY/git/ref/tags/$RELEASE_TAG" >/dev/null 2>&1; then
      public_identity_exists=1
    fi
    if (( public_identity_exists != 0 )); then
      print -u2 "release request timestamps/identity are immutable for $RELEASE_TAG"
      exit 1
    fi
    print "Replacing a pre-signing-only attestation for $RELEASE_TAG; no public tag or release exists."
    locked_json=""
  fi
  expected_json="$locked_json"
  ready_epoch="$(print -r -- "$locked_json" | jq -r '.releaseReadyAt')"
fi

/bin/mkdir -p "${OUTPUT_FILE:h}"
print -r -- "$expected_json" | jq -S . > "$OUTPUT_FILE"
print "RELEASE REQUEST ATTESTATION PASS"
print "REQUEST_ID: $REQUEST_ID"
print "REQUEST_STARTED_AT: $REQUEST_STARTED_AT"
print "RELEASE_READY_AT: $ready_epoch"
