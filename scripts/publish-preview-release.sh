#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
ATTESTATION="${1:-}"

[[ "$REPOSITORY" == "HD838A/remote-mic-app" ]] || {
  echo "Preview publication is restricted to HD838A/remote-mic-app" >&2
  exit 1
}
CDN_PROBE_BIN="$ROOT/scripts/verify-preview-cdn-availability.sh"
[[ -x "$CDN_PROBE_BIN" ]] || {
  echo "Missing executable CDN occupancy checker: $CDN_PROBE_BIN" >&2
  exit 1
}

if [[ "$#" -ne 1 || ! -r "$ATTESTATION" ]]; then
  echo "usage: $0 <preview-ui-attestation.json>" >&2
  exit 2
fi
for command_name in git jq shasum curl "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

if [[ "${RELEASE_ALLOW_LOCAL_FIXTURE:-0}" != 1 ]]; then
  current_commit="$(git -C "$ROOT" rev-parse HEAD)"
  [[ "${GITHUB_ACTIONS:-}" == true &&
      "${GITHUB_REPOSITORY:-}" == "$REPOSITORY" &&
      "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
      "${GITHUB_REF_NAME:-}" == main &&
      "${GITHUB_SHA:-}" == "$current_commit" &&
      "${GITHUB_WORKFLOW_REF:-}" == "$REPOSITORY/.github/workflows/mac-preview-publication.yml@"* ]] || {
    echo "Preview publication is restricted to the reviewed main workflow" >&2
    exit 1
  }
fi

jq -e '
  .schemaVersion == 3 and .result == "passed" and .mode == "preview" and
  (.tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
  (.sourceCommit | test("^[0-9a-f]{40}$")) and
  (.sourceRunId | type == "number" and . > 0) and
  (.sourceRunAttempt | type == "number" and . > 0) and
  (.signedArtifactId | type == "number" and . > 0) and
  (.signedArtifactDigest | test("^sha256:[0-9a-f]{64}$")) and
  (.assetManifestSHA256 | test("^[0-9a-f]{64}$")) and
  (.stagedAt | fromdateiso8601 > 0) and
  (.target.version | test("^[0-9]+[.][0-9]+[.][0-9]+$")) and
  .tag == ("v" + .target.version) and
  (.target.build | test("^[1-9][0-9]*$"))
' "$ATTESTATION" >/dev/null || {
  echo "Preview UI attestation is invalid" >&2
  exit 1
}

tag="$(jq -r '.tag' "$ATTESTATION")"
source_commit="$(jq -r '.sourceCommit' "$ATTESTATION")"
run_id="$(jq -r '.sourceRunId' "$ATTESTATION")"
run_attempt="$(jq -r '.sourceRunAttempt' "$ATTESTATION")"
artifact_id="$(jq -r '.signedArtifactId' "$ATTESTATION")"
artifact_digest="$(jq -r '.signedArtifactDigest' "$ATTESTATION")"
expected_manifest_sha="$(jq -r '.assetManifestSHA256' "$ATTESTATION")"
staged_at="$(jq -r '.stagedAt' "$ATTESTATION")"
version="${tag#v}"

git -C "$ROOT" fetch --no-tags origin main
git -C "$ROOT" merge-base --is-ancestor "$source_commit" "origin/main" || {
  echo "staged source commit is not contained in current origin/main" >&2
  exit 1
}

stable_release_before="$($GH_BIN api "repos/$REPOSITORY/releases/latest")" || {
  echo "unable to resolve the current stable latest Release" >&2
  exit 1
}
stable_latest_before="$(printf '%s\n' "$stable_release_before" | jq -r '.tag_name')"
printf '%s\n' "$stable_release_before" | jq -e \
  --arg tag "$stable_latest_before" \
  '.tag_name == $tag and ($tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and .draft == false and .prerelease == false' >/dev/null || {
  echo "releases/latest is not a formal stable Release: $stable_latest_before" >&2
  exit 1
}

work_dir="$(/usr/bin/mktemp -d /private/tmp/sayall-preview-publication.XXXXXX)"
recovered="$work_dir/recovered"
"$ROOT/scripts/recover-preview-stage.sh" \
  "$run_id" "$run_attempt" "$artifact_id" "$artifact_digest" \
  "$source_commit" "$recovered" > "$work_dir/recovery.txt"
manifest="$recovered/bundle/staged-assets.json"
public_dir="$recovered/bundle/public"
[[ -r "$manifest" && -d "$public_dir" ]] || {
  echo "Recovered stage has an unexpected layout" >&2
  exit 1
}
manifest_sha="$(/usr/bin/shasum -a 256 "$manifest" | /usr/bin/awk '{print $1}')"
[[ "$manifest_sha" == "$expected_manifest_sha" ]] || {
  echo "UI attestation is bound to a different staged asset manifest" >&2
  exit 1
  }

stage_record="$recovered/stage-record/preview-stage-record.json"
[[ -r "$stage_record" ]] || {
  echo "Recovered stage is missing its authenticated staging record" >&2
  exit 1
}
"$ROOT/scripts/verify-preview-ui-attestation.sh" "$ATTESTATION" "$stage_record" "$public_dir" >/dev/null || {
  echo "Preview UI attestation failed final publication verification" >&2
  exit 1
}
jq -e \
  --arg tag "$tag" --arg commit "$source_commit" --arg version "$version" \
  --arg build "$(jq -r '.target.build' "$ATTESTATION")" '
    .tag == $tag and .sourceCommit == $commit and
    .version == $version and .build == $build
  ' "$manifest" >/dev/null || {
  echo "Recovered manifest does not match the UI-tested target" >&2
  exit 1
}

provenance="$work_dir/candidate-provenance.json"
jq -S \
  --arg repository "$REPOSITORY" \
  --arg tag "$tag" \
  --arg sourceCommit "$source_commit" \
  --argjson sourceRunId "$run_id" \
  --argjson sourceRunAttempt "$run_attempt" \
  --argjson signedArtifactId "$artifact_id" \
  --arg signedArtifactDigest "$artifact_digest" \
  --arg assetManifestSHA256 "$manifest_sha" \
  --arg uiAttestationSHA256 "$(/usr/bin/shasum -a 256 "$ATTESTATION" | /usr/bin/awk '{print $1}')" \
  --arg stagedAt "$staged_at" \
  --slurpfile manifest "$manifest" '
    {
      schemaVersion:4,
      repository:$repository,
      tag:$tag,
      tagCommit:$sourceCommit,
      sourceCommit:$sourceCommit,
      version:$manifest[0].version,
      build:$manifest[0].build,
      sourceRunId:$sourceRunId,
      sourceRunAttempt:$sourceRunAttempt,
      signedArtifactId:$signedArtifactId,
      signedArtifactDigest:$signedArtifactDigest,
      assetManifestSHA256:$assetManifestSHA256,
      uiAttestationSHA256:$uiAttestationSHA256,
      stagedAt:$stagedAt,
      publishedAt:$stagedAt,
      payloadAssets:$manifest[0].assets
    }
  ' "$manifest" > "$provenance"

release_preflight_response=""
if release_preflight_response="$($GH_BIN api --include "repos/$REPOSITORY/releases/tags/$tag" 2>/dev/null)"; then
  release_preflight_state=exists
else
  release_preflight_status=$?
  release_preflight_http_code="$(printf '%s\n' "$release_preflight_response" | /usr/bin/awk '$1 ~ /^HTTP\/[0-9.]+$/ {code=$2} END {print code}')"
  if [[ "$release_preflight_http_code" != 404 ]]; then
    if [[ -n "$release_preflight_http_code" ]]; then
      echo "unable to check GitHub Release $tag (HTTP $release_preflight_http_code, gh exit $release_preflight_status)" >&2
    else
      echo "unable to check GitHub Release $tag (no HTTP response, gh exit $release_preflight_status)" >&2
    fi
    exit 1
  fi
  release_preflight_state=missing
fi

remote_tag_refs="$(git -C "$ROOT" ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")" || {
  echo "unable to check remote Tag $tag" >&2
  exit 1
}
remote_tag_commit="$(printf '%s\n' "$remote_tag_refs" | /usr/bin/awk '$2 ~ /\^\{\}$/ {print $1; found=1; exit} $2 !~ /\^\{\}$/ {fallback=$1} END {if (!found && fallback != "") print fallback}')"
if [[ "$release_preflight_state" == exists && -z "$remote_tag_commit" ]]; then
  echo "GitHub Release $tag exists but its remote Tag is missing" >&2
  exit 1
fi
if [[ -z "$remote_tag_commit" ]]; then
  cdn_status=0
  "$CDN_PROBE_BIN" "$tag" >/dev/null || cdn_status=$?
  case "$cdn_status" in
    0)
      ;;
    42)
      echo "CDN fixed paths are already occupied for $tag; refusing to create a new public identity" >&2
      exit 1
      ;;
    *)
      echo "unable to establish CDN availability before creating $tag" >&2
      exit 1
      ;;
  esac
  $GH_BIN api --method POST "repos/$REPOSITORY/git/refs" \
    -f "ref=refs/tags/$tag" -f "sha=$source_commit" >/dev/null
  remote_tag_refs="$(git -C "$ROOT" ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")" || {
    echo "unable to verify newly created remote Tag $tag" >&2
    exit 1
  }
  remote_tag_commit="$(printf '%s\n' "$remote_tag_refs" | /usr/bin/awk '$2 ~ /\^\{\}$/ {print $1; found=1; exit} $2 !~ /\^\{\}$/ {fallback=$1} END {if (!found && fallback != "") print fallback}')"
fi
[[ "$remote_tag_commit" == "$source_commit" ]] || {
  echo "$tag points to a different Commit" >&2
  exit 1
}

release_exists=0
release_json=""
if release_json="$($GH_BIN release view "$tag" --repo "$REPOSITORY" --json databaseId,isDraft,isPrerelease,tagName,name,body,assets 2>/dev/null)"; then
  release_exists=1
  printf '%s\n' "$release_json" | jq -e \
    --arg tag "$tag" '.tagName == $tag and (.isDraft == true or .isPrerelease == true)' >/dev/null || {
    echo "Existing Release is neither a resumable Draft nor a Pre-release" >&2
    exit 1
  }
else
  release_view_status=$?
  if [[ "$release_preflight_state" == exists ]]; then
    echo "GitHub Release $tag was found by API but could not be read by gh release view (exit $release_view_status)" >&2
    exit 1
  fi
  release_probe_response=""
  if release_probe_response="$($GH_BIN api --include "repos/$REPOSITORY/releases/tags/$tag" 2>/dev/null)"; then
    echo "Release lookup returned inconsistent results for $tag" >&2
    exit 1
  else
    release_probe_status=$?
  fi
  release_http_code="$(printf '%s\n' "$release_probe_response" | /usr/bin/awk '$1 ~ /^HTTP\/[0-9.]+$/ {code=$2} END {print code}')"
  if [[ "$release_http_code" != 404 ]]; then
    if [[ -n "$release_http_code" ]]; then
      echo "unable to check GitHub Release $tag (HTTP $release_http_code, gh exit $release_probe_status; release view exit $release_view_status)" >&2
    else
      echo "unable to check GitHub Release $tag (no HTTP response, gh exit $release_probe_status; release view exit $release_view_status)" >&2
    fi
    exit 1
  fi
  $GH_BIN release create "$tag" --repo "$REPOSITORY" --verify-tag \
    --prerelease --latest=false \
    --title "无线麦SayAll.app $version" \
    --notes-file "$recovered/bundle/release-notes.md"
  release_exists=1
fi

expected_assets="$work_dir/expected-assets.tsv"
jq -r '.assets[] | [.name, (.size | tostring), .sha256] | @tsv' "$manifest" > "$expected_assets"
provenance_size="$(if [[ "$(uname -s)" == Darwin ]]; then /usr/bin/stat -f '%z' "$provenance"; else /usr/bin/stat -c '%s' "$provenance"; fi)"
provenance_sha="$(/usr/bin/shasum -a 256 "$provenance" | /usr/bin/awk '{print $1}')"
printf 'candidate-provenance.json\t%s\t%s\n' "$provenance_size" "$provenance_sha" >> "$expected_assets"

release_json="$($GH_BIN release view "$tag" --repo "$REPOSITORY" --json databaseId,isDraft,isPrerelease,tagName,name,body,assets)"
remote_assets="$(printf '%s\n' "$release_json" | jq -r '.assets[] | [.name, (.size | tostring), (.digest // "")] | @tsv')"
while IFS=$'\t' read -r remote_name _ _; do
  [[ -n "$remote_name" ]] || continue
  /usr/bin/awk -F '\t' -v name="$remote_name" '$1 == name {found=1} END {exit !found}' "$expected_assets" || {
    echo "Existing Release contains an unexpected asset: $remote_name" >&2
    exit 1
  }
done <<< "$remote_assets"

while IFS=$'\t' read -r name expected_size expected_sha; do
  [[ -n "$name" ]] || continue
  remote_record="$(printf '%s\n' "$remote_assets" | /usr/bin/awk -F '\t' -v name="$name" '$1 == name {print; exit}')"
  if [[ -n "$remote_record" ]]; then
    IFS=$'\t' read -r _ remote_size remote_digest <<< "$remote_record"
    [[ "$remote_size" == "$expected_size" && "$remote_digest" == "sha256:$expected_sha" ]] || {
      echo "Existing Release asset differs from the staged bytes: $name" >&2
      exit 1
    }
    continue
  fi
  source_file="$public_dir/$name"
  [[ "$name" == candidate-provenance.json ]] && source_file="$provenance"
  $GH_BIN release upload "$tag" "$source_file" --repo "$REPOSITORY"
done < "$expected_assets"

release_name="$(printf '%s\n' "$release_json" | jq -r '.name // ""')"
release_is_draft="$(printf '%s\n' "$release_json" | jq -r '.isDraft')"
release_is_prerelease="$(printf '%s\n' "$release_json" | jq -r '.isPrerelease')"
expected_release_body="$(<"$recovered/bundle/release-notes.md")"
actual_release_body="$(printf '%s\n' "$release_json" | jq -r '.body // ""')"
if [[ "$release_is_draft" == false || "$release_is_draft" == "false" ]] &&
   [[ "$release_is_prerelease" == true || "$release_is_prerelease" == "true" ]]; then
  [[ "$release_name" == "无线麦SayAll.app $version" && "$actual_release_body" == "$expected_release_body" ]] || {
    echo "Existing public Pre-release metadata differs; refusing to overwrite Release Notes" >&2
    exit 1
  }
else
  $GH_BIN release edit "$tag" --repo "$REPOSITORY" \
    --draft=false --prerelease=true --latest=false \
    --title "无线麦SayAll.app $version" \
    --notes-file "$recovered/bundle/release-notes.md"
fi

release_json="$($GH_BIN release view "$tag" --repo "$REPOSITORY" --json isDraft,isPrerelease,assets)"
printf '%s\n' "$release_json" | jq -e '.isDraft == false and .isPrerelease == true' >/dev/null
remote_assets="$(printf '%s\n' "$release_json" | jq -r '.assets[] | [.name, (.size | tostring), (.digest // "")] | @tsv')"
[[ "$(printf '%s\n' "$remote_assets" | /usr/bin/awk 'NF {count++} END {print count+0}')" -eq 12 ]] || {
  echo "Published Pre-release does not contain the exact 12 expected assets" >&2
  exit 1
}

github_dir="$work_dir/github"
cdn_dir="$work_dir/cdn"
/bin/mkdir -p "$github_dir" "$cdn_dir"
while IFS=$'\t' read -r name _ expected_sha; do
  [[ -n "$name" ]] || continue
  /usr/bin/curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    "https://github.com/$REPOSITORY/releases/download/$tag/$name" \
    --output "$github_dir/$name"
  [[ "$(/usr/bin/shasum -a 256 "$github_dir/$name" | /usr/bin/awk '{print $1}')" == "$expected_sha" ]] || {
    echo "GitHub fixed-tag download differs from staged bytes: $name" >&2
    exit 1
  }
  if [[ "$name" != candidate-provenance.json ]]; then
    /usr/bin/curl --fail --silent --show-error --location --retry 6 --retry-all-errors --retry-delay 3 \
      "https://download.sayall.app/mac/releases/$tag/$name" \
      --output "$cdn_dir/$name"
    /usr/bin/cmp -s "$github_dir/$name" "$cdn_dir/$name" || {
      echo "CDN fixed-tag download differs from GitHub: $name" >&2
      exit 1
    }
  fi
done < "$expected_assets"

stable_release_after="$($GH_BIN api "repos/$REPOSITORY/releases/latest")" || {
  echo "unable to verify releases/latest after publication" >&2
  exit 1
}
stable_latest_after="$(printf '%s\n' "$stable_release_after" | jq -r '.tag_name')"
printf '%s\n' "$stable_release_after" | jq -e \
  --arg tag "$stable_latest_after" \
  '.tag_name == $tag and ($tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and .draft == false and .prerelease == false' >/dev/null || {
  echo "releases/latest is no longer a formal stable Release" >&2
  exit 1
}
[[ "$stable_latest_after" == "$stable_latest_before" ]] || {
  echo "Preview publication changed releases/latest from $stable_latest_before to $stable_latest_after" >&2
  exit 1
}

echo "PREVIEW RELEASE PUBLISHED AND VERIFIED"
echo "TAG: $tag"
echo "SOURCE_COMMIT: $source_commit"
echo "ASSET_MANIFEST_SHA256: $manifest_sha"
