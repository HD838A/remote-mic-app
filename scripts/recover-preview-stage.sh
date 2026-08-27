#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
RUN_ID="${1:-}"
RUN_ATTEMPT="${2:-}"
ARTIFACT_ID="${3:-}"
ARTIFACT_DIGEST="${4:-}"
EXPECTED_COMMIT="${5:-}"
OUTPUT_DIR="${6:-}"

[[ "$REPOSITORY" == "HD838A/remote-mic-app" ]] || {
  echo "Preview artifact recovery is restricted to HD838A/remote-mic-app" >&2
  exit 1
}

if [[ "$#" -ne 6 || ! "$RUN_ID" =~ ^[1-9][0-9]*$ ||
      ! "$RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ||
      ! "$ARTIFACT_ID" =~ ^[1-9][0-9]*$ ||
      ! "$ARTIFACT_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ||
      ! "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ || -z "$OUTPUT_DIR" ]]; then
  echo "usage: $0 <run-id> <run-attempt> <artifact-id> <sha256:digest> <source-commit> <new-output-directory>" >&2
  exit 2
fi
[[ ! -e "$OUTPUT_DIR" ]] || {
  echo "recovery output already exists: $OUTPUT_DIR" >&2
  exit 1
}
for command_name in "$GH_BIN" jq shasum unzip zipinfo find sort curl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

download_artifact() {
  local artifact_id="$1"
  local destination="$2"
  local token="${GH_TOKEN:-}"
  if [[ -z "$token" ]]; then
    token="$($GH_BIN auth token)"
  fi
  [[ -n "$token" ]] || {
    echo "unable to resolve GitHub token for artifact download" >&2
    exit 1
  }
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/zip' \
    "https://api.github.com/repos/$REPOSITORY/actions/artifacts/$artifact_id/zip" \
    --output "$destination"
}

run_json="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$RUN_ID/attempts/$RUN_ATTEMPT")"
printf '%s\n' "$run_json" | jq -e \
  --arg repository "$REPOSITORY" \
  --arg commit "$EXPECTED_COMMIT" \
  --argjson run "$RUN_ID" \
  --argjson attempt "$RUN_ATTEMPT" '
    .id == $run and
    .repository.full_name == $repository and
    .event == "workflow_dispatch" and
    .path == ".github/workflows/mac-release-package.yml" and
    .head_branch == "main" and .head_sha == $commit and
    .run_attempt == $attempt and
    .status == "completed" and .conclusion == "success"
  ' >/dev/null || {
    echo "source Run is not the exact successful main-based staging Run" >&2
    exit 1
  }

artifact_json="$($GH_BIN api "repos/$REPOSITORY/actions/artifacts/$ARTIFACT_ID")"
artifact_name="$(printf '%s\n' "$artifact_json" | jq -r '.name')"
printf '%s\n' "$artifact_json" | jq -e \
  --arg digest "$ARTIFACT_DIGEST" \
  --arg commit "$EXPECTED_COMMIT" \
  --argjson artifact "$ARTIFACT_ID" \
  --argjson run "$RUN_ID" '
    .id == $artifact and .expired == false and
    .digest == $digest and
    (.name | test("^mac-preview-payload-v[0-9]+[.][0-9]+[.][0-9]+-[0-9a-f]{40}$")) and
    .workflow_run.id == $run and
    .workflow_run.head_branch == "main" and
    .workflow_run.head_sha == $commit
  ' >/dev/null || {
    echo "payload artifact identity does not match the source Run" >&2
    exit 1
  }

/bin/mkdir -p "$OUTPUT_DIR"
archive="$OUTPUT_DIR/payload-artifact.zip"
download_artifact "$ARTIFACT_ID" "$archive"
actual_digest="sha256:$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
[[ "$actual_digest" == "$ARTIFACT_DIGEST" ]] || {
  echo "downloaded payload artifact digest mismatch" >&2
  exit 1
}

entries_file="$OUTPUT_DIR/archive-entries.txt"
unzip -Z1 "$archive" > "$entries_file"
[[ -s "$entries_file" ]] || {
  echo "payload artifact is empty" >&2
  exit 1
}
if /usr/bin/awk '
  /^\// || /(^|\/)\.\.($|\/)/ { bad = 1 }
  { count[$0]++ }
  END { for (entry in count) if (count[entry] > 1) bad = 1; exit bad }
' "$entries_file"; then
  :
else
  echo "payload artifact contains an unsafe or duplicate path" >&2
  exit 1
fi
if ! zipinfo -l "$archive" | /usr/bin/awk '
  length($1) == 10 {
    type = substr($1, 1, 1)
    if (type != "-" && type != "d") bad = 1
  }
  END { exit bad }
'; then
  echo "payload artifact contains a non-regular ZIP entry" >&2
  exit 1
fi

bundle="$OUTPUT_DIR/bundle"
/bin/mkdir -p "$bundle"
unzip -q "$archive" -d "$bundle"
[[ -z "$(/usr/bin/find "$bundle" -type l -print -quit)" ]] || {
  echo "payload artifact contains a symlink" >&2
  exit 1
}
[[ -z "$(/usr/bin/find "$bundle" ! -type f ! -type d -print -quit)" ]] || {
  echo "payload artifact contains a non-regular entry" >&2
  exit 1
}

manifest_candidates=()
while IFS= read -r manifest_path; do
  manifest_candidates+=("$manifest_path")
done < <(/usr/bin/find "$bundle" -name staged-assets.json -type f)
[[ "${#manifest_candidates[@]}" -eq 1 ]] || {
  echo "payload artifact must contain exactly one staged-assets.json" >&2
  exit 1
}
manifest="${manifest_candidates[0]}"
public_dir="$(dirname "$manifest")/public"
[[ -d "$public_dir" ]] || {
  echo "payload artifact is missing the public asset directory" >&2
  exit 1
}
version="$(jq -r '.version' "$manifest")"
expected_artifact_name="mac-preview-payload-v${version}-${EXPECTED_COMMIT}"
[[ "$artifact_name" == "$expected_artifact_name" ]] || {
  echo "payload artifact name does not match the staged manifest and source Commit" >&2
  exit 1
}
"$ROOT/scripts/verify-staged-release-assets.sh" "$manifest" "$public_dir"
jq -e --arg commit "$EXPECTED_COMMIT" '.sourceCommit == $commit' "$manifest" >/dev/null || {
  echo "staged asset manifest source Commit does not match the Run" >&2
  exit 1
}

manifest_sha="$(/usr/bin/shasum -a 256 "$manifest" | /usr/bin/awk '{print $1}')"
version="$(jq -r '.version' "$manifest")"
tag="$(jq -r '.tag' "$manifest")"
stage_artifacts="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$RUN_ID/artifacts?per_page=100")"
stage_record_info="$(printf '%s\n' "$stage_artifacts" | jq -r \
  --arg name "mac-preview-stage-$tag-$EXPECTED_COMMIT" \
  --argjson run "$RUN_ID" --arg commit "$EXPECTED_COMMIT" '
    [.artifacts[] | select(.name == $name) | select(.expired == false) |
      select(.workflow_run.id == ($run // 0) and
             .workflow_run.head_branch == "main" and
             .workflow_run.head_sha == $commit)] |
    if length == 1 then .[0] | [.id,.digest,.name] | @tsv else empty end
  ')"
[[ -n "$stage_record_info" ]] || {
  echo "successful Run has no unique staging record artifact" >&2
  exit 1
}
IFS=$'\t' read -r stage_artifact_id stage_artifact_digest stage_artifact_name <<< "$stage_record_info"
[[ "$stage_artifact_id" =~ ^[1-9][0-9]*$ &&
   "$stage_artifact_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "staging record artifact identity is invalid" >&2
  exit 1
}

stage_archive="$OUTPUT_DIR/stage-record-artifact.zip"
download_artifact "$stage_artifact_id" "$stage_archive"
stage_actual_digest="sha256:$(/usr/bin/shasum -a 256 "$stage_archive" | /usr/bin/awk '{print $1}')"
[[ "$stage_actual_digest" == "$stage_artifact_digest" ]] || {
  echo "downloaded staging record artifact digest mismatch" >&2
  exit 1
}

stage_entries="$OUTPUT_DIR/stage-record-entries.txt"
unzip -Z1 "$stage_archive" > "$stage_entries"
[[ -s "$stage_entries" ]] || {
  echo "staging record artifact is empty" >&2
  exit 1
}
if /usr/bin/awk '
  /^\// || /(^|\/)\.\.($|\/)/ { bad = 1 }
  { count[$0]++ }
  END { for (entry in count) if (count[entry] > 1) bad = 1; exit bad }
' "$stage_entries"; then
  :
else
  echo "staging record artifact contains an unsafe or duplicate path" >&2
  exit 1
fi

stage_bundle="$OUTPUT_DIR/stage-record"
/bin/mkdir -p "$stage_bundle"
unzip -q "$stage_archive" -d "$stage_bundle"
[[ -z "$(/usr/bin/find "$stage_bundle" -type l -print -quit)" ]] || {
  echo "staging record artifact contains a symlink" >&2
  exit 1
}
[[ -z "$(/usr/bin/find "$stage_bundle" ! -type f ! -type d -print -quit)" ]] || {
  echo "staging record artifact contains a non-regular entry" >&2
  exit 1
}
stage_candidates=()
while IFS= read -r stage_path; do
  stage_candidates+=("$stage_path")
done < <(/usr/bin/find "$stage_bundle" -name preview-stage-record.json -type f)
[[ "${#stage_candidates[@]}" -eq 1 ]] || {
  echo "staging record artifact must contain exactly one preview-stage-record.json" >&2
  exit 1
}
stage_record="${stage_candidates[0]}"
jq -e \
  --arg tag "$tag" --arg version "$version" --arg commit "$EXPECTED_COMMIT" \
  --argjson run "$RUN_ID" --argjson attempt "$RUN_ATTEMPT" \
  --argjson artifact "$ARTIFACT_ID" --arg digest "$ARTIFACT_DIGEST" \
  --arg manifest "$manifest_sha" \
  '.schemaVersion == 1 and .mode == "preview" and
   .tag == $tag and .version == $version and .sourceCommit == $commit and
   .sourceRunId == $run and .sourceRunAttempt == $attempt and
   .signedArtifactId == $artifact and .signedArtifactDigest == $digest and
   .assetManifestSHA256 == $manifest and (.stagedAt | fromdateiso8601 > 0)' \
  "$stage_record" >/dev/null || {
  echo "staging record is not bound to the recovered payload" >&2
  exit 1
}

echo "PREVIEW STAGE RECOVERY PASS"
echo "ARTIFACT_NAME: $artifact_name"
echo "MANIFEST: $manifest"
echo "PUBLIC_DIR: $public_dir"
echo "ASSET_MANIFEST_SHA256: $manifest_sha"
echo "STAGE_RECORD_ARTIFACT_NAME: $stage_artifact_name"
echo "STAGE_RECORD: $stage_record"
