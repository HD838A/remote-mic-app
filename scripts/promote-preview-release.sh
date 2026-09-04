#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
TAG="${1:-}"

[[ "$REPOSITORY" == "HD838A/remote-mic-app" ]] || {
  echo "Stable promotion is restricted to HD838A/remote-mic-app" >&2
  exit 1
}

if [[ "$#" -ne 1 || ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <existing-pre-release-tag>" >&2
  exit 2
fi
for command_name in git jq shasum curl unzip zipinfo find "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || {
  echo "Stable promotion requires a clean worktree" >&2
  exit 1
}
git fetch origin main --tags
current_branch="$(git branch --show-current)"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" &&
   ( "$current_branch" == main || ( "${GITHUB_ACTIONS:-}" == true && -z "$current_branch" ) ) ]] || {
  echo "Stable promotion must run from exact origin/main" >&2
  exit 1
}

if [[ "${RELEASE_ALLOW_LOCAL_FIXTURE:-0}" != 1 ]]; then
  current_commit="$(git rev-parse HEAD)"
  [[ "${GITHUB_ACTIONS:-}" == true &&
      "${GITHUB_REPOSITORY:-}" == "$REPOSITORY" &&
      "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
      "${GITHUB_REF_NAME:-}" == main &&
      "${GITHUB_SHA:-}" == "$current_commit" &&
      "${GITHUB_WORKFLOW_REF:-}" == "$REPOSITORY/.github/workflows/mac-stable-promote.yml@"* ]] || {
    echo "Stable promotion is restricted to the reviewed main workflow" >&2
    exit 1
  }
fi

release_json="$($GH_BIN release view "$TAG" --repo "$REPOSITORY" --json isDraft,isPrerelease,tagName,assets)"
printf '%s\n' "$release_json" | jq -e --arg tag "$TAG" '.tagName == $tag and .isDraft == false' >/dev/null || {
  echo "$TAG is not an existing public Release" >&2
  exit 1
}

is_prerelease="$(printf '%s\n' "$release_json" | jq -r '.isPrerelease')"
stable_release_before="$($GH_BIN api "repos/$REPOSITORY/releases/latest")" || {
  echo "unable to resolve the current stable latest Release" >&2
  exit 1
}
latest_tag="$(printf '%s\n' "$stable_release_before" | jq -r '.tag_name')"
printf '%s\n' "$stable_release_before" | jq -e \
  --arg tag "$latest_tag" \
  '.tag_name == $tag and ($tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and .draft == false and .prerelease == false' >/dev/null || {
  echo "releases/latest is not a formal stable Release: $latest_tag" >&2
  exit 1
}
case "$is_prerelease" in
  true)
    needs_promotion=1
    ;;
  false)
    [[ "$latest_tag" == "$TAG" ]] || {
      echo "$TAG is already Stable but is not releases/latest; refusing to change another Stable release" >&2
      exit 1
    }
    needs_promotion=0
    ;;
  *)
    echo "$TAG has an invalid Release classification" >&2
    exit 1
    ;;
esac

work_dir="$(/usr/bin/mktemp -d /private/tmp/sayall-stable-promotion.XXXXXX)"
$GH_BIN release download "$TAG" --repo "$REPOSITORY" \
  --pattern candidate-provenance.json --dir "$work_dir"
provenance="$work_dir/candidate-provenance.json"
jq -e \
  --arg repository "$REPOSITORY" --arg tag "$TAG" '
    .schemaVersion == 5 and .repository == $repository and .tag == $tag and
    .tagCommit == .sourceCommit and
    (.sourceBranch == "main" or (.sourceBranch | test("^hotfix/v[0-9]+[.][0-9]+[.][0-9]+$"))) and
    (.sourceKind == "main" or .sourceKind == "hotfix") and
    (.sourceCommit | test("^[0-9a-f]{40}$")) and
    (.sourceWorkflowCommit | test("^[0-9a-f]{40}$")) and
    ((.sourceKind == "main" and .sourceBranch == "main" and .sourceBaseTag == "" and .sourceBaseCommit == "") or
     (.sourceKind == "hotfix" and .sourceBranch == ("hotfix/" + .tag) and
      (.sourceBaseTag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
      (.sourceBaseCommit | test("^[0-9a-f]{40}$")))) and
    (.version | test("^[0-9]+[.][0-9]+[.][0-9]+$")) and
    .tag == ("v" + .version) and
    (.build | test("^[1-9][0-9]*$")) and
    (.sourceRunId | type == "number" and . > 0 and floor == .) and
    (.sourceRunAttempt | type == "number" and . > 0 and floor == .) and
    (.signedArtifactId | type == "number" and . > 0 and floor == .) and
    (.signedArtifactDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.stagedAt | fromdateiso8601 > 0) and
    .publishedAt == .stagedAt and
    (.assetManifestSHA256 | test("^[0-9a-f]{64}$")) and
    (.uiAttestationSHA256 | test("^[0-9a-f]{64}$")) and
    (.payloadAssets | type == "array" and length == 11) and
    ([.payloadAssets[].name] | length == (unique | length)) and
    all(.payloadAssets[];
      (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      (.size | type == "number" and . >= 0 and floor == .) and
      (.sha256 | test("^[0-9a-f]{64}$"))) and
    ([
      "Remote-Mic-" + .version + "-Intel-Uninstaller.pkg",
      "Remote-Mic-" + .version + "-Intel.dmg",
      "Remote-Mic-" + .version + "-Intel.zip",
      "Remote-Mic-" + .version + "-Uninstaller.pkg",
      "Remote-Mic-" + .version + ".dmg",
      "Remote-Mic-" + .version + ".dmg.sha256",
      "Remote-Mic-" + .version + ".en.txt",
      "Remote-Mic-" + .version + ".zh.txt",
      "Remote-Mic-" + .version + ".zip",
      "appcast-intel.xml",
      "appcast.xml"
    ] | sort) == ([.payloadAssets[].name] | sort)
  ' "$provenance" >/dev/null || {
  echo "Candidate provenance is invalid" >&2
  exit 1
}

source_commit="$(jq -r '.sourceCommit' "$provenance")"
source_branch="$(jq -r '.sourceBranch' "$provenance")"
source_kind="$(jq -r '.sourceKind' "$provenance")"
source_base_tag="$(jq -r '.sourceBaseTag' "$provenance")"
source_base_commit="$(jq -r '.sourceBaseCommit' "$provenance")"
source_workflow_commit="$(jq -r '.sourceWorkflowCommit' "$provenance")"
source_run_id="$(jq -r '.sourceRunId' "$provenance")"
source_run_attempt="$(jq -r '.sourceRunAttempt' "$provenance")"
signed_artifact_id="$(jq -r '.signedArtifactId' "$provenance")"
signed_artifact_digest="$(jq -r '.signedArtifactDigest' "$provenance")"
run_json=""
if run_json="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$source_run_id/attempts/$source_run_attempt" 2>/dev/null)"; then
  :
else
  run_status=$?
  echo "unable to verify the protected staging Run identity (gh exit $run_status)" >&2
  exit 1
fi
printf '%s\n' "$run_json" | jq -e \
  --arg repository "$REPOSITORY" --arg workflowCommit "$source_workflow_commit" \
  --argjson run "$source_run_id" --argjson attempt "$source_run_attempt" \
  '.id == $run and .repository.full_name == $repository and
   .event == "workflow_dispatch" and
   .path == ".github/workflows/mac-release-package.yml" and
   .head_branch == "main" and .head_sha == $workflowCommit and
   .run_attempt == $attempt and .status == "completed" and
   .conclusion == "success"' >/dev/null || {
  echo "candidate provenance is not bound to a successful main-controlled staging Run" >&2
  exit 1
}

artifact_json=""
if artifact_json="$($GH_BIN api "repos/$REPOSITORY/actions/artifacts/$signed_artifact_id" 2>/dev/null)"; then
  :
else
  artifact_status=$?
  echo "unable to verify the protected staging artifact identity (gh exit $artifact_status)" >&2
  exit 1
fi
printf '%s\n' "$artifact_json" | jq -e \
  --arg repository "$REPOSITORY" --arg workflowCommit "$source_workflow_commit" \
  --arg commit "$source_commit" \
  --arg version "$(jq -r '.version' "$provenance")" \
  --arg digest "$signed_artifact_digest" --argjson artifact "$signed_artifact_id" \
  --argjson run "$source_run_id" \
  '.id == $artifact and .expired == false and .digest == $digest and
   (.name == ("mac-preview-payload-v" + $version + "-" + $commit)) and
   .workflow_run.id == $run and
   .workflow_run.head_branch == "main" and
   .workflow_run.head_sha == $workflowCommit' >/dev/null || {
  echo "candidate provenance is not bound to the exact protected staging artifact" >&2
  exit 1
}

version="$(jq -r '.version' "$provenance")"
manifest_sha="$(jq -r '.assetManifestSHA256' "$provenance")"
staged_at="$(jq -r '.stagedAt' "$provenance")"
stage_artifacts=""
if stage_artifacts="$($GH_BIN api "repos/$REPOSITORY/actions/runs/$source_run_id/artifacts?per_page=100" 2>/dev/null)"; then
  :
else
  stage_artifacts_status=$?
  echo "unable to verify the protected staging record artifact (gh exit $stage_artifacts_status)" >&2
  exit 1
fi
stage_record_info="$(printf '%s\n' "$stage_artifacts" | jq -r \
  --arg name "mac-preview-stage-v$version-$source_commit" \
  --argjson run "$source_run_id" --arg workflowCommit "$source_workflow_commit" '
    [.artifacts[] | select(.name == $name and .expired == false) |
      select(.workflow_run.id == $run and
             .workflow_run.head_branch == "main" and
             .workflow_run.head_sha == $workflowCommit)] |
    if length == 1 then .[0] | [.id, (.digest // ""), .name] | @tsv else empty end
  ')"
[[ -n "$stage_record_info" ]] || {
  echo "successful staging Run has no unique unexpired staging record artifact" >&2
  exit 1
}
IFS=$'\t' read -r stage_record_artifact_id stage_record_artifact_digest stage_record_artifact_name <<< "$stage_record_info"
[[ "$stage_record_artifact_id" =~ ^[1-9][0-9]*$ &&
   "$stage_record_artifact_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "staging record artifact identity is invalid" >&2
  exit 1
}
stage_record_archive="$work_dir/stage-record-artifact.zip"
api_base="https://api.github.com"
if ! /usr/bin/curl --fail --silent --show-error --location \
  -H "Authorization: Bearer ${GH_TOKEN:?GH_TOKEN is required to download the staging record artifact}" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$api_base/repos/$REPOSITORY/actions/artifacts/$stage_record_artifact_id/zip" \
  --output "$stage_record_archive"; then
  echo "unable to download the protected staging record artifact" >&2
  exit 1
fi
stage_record_actual_digest="sha256:$(/usr/bin/shasum -a 256 "$stage_record_archive" | /usr/bin/awk '{print $1}')"
[[ "$stage_record_actual_digest" == "$stage_record_artifact_digest" ]] || {
  echo "staging record artifact digest mismatch" >&2
  exit 1
}
stage_record_entries="$work_dir/stage-record-entries.txt"
unzip -Z1 "$stage_record_archive" > "$stage_record_entries"
[[ -s "$stage_record_entries" ]] || {
  echo "staging record artifact is empty" >&2
  exit 1
}
if /usr/bin/awk '
  /^\// || /(^|\/)\.\.($|\/)/ { bad = 1 }
  { count[$0]++ }
  END { for (entry in count) if (count[entry] > 1) bad = 1; exit bad }
' "$stage_record_entries"; then
  :
else
  echo "staging record artifact contains an unsafe or duplicate path" >&2
  exit 1
fi
if ! zipinfo -l "$stage_record_archive" | /usr/bin/awk '
  length($1) == 10 {
    type = substr($1, 1, 1)
    if (type != "-" && type != "d") bad = 1
  }
  END { exit bad }
'; then
  echo "staging record artifact contains a non-regular ZIP entry" >&2
  exit 1
fi
stage_record_root="$work_dir/stage-record"
/bin/mkdir -p "$stage_record_root"
unzip -q "$stage_record_archive" -d "$stage_record_root"
[[ -z "$(/usr/bin/find "$stage_record_root" -type l -print -quit)" ]] || {
  echo "staging record artifact contains a symlink" >&2
  exit 1
}
stage_record_candidates=()
while IFS= read -r stage_record_path; do
  stage_record_candidates+=("$stage_record_path")
done < <(/usr/bin/find "$stage_record_root" -name preview-stage-record.json -type f -print)
[[ "${#stage_record_candidates[@]}" -eq 1 ]] || {
  echo "staging record artifact must contain exactly one preview-stage-record.json" >&2
  exit 1
}
stage_record="${stage_record_candidates[0]}"
jq -e \
  --arg tag "$TAG" --arg version "$version" --arg commit "$source_commit" \
  --arg sourceBranch "$source_branch" --arg sourceKind "$source_kind" \
  --arg sourceBaseTag "$source_base_tag" --arg sourceBaseCommit "$source_base_commit" \
  --arg workflowCommit "$source_workflow_commit" \
  --argjson run "$source_run_id" --argjson attempt "$source_run_attempt" \
  --argjson artifact "$signed_artifact_id" --arg digest "$signed_artifact_digest" \
  --arg manifest "$manifest_sha" --arg stagedAt "$staged_at" \
  '.schemaVersion == 2 and .mode == "preview" and
   .sourceBranch == $sourceBranch and .sourceKind == $sourceKind and
   .sourceBaseTag == $sourceBaseTag and .sourceBaseCommit == $sourceBaseCommit and
   .tag == $tag and .version == $version and .sourceCommit == $commit and
   .sourceWorkflowCommit == $workflowCommit and
   .sourceRunId == $run and .sourceRunAttempt == $attempt and
   .signedArtifactId == $artifact and .signedArtifactDigest == $digest and
   .assetManifestSHA256 == $manifest and .stagedAt == $stagedAt' \
  "$stage_record" >/dev/null || {
  echo "candidate provenance is not bound to the exact Preview staging record" >&2
  exit 1
}

RELEASE_SOURCE_CHECKOUT_MODE=none \
RELEASE_SOURCE_REMOTE_MODE=published \
RELEASE_SOURCE_EXPECTED_BASE_TAG="$source_base_tag" \
RELEASE_SOURCE_EXPECTED_BASE_COMMIT="$source_base_commit" \
RELEASE_SOURCE_REQUIRE_CURRENT_STABLE_BASE="$needs_promotion" \
GITHUB_REPOSITORY="$REPOSITORY" GH_BIN="$GH_BIN" \
  "$ROOT/scripts/verify-public-release-source.sh" \
  "$source_branch" "$source_commit" "$version" >/dev/null

remote_tag_refs="$(git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}")" || {
  echo "unable to verify the remote Tag $TAG" >&2
  exit 1
}
tag_commit="$(printf '%s\n' "$remote_tag_refs" | /usr/bin/awk '$2 ~ /\^\{\}$/ {print $1; found=1; exit} $2 !~ /\^\{\}$/ {fallback=$1} END {if (!found && fallback != "") print fallback}')"
[[ -n "$tag_commit" ]] || {
  echo "remote Tag $TAG was not found" >&2
  exit 1
}
[[ "$tag_commit" == "$source_commit" ]] || {
  echo "Tag Commit does not match candidate provenance" >&2
  exit 1
}
remote_assets="$(printf '%s\n' "$release_json" | jq -r '.assets[] | [.name, (.size | tostring), (.digest // "")] | @tsv')"
[[ "$(printf '%s\n' "$remote_assets" | /usr/bin/awk 'NF {count++} END {print count+0}')" -eq 12 ]] || {
  echo "Pre-release asset set changed" >&2
  exit 1
}
while IFS=$'\t' read -r name expected_size expected_sha; do
  remote_record="$(printf '%s\n' "$remote_assets" | /usr/bin/awk -F '\t' -v name="$name" '$1 == name {print; exit}')"
  [[ -n "$remote_record" ]] || {
    echo "Pre-release is missing payload asset: $name" >&2
    exit 1
  }
  IFS=$'\t' read -r _ remote_size remote_digest <<< "$remote_record"
  [[ "$remote_size" == "$expected_size" && "$remote_digest" == "sha256:$expected_sha" ]] || {
    echo "Pre-release payload digest changed: $name" >&2
    exit 1
  }
done < <(jq -r '.payloadAssets[] | [.name, (.size | tostring), .sha256] | @tsv' "$provenance")

provenance_record="$(printf '%s\n' "$remote_assets" | /usr/bin/awk -F '\t' '$1 == "candidate-provenance.json" {print; exit}')"
[[ -n "$provenance_record" ]] || {
  echo "Pre-release is missing candidate-provenance.json" >&2
  exit 1
}
IFS=$'\t' read -r _ provenance_size provenance_digest <<< "$provenance_record"
local_size="$(if [[ "$(uname -s)" == Darwin ]]; then /usr/bin/stat -f '%z' "$provenance"; else /usr/bin/stat -c '%s' "$provenance"; fi)"
local_sha="$(/usr/bin/shasum -a 256 "$provenance" | /usr/bin/awk '{print $1}')"
[[ "$provenance_size" == "$local_size" && "$provenance_digest" == "sha256:$local_sha" ]] || {
  echo "Candidate provenance digest changed" >&2
  exit 1
}

# Promotion mutates classification only. It never builds, signs, notarizes,
# uploads, replaces, or removes an asset. A completed promotion is safe to
# re-run as a read-only verification when the Release is already Stable and
# releases/latest already points at the selected Tag.
if (( needs_promotion )); then
  current_stable_release="$($GH_BIN api "repos/$REPOSITORY/releases/latest")" || {
    echo "unable to verify stable latest before promotion" >&2
    exit 1
  }
  current_latest="$(printf '%s\n' "$current_stable_release" | jq -r '.tag_name')"
  [[ "$current_latest" == "$latest_tag" ]] || {
    echo "Stable latest changed before promotion: expected $latest_tag, found $current_latest" >&2
    exit 1
  }
  $GH_BIN release edit "$TAG" --repo "$REPOSITORY" --draft=false --prerelease=false --latest
fi

after="$($GH_BIN release view "$TAG" --repo "$REPOSITORY" --json isDraft,isPrerelease,assets)"
printf '%s\n' "$after" | jq -e '.isDraft == false and .isPrerelease == false' >/dev/null || {
  echo "Stable promotion verification found an unexpected Release classification" >&2
  exit 1
}
[[ "$($GH_BIN api "repos/$REPOSITORY/releases/latest" --jq '.tag_name')" == "$TAG" ]] || {
  echo "Stable promotion verification found a different releases/latest Tag" >&2
  exit 1
}
after_assets="$(printf '%s\n' "$after" | jq -S -c '.assets | map({name,size,digest}) | sort_by(.name)')"
before_assets="$(printf '%s\n' "$release_json" | jq -S -c '.assets | map({name,size,digest}) | sort_by(.name)')"
[[ "$after_assets" == "$before_assets" ]] || {
  echo "Stable promotion changed the asset set" >&2
  exit 1
}

for appcast in appcast.xml appcast-intel.xml; do
  /usr/bin/curl --fail --silent --show-error --location \
    "https://github.com/$REPOSITORY/releases/download/$TAG/$appcast" \
    --output "$work_dir/fixed-$appcast"
  /usr/bin/curl --fail --silent --show-error --location \
    "https://github.com/$REPOSITORY/releases/latest/download/$appcast" \
    --output "$work_dir/latest-$appcast"
  /usr/bin/cmp -s "$work_dir/fixed-$appcast" "$work_dir/latest-$appcast" || {
    echo "Latest stable appcast differs from the promoted candidate: $appcast" >&2
    exit 1
  }
  channel_matches=0
  for attempt in {1..20}; do
    if /usr/bin/curl --fail --silent --show-error --location \
        "https://download.sayall.app/mac/channels/stable/$appcast" \
        --output "$work_dir/stable-channel-$appcast" && \
       /usr/bin/cmp -s "$work_dir/fixed-$appcast" "$work_dir/stable-channel-$appcast"; then
      channel_matches=1
      break
    fi
    (( attempt < 20 )) && /bin/sleep 6
  done
  [[ "$channel_matches" -eq 1 ]] || {
    echo "Cloudflare stable channel differs from the promoted candidate: $appcast" >&2
    exit 1
  }
done

echo "STABLE PROMOTION PASS"
echo "TAG: $TAG"
echo "SOURCE_COMMIT: $source_commit"
