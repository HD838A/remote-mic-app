#!/bin/zsh
set -euo pipefail
umask 077

REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
REQUEST_ID="${1:-}"
RELEASE_TAG="${2:-}"
REQUEST_STARTED_AT="${3:-}"
OUTPUT_FILE="${4:-}"

if [[ "$#" -ne 4 ]]; then
  print -u2 "usage: $0 <request-id> <tag> <request-started-epoch> <output.json>"
  exit 2
fi
if [[ ! "$REQUEST_ID" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$' ||
      ! "$RELEASE_TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
      ! "$REQUEST_STARTED_AT" =~ '^[0-9]+$' ]]; then
  print -u2 "invalid stable request attestation input"
  exit 2
fi

artifact_name="stable-request-attestation-$RELEASE_TAG"
work_dir="$(/usr/bin/mktemp -d /private/tmp/sayall-stable-attestation.XXXXXX)"
release_json="$($GH_BIN api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG")" || {
  print -u2 "requested stable promotion source release does not exist: $RELEASE_TAG"
  exit 1
}
if ! print -r -- "$release_json" | jq -e \
    --arg tag "$RELEASE_TAG" \
    '.tag_name == $tag and .draft == false and .prerelease == true' \
    >/dev/null; then
  print -u2 "stable promotion source must be an existing published pre-release: $RELEASE_TAG"
  exit 1
fi
artifact_json="$($GH_BIN api "repos/$REPOSITORY/actions/artifacts?name=$artifact_name&per_page=100")"
artifact_ids=("${(@f)$(print -r -- "$artifact_json" | jq -r '.artifacts[] | select(.expired == false) | .id')}")
release_ready_at="$(/bin/date +%s)"
expected_json="$(jq -n \
  --arg requestId "$REQUEST_ID" \
  --arg tag "$RELEASE_TAG" \
  --argjson requestStartedAt "$REQUEST_STARTED_AT" \
  --argjson releaseReadyAt "$release_ready_at" \
  '{schemaVersion:2,mode:"stable",requestId:$requestId,tag:$tag,requestStartedAt:$requestStartedAt,releaseReadyAt:$releaseReadyAt}')"

locked_json=""
for artifact_id in "${artifact_ids[@]}"; do
  [[ -n "$artifact_id" ]] || continue
  zip_path="$work_dir/$artifact_id.zip"
  extract_dir="$work_dir/$artifact_id"
  "$GH_BIN" api "repos/$REPOSITORY/actions/artifacts/$artifact_id/zip" > "$zip_path"
  /bin/mkdir -p "$extract_dir"
  /usr/bin/unzip -q "$zip_path" -d "$extract_dir"
  existing_file="$extract_dir/stable-request-attestation.json"
  [[ -r "$existing_file" ]] || { print -u2 "existing stable attestation artifact is malformed"; exit 1; }
  existing_json="$(jq -S '
    if .schemaVersion == 1 and (.releaseReadyAt | not) then
      .schemaVersion = 2 | .releaseReadyAt = .requestStartedAt
    else
      .
    end
  ' "$existing_file")" || {
    print -u2 "existing stable attestation artifact is malformed"
    exit 1
  }
  if [[ -n "$locked_json" && "$existing_json" != "$locked_json" ]]; then
    print -u2 "stable request attestation artifacts disagree for $RELEASE_TAG"
    exit 1
  fi
  locked_json="$existing_json"
done

if [[ -n "$locked_json" ]]; then
  if ! print -r -- "$locked_json" | jq -e \
      --arg requestId "$REQUEST_ID" \
      --arg tag "$RELEASE_TAG" \
      --argjson requestStartedAt "$REQUEST_STARTED_AT" \
      '.schemaVersion == 2 and .mode == "stable" and .requestId == $requestId and
       .tag == $tag and .requestStartedAt == $requestStartedAt and
       (.releaseReadyAt | type == "number") and .releaseReadyAt >= .requestStartedAt' \
      >/dev/null; then
    print -u2 "stable request timestamp/identity is immutable for $RELEASE_TAG"
    exit 1
  fi
  expected_json="$locked_json"
fi

/bin/mkdir -p "${OUTPUT_FILE:h}"
print -r -- "$expected_json" | jq -S . > "$OUTPUT_FILE"
print "STABLE REQUEST ATTESTATION PASS"
print "REQUEST_ID: $REQUEST_ID"
print "REQUEST_STARTED_AT: $REQUEST_STARTED_AT"
print "RELEASE_READY_AT: $(jq -r '.releaseReadyAt' "$OUTPUT_FILE")"
