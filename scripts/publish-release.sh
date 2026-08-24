#!/bin/zsh
set -euo pipefail
umask 022

SCRIPT_ROOT="${0:A:h:h}"
SOURCE_ROOT="${RELEASE_SOURCE_ROOT:-$SCRIPT_ROOT}"
OUTPUT_DIR="$SOURCE_ROOT/dist"
PLIST="$SOURCE_ROOT/Resources/Info.plist"
REPOSITORY="HD838A/remote-mic-app"
PUBLIC_PRODUCT_NAME="无线麦SayAll.app"
MODE="${1:-}"
DRY_RUN="${DRY_RUN:-0}"
PUBLIC_DOWNLOAD_CONCURRENCY="${PUBLIC_DOWNLOAD_CONCURRENCY:-4}"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-L3QHLDRPAY}"
REQUEST_ATTESTATION="${RELEASE_REQUEST_ATTESTATION:-}"
REQUEST_ID="${RELEASE_REQUEST_ID:-}"
EXPECTED_PIPELINE_DIGEST="${EXPECTED_PIPELINE_DIGEST:-}"
EXPECTED_STABLE_TAG="${EXPECTED_STABLE_TAG:-v1.8.3}"
PLIST_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
PLIST_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PLIST")"
REQUESTED_RELEASE_TAG="${RELEASE_TAG:-}"
VERSION="$PLIST_VERSION"
BUILD="$PLIST_BUILD"

APP="$OUTPUT_DIR/SayAll.app"
INSTALL_PACKAGE="$OUTPUT_DIR/Install Remote Mic.pkg"
UNINSTALL_PACKAGE="$OUTPUT_DIR/Uninstall Remote Mic.pkg"
DMG="$OUTPUT_DIR/Remote-Mic-$VERSION.dmg"
DMG_CHECKSUM="$DMG.sha256"
UPDATE_ZIP="$OUTPUT_DIR/Remote-Mic-$VERSION.zip"
APPCAST="$OUTPUT_DIR/appcast.xml"
ZH_RELEASE_NOTES="$OUTPUT_DIR/Remote-Mic-$VERSION.zh.txt"
EN_RELEASE_NOTES="$OUTPUT_DIR/Remote-Mic-$VERSION.en.txt"
INTEL_OUTPUT_DIR="$OUTPUT_DIR/intel"
INTEL_INSTALL_PACKAGE="$INTEL_OUTPUT_DIR/Install Remote Mic Intel.pkg"
INTEL_UNINSTALL_PACKAGE="$INTEL_OUTPUT_DIR/Uninstall Remote Mic Intel.pkg"
INTEL_DMG="$INTEL_OUTPUT_DIR/Remote-Mic-$VERSION-Intel.dmg"
INTEL_DMG_CHECKSUM="$INTEL_DMG.sha256"
INTEL_UPDATE_ZIP="$INTEL_OUTPUT_DIR/Remote-Mic-$VERSION-Intel.zip"
INTEL_APPCAST="$INTEL_OUTPUT_DIR/appcast-intel.xml"
INTEL_ZH_RELEASE_NOTES="$INTEL_OUTPUT_DIR/Remote-Mic-$VERSION-Intel.zh.txt"
INTEL_EN_RELEASE_NOTES="$INTEL_OUTPUT_DIR/Remote-Mic-$VERSION-Intel.en.txt"
SHARED_CHECKSUM_BASENAME="Remote-Mic-$VERSION.dmg.sha256"

if [[ "$#" -ne 1 || \
      ( "$MODE" != "prerelease" && \
        "$MODE" != "resume-prerelease" && \
        "$MODE" != "verify-prerelease" && \
        "$MODE" != "promote" ) ]]; then
  print -u2 "usage: $0 prerelease|resume-prerelease|verify-prerelease|promote"
  exit 1
fi
case "$DRY_RUN" in
  0|1) ;;
  *) print -u2 "DRY_RUN must be 0 or 1"; exit 1 ;;
esac
if [[ ! "$PUBLIC_DOWNLOAD_CONCURRENCY" =~ '^[1-9][0-9]*$' ]] || \
    (( PUBLIC_DOWNLOAD_CONCURRENCY > 8 )); then
  print -u2 "PUBLIC_DOWNLOAD_CONCURRENCY must be between 1 and 8"
  exit 1
fi
if [[ "$EXPECTED_DEVELOPER_TEAM_ID" != "L3QHLDRPAY" ]]; then
  print -u2 "refusing to publish for an unexpected Apple Developer Team"
  exit 1
fi
if [[ ! "$EXPECTED_STABLE_TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "EXPECTED_STABLE_TAG must be an exact semantic version tag"
  exit 1
fi
if [[ "$MODE" == "prerelease" || "$MODE" == "resume-prerelease" || "$MODE" == "verify-prerelease" ]]; then
  RELEASE_TAG="${REQUESTED_RELEASE_TAG:-v$VERSION}"
  if [[ "$RELEASE_TAG" != "v$VERSION" ]]; then
    print -u2 "RELEASE_TAG must match the version in Resources/Info.plist"
    exit 1
  fi
else
  if [[ -z "$REQUESTED_RELEASE_TAG" ]]; then
    print -u2 "stable promotion requires an explicit RELEASE_TAG"
    exit 1
  fi
  RELEASE_TAG="$REQUESTED_RELEASE_TAG"
fi
if [[ ! "$RELEASE_TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "RELEASE_TAG must be a stable semantic version tag such as v1.8.8"
  exit 1
fi
GITHUB_DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/"
CDN_DOWNLOAD_PREFIX="https://download.sayall.app/mac/releases/$RELEASE_TAG/"
for command_name in cmp curl gh git jq plutil rg shasum stat; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

if [[ "$DRY_RUN" == "0" ]]; then
  expected_workflow_path=".github/workflows/mac-release-package.yml"
  expected_head_branch="release/pre-$RELEASE_TAG"
  if [[ "$MODE" == "resume-prerelease" ]]; then
    expected_head_branch="main"
  fi
  if [[ "$MODE" == "promote" ]]; then
    expected_workflow_path=".github/workflows/mac-stable-promote.yml"
    expected_head_branch="main"
  fi
  expected_workflow_ref="$REPOSITORY/$expected_workflow_path@"
  current_commit="$(git -C "$SCRIPT_ROOT" rev-parse HEAD)"
  if [[ "${GITHUB_ACTIONS:-}" != "true" || \
        "${GITHUB_REPOSITORY:-}" != "$REPOSITORY" || \
        "${GITHUB_EVENT_NAME:-}" != "workflow_dispatch" || \
        "${GITHUB_REF_NAME:-}" != "$expected_head_branch" || \
        "${GITHUB_SHA:-}" != "$current_commit" || \
        ! "${GITHUB_RUN_ID:-}" =~ '^[1-9][0-9]*$' || \
        ! "${GITHUB_RUN_ATTEMPT:-}" =~ '^[1-9][0-9]*$' || \
        "${GITHUB_WORKFLOW_REF:-}" != "$expected_workflow_ref"* ]]; then
    print -u2 "release mutation is restricted to the expected protected GitHub workflow"
    exit 1
  fi
  run_identity="$(gh api "repos/$REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT")"
  if ! print -r -- "$run_identity" | jq -e \
    --arg repository "$REPOSITORY" \
    --arg event "workflow_dispatch" \
    --arg workflowPath "$expected_workflow_path" \
    --arg headBranch "$expected_head_branch" \
    --arg headSha "$current_commit" \
    --argjson runAttempt "$GITHUB_RUN_ATTEMPT" '
      .repository.full_name == $repository and
      .event == $event and
      .path == $workflowPath and
      .head_branch == $headBranch and
      .head_sha == $headSha and
      .run_attempt == $runAttempt and
      .status == "in_progress"
    ' >/dev/null; then
    print -u2 "GitHub API did not confirm the active protected release workflow identity"
    exit 1
  fi
fi

WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-publish-release.XXXXXX)"
STAGING_DIR="$WORK_DIR/upload"
DOWNLOAD_DIR="$WORK_DIR/download"
CDN_DOWNLOAD_DIR="$WORK_DIR/cdn-download"
RELEASE_NOTES="$WORK_DIR/release-notes.md"
CANDIDATE_PROVENANCE="$STAGING_DIR/candidate-provenance.json"
CANDIDATE_RELEASE_MANIFEST="$WORK_DIR/candidate-release-assets.txt"
STABLE_PROMOTION="$WORK_DIR/stable-promotion.json"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remotemic-publish-release.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected publish work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

/bin/mkdir -p "$STAGING_DIR" "$DOWNLOAD_DIR" "$CDN_DOWNLOAD_DIR"

require_expected_stable_latest() {
  local actual_stable_tag
  actual_stable_tag="$(gh api "repos/$REPOSITORY/releases/latest" --jq .tag_name)"
  if [[ "$actual_stable_tag" != "$EXPECTED_STABLE_TAG" ]]; then
    print -u2 "stable latest must remain $EXPECTED_STABLE_TAG during Preview publication; found $actual_stable_tag"
    return 1
  fi
}

verify_update_zip() {
  local archive="$1"
  local variant="$2"
  local extract_dir="$WORK_DIR/verify-$variant-update-zip"
  /bin/mkdir -p "$extract_dir"
  /usr/bin/ditto -x -k "$archive" "$extract_dir"
  if [[ "$variant" == "intel" ]]; then
    RELEASE_VARIANT=intel "$SCRIPT_ROOT/scripts/verify-app.sh" "$extract_dir/SayAll.app"
  else
    "$SCRIPT_ROOT/scripts/verify-app.sh" "$extract_dir/SayAll.app"
  fi
}

verify_local_artifacts() {
  test -f "$UNINSTALL_PACKAGE"
  test -f "$DMG"
  test -f "$DMG_CHECKSUM"
  test -f "$UPDATE_ZIP"
  test -f "$APPCAST"
  test -f "$ZH_RELEASE_NOTES"
  test -f "$EN_RELEASE_NOTES"
  test -f "$INTEL_UNINSTALL_PACKAGE"
  test -f "$INTEL_DMG"
  test -f "$INTEL_DMG_CHECKSUM"
  test -f "$INTEL_UPDATE_ZIP"
  test -f "$INTEL_APPCAST"

  export EXPECTED_DEVELOPER_TEAM_ID REQUIRE_DEVELOPER_ID_SIGNING=1 REQUIRE_NOTARIZATION=1
  verify_update_zip "$UPDATE_ZIP" apple-silicon
  verify_update_zip "$INTEL_UPDATE_ZIP" intel
  "$SCRIPT_ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall
  "$SCRIPT_ROOT/scripts/verify-dmg.sh" "$DMG"
  RELEASE_VARIANT=intel "$SCRIPT_ROOT/scripts/verify-doubao-driver-pkg.sh" "$INTEL_UNINSTALL_PACKAGE" uninstall
  RELEASE_VARIANT=intel "$SCRIPT_ROOT/scripts/verify-dmg.sh" "$INTEL_DMG"

  rg -Fq "url=\"$CDN_DOWNLOAD_PREFIX${UPDATE_ZIP:t}\"" "$APPCAST"
  rg -Fq "$CDN_DOWNLOAD_PREFIX${ZH_RELEASE_NOTES:t}" "$APPCAST"
  rg -Fq "$CDN_DOWNLOAD_PREFIX${EN_RELEASE_NOTES:t}" "$APPCAST"
  rg -Fq "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST"
  rg -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST"
  rg -Fq "url=\"$CDN_DOWNLOAD_PREFIX${INTEL_UPDATE_ZIP:t}\"" "$INTEL_APPCAST"
  rg -Fq "$CDN_DOWNLOAD_PREFIX${ZH_RELEASE_NOTES:t}" "$INTEL_APPCAST"
  rg -Fq "$CDN_DOWNLOAD_PREFIX${EN_RELEASE_NOTES:t}" "$INTEL_APPCAST"
  rg -Fq "<sparkle:version>$BUILD</sparkle:version>" "$INTEL_APPCAST"
  rg -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$INTEL_APPCAST"
}

stage_assets() {
  /usr/bin/ditto --norsrc --noqtn --noacl "$UNINSTALL_PACKAGE" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Uninstaller.pkg"
  /usr/bin/ditto --norsrc --noqtn --noacl "$DMG" "$STAGING_DIR/${DMG:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl "$UPDATE_ZIP" "$STAGING_DIR/${UPDATE_ZIP:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl "$APPCAST" "$STAGING_DIR/appcast.xml"
  /usr/bin/ditto --norsrc --noqtn --noacl \
    "$ZH_RELEASE_NOTES" "$STAGING_DIR/${ZH_RELEASE_NOTES:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl \
    "$EN_RELEASE_NOTES" "$STAGING_DIR/${EN_RELEASE_NOTES:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl "$INTEL_UNINSTALL_PACKAGE" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Intel-Uninstaller.pkg"
  /usr/bin/ditto --norsrc --noqtn --noacl "$INTEL_DMG" "$STAGING_DIR/${INTEL_DMG:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl \
    "$INTEL_UPDATE_ZIP" "$STAGING_DIR/${INTEL_UPDATE_ZIP:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl "$INTEL_APPCAST" "$STAGING_DIR/appcast-intel.xml"

  (
    cd "$STAGING_DIR"
    /usr/bin/shasum -a 256 "${DMG:t}" "${INTEL_DMG:t}" > "$SHARED_CHECKSUM_BASENAME"
  )

  /usr/bin/cmp -s "$UNINSTALL_PACKAGE" "$STAGING_DIR/Remote-Mic-$VERSION-Uninstaller.pkg"
  /usr/bin/cmp -s "$DMG" "$STAGING_DIR/${DMG:t}"
  /usr/bin/cmp -s "$UPDATE_ZIP" "$STAGING_DIR/${UPDATE_ZIP:t}"
  /usr/bin/cmp -s "$APPCAST" "$STAGING_DIR/appcast.xml"
  /usr/bin/cmp -s "$ZH_RELEASE_NOTES" "$STAGING_DIR/${ZH_RELEASE_NOTES:t}"
  /usr/bin/cmp -s "$EN_RELEASE_NOTES" "$STAGING_DIR/${EN_RELEASE_NOTES:t}"
  /usr/bin/cmp -s "$INTEL_UNINSTALL_PACKAGE" "$STAGING_DIR/Remote-Mic-$VERSION-Intel-Uninstaller.pkg"
  /usr/bin/cmp -s "$INTEL_DMG" "$STAGING_DIR/${INTEL_DMG:t}"
  /usr/bin/cmp -s "$INTEL_UPDATE_ZIP" "$STAGING_DIR/${INTEL_UPDATE_ZIP:t}"
  /usr/bin/cmp -s "$INTEL_APPCAST" "$STAGING_DIR/appcast-intel.xml"
  (
    cd "$STAGING_DIR"
    /usr/bin/shasum -a 256 -c "$SHARED_CHECKSUM_BASENAME"
  )
}

generate_release_notes() {
  {
    print "## 更新内容"
    print
    /usr/bin/awk -v version="$VERSION" '
      index($0, "## " version) == 1 { active = 1; next }
      active && /^## / { exit }
      active { print }
    ' "$SOURCE_ROOT/Resources/zh-Hans.lproj/ReleaseHistory.md"
  } > "$RELEASE_NOTES"

  rg -q '^- ' "$RELEASE_NOTES"

  if rg -i -q \
    '((连续|连点|点击|轻点).{0,24}(版本号|当前版本).{0,24}(次|隐藏|入口))|((tap|click).{0,24}(version|build).{0,24}(times|hidden|secret|invite|enrollment))|(隐藏入口|秘密手势|secret gesture|hidden entry|invitation-code entry)' \
    "$SOURCE_ROOT/Resources/zh-Hans.lproj/ReleaseHistory.md" \
    "$SOURCE_ROOT/Resources/en.lproj/ReleaseHistory.md" \
    "$RELEASE_NOTES"; then
    print -u2 "release notes contain an internal trigger or confidential enrollment detail"
    exit 1
  fi
}

validate_payload_asset_manifest() {
  local provenance="$1"
  jq -e '
    (.payloadAssets | type == "array" and length > 0) and
    ([.payloadAssets[].name] | length == (unique | length)) and
    all(.payloadAssets[];
      (.name | type == "string" and length > 0 and
        test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and
        . != "candidate-provenance.json" and
        . != "stable-promotion.json") and
      (.size | type == "number" and . >= 0 and floor == .) and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
  ' "$provenance" >/dev/null
}

validate_request_attestation() {
  local expected_commit="$1"
  local expected_base="$2"
  if [[ ! -r "$REQUEST_ATTESTATION" ]]; then
    print -u2 "preview publication requires the immutable request attestation"
    return 1
  fi
  jq -e \
    --arg requestId "$REQUEST_ID" \
    --arg tag "$RELEASE_TAG" \
    --arg commit "$expected_commit" \
    --arg base "$expected_base" \
    --arg pipelineDigest "$EXPECTED_PIPELINE_DIGEST" '
      .schemaVersion == 4 and
      .requestId == $requestId and
      .attemptId == $commit and
      .tag == $tag and
      .candidateCommit == $commit and
      .baseMainCommit == $base and
      .pipelineDigest == $pipelineDigest and
      (.requestStartedAt | type == "number" and . >= 0 and floor == .) and
      (.releaseReadyAt | type == "number") and
      (.releaseReadyAt >= .requestStartedAt) and
      (.releaseReadyAt | floor == .) and
      (.pipelineQualifiedAt | type == "string" and length > 0) and
      (.pipelineQualificationRunId | type == "number" and . > 0) and
      (.pipelineQualificationArtifactId | type == "number" and . > 0) and
      (.pipelineQualificationArtifactDigest | type == "string" and
        test("^sha256:[0-9a-f]{64}$")) and
      (.attestationRunId | type == "number" and . > 0) and
      (.attestationRunAttempt | type == "number" and . > 0)
    ' "$REQUEST_ATTESTATION" >/dev/null
}

write_candidate_release_manifest() {
  local provenance="$1"
  local output_file="$2"
  validate_payload_asset_manifest "$provenance"
  {
    jq -r '.payloadAssets[].name' "$provenance"
    print -r -- "candidate-provenance.json"
  } | LC_ALL=C /usr/bin/sort > "$output_file"
  test "$(/usr/bin/wc -l < "$output_file" | /usr/bin/tr -d ' ')" -gt 1
}

verify_asset_directory_matches_manifest() {
  local source_dir="$1"
  local manifest_file="$2"
  local label="$3"
  local actual_manifest="$WORK_DIR/$label-actual-assets.txt"
  local file_path
  : > "$actual_manifest"
  for file_path in "$source_dir"/*(DN); do
    if [[ ! -f "$file_path" || -L "$file_path" ]]; then
      print -u2 "$label contains a non-regular release asset: ${file_path:t}"
      return 1
    fi
    print -r -- "${file_path:t}" >> "$actual_manifest"
  done
  LC_ALL=C /usr/bin/sort -o "$actual_manifest" "$actual_manifest"
  if ! /usr/bin/cmp -s "$manifest_file" "$actual_manifest"; then
    print -u2 "$label asset set does not exactly match candidate provenance"
    print -u2 "expected assets:"
    /bin/cat "$manifest_file" >&2
    print -u2 "actual assets:"
    /bin/cat "$actual_manifest" >&2
    return 1
  fi
}

generate_candidate_provenance() {
  local branch head_commit base_main_commit payload_json_file file_path file_name file_size file_sha
  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  branch="${branch:-${RELEASE_CANDIDATE_BRANCH:-${GITHUB_REF_NAME:-}}}"
  head_commit="$(git rev-parse HEAD)"
  base_main_commit="$(git rev-parse HEAD^)"
  validate_request_attestation "$head_commit" "$base_main_commit"
  payload_json_file="$WORK_DIR/payload-assets.jsonl"
  : > "$payload_json_file"

  for file_path in "$STAGING_DIR"/*; do
    file_name="${file_path:t}"
    file_size="$(/usr/bin/stat -f '%z' "$file_path")"
    file_sha="$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{ print $1 }')"
    jq -cn \
      --arg name "$file_name" \
      --argjson size "$file_size" \
      --arg sha256 "$file_sha" \
      '{name: $name, size: $size, sha256: $sha256}' >> "$payload_json_file"
  done

  jq -s \
    --arg repository "$REPOSITORY" \
    --arg candidateBranch "$branch" \
    --arg tag "$RELEASE_TAG" \
    --arg tagCommit "$head_commit" \
    --arg baseMainCommit "$base_main_commit" \
    --arg version "$VERSION" \
    --arg build "$BUILD" \
    --slurpfile requestAttestation "$REQUEST_ATTESTATION" \
    '{
      schemaVersion: 3,
      repository: $repository,
      candidateBranch: $candidateBranch,
      tag: $tag,
      tagCommit: $tagCommit,
      baseMainCommit: $baseMainCommit,
      version: $version,
      build: $build,
      requestId: $requestAttestation[0].requestId,
      attemptId: $requestAttestation[0].attemptId,
      requestStartedAt: $requestAttestation[0].requestStartedAt,
      releaseReadyAt: $requestAttestation[0].releaseReadyAt,
      pipelineDigest: $requestAttestation[0].pipelineDigest,
      pipelineQualifiedAt: $requestAttestation[0].pipelineQualifiedAt,
      pipelineQualificationRunId: $requestAttestation[0].pipelineQualificationRunId,
      pipelineQualificationArtifactId: $requestAttestation[0].pipelineQualificationArtifactId,
      pipelineQualificationArtifactDigest: $requestAttestation[0].pipelineQualificationArtifactDigest,
      requestAttestationRunId: $requestAttestation[0].attestationRunId,
      requestAttestationRunAttempt: $requestAttestation[0].attestationRunAttempt,
      payloadAssets: .
  }' "$payload_json_file" > "$CANDIDATE_PROVENANCE"
  write_candidate_release_manifest \
    "$CANDIDATE_PROVENANCE" "$CANDIDATE_RELEASE_MANIFEST"
  verify_asset_directory_matches_manifest \
    "$STAGING_DIR" "$CANDIDATE_RELEASE_MANIFEST" staging
}

verify_candidate_source() {
  cd "$SOURCE_ROOT"
  if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 "refusing to publish from a dirty worktree"
    exit 1
  fi

  RELEASE_CANDIDATE_BRANCH="${RELEASE_CANDIDATE_BRANCH:-${GITHUB_REF_NAME:-}}" \
    GITHUB_REF_NAME="${RELEASE_CANDIDATE_BRANCH:-${GITHUB_REF_NAME:-}}" \
    REPOSITORY_ROOT="$SOURCE_ROOT" \
    "$SCRIPT_ROOT/scripts/verify-preview-branch.sh"

  local head_commit local_tag_commit remote_tag_commit
  head_commit="$(git rev-parse HEAD)"
  local_tag_commit="$(git rev-parse "$RELEASE_TAG^{commit}" 2>/dev/null)" || {
    print -u2 "local tag $RELEASE_TAG is missing"
    exit 1
  }
  if [[ "$local_tag_commit" != "$head_commit" ]]; then
    print -u2 "local tag $RELEASE_TAG does not point to candidate HEAD"
    exit 1
  fi
  remote_tag_commit="$(git ls-remote origin "refs/tags/$RELEASE_TAG^{}" | /usr/bin/awk 'NR == 1 { print $1 }')"
  if [[ -z "$remote_tag_commit" ]]; then
    remote_tag_commit="$(git ls-remote origin "refs/tags/$RELEASE_TAG" | /usr/bin/awk 'NR == 1 { print $1 }')"
  fi
  if [[ "$remote_tag_commit" != "$head_commit" ]]; then
    print -u2 "remote tag $RELEASE_TAG must point to candidate HEAD"
    exit 1
  fi
}

verify_promotion_source() {
  cd "$SOURCE_ROOT"
  if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 "refusing to promote from a dirty worktree"
    exit 1
  fi
  local branch head_commit tag_commit remote_tag_commit
  branch="$(git symbolic-ref --quiet --short HEAD)" || {
    print -u2 "promotion requires the main branch"
    exit 1
  }
  if [[ "$branch" != "main" ]]; then
    print -u2 "stable promotion is restricted to main"
    exit 1
  fi
  git fetch origin main --tags >/dev/null
  head_commit="$(git rev-parse HEAD)"
  if [[ "$head_commit" != "$(git rev-parse origin/main)" ]]; then
    print -u2 "local main must exactly match origin/main before promotion"
    exit 1
  fi
  tag_commit="$(git rev-parse "$RELEASE_TAG^{commit}" 2>/dev/null)" || {
    print -u2 "local tag $RELEASE_TAG is missing"
    exit 1
  }
  remote_tag_commit="$(git ls-remote origin "refs/tags/$RELEASE_TAG^{}" | /usr/bin/awk 'NR == 1 { print $1 }')"
  if [[ -z "$remote_tag_commit" ]]; then
    remote_tag_commit="$(git ls-remote origin "refs/tags/$RELEASE_TAG" | /usr/bin/awk 'NR == 1 { print $1 }')"
  fi
  if [[ "$remote_tag_commit" != "$tag_commit" ]]; then
    print -u2 "remote tag $RELEASE_TAG does not match the local tag"
    exit 1
  fi
  if ! git merge-base --is-ancestor "$tag_commit" origin/main; then
    print -u2 "candidate tag commit is not contained in origin/main"
    exit 1
  fi
}

wait_for_download_batch() {
  local label="$1"
  shift
  local download_pid failed=0
  for download_pid in "$@"; do
    if ! wait "$download_pid"; then
      failed=1
    fi
  done
  if (( failed != 0 )); then
    print -u2 "$label asset download or comparison failed"
    return 1
  fi
}

download_asset() {
  local asset_name="$1"
  local destination_dir="$2"
  local download_prefix="$3"
  local label="$4"
  local destination_file="$destination_dir/$asset_name"

  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors \
    "$download_prefix$asset_name" \
    --output "$destination_file"
  print "$label DOWNLOAD PASS: $asset_name"
}

download_assets_from_manifest() {
  local manifest_file="$1"
  local destination_dir="$2"
  local download_prefix="$3"
  local label="$4"
  local asset_name
  local -a batch_pids=()

  for asset_name in "${(@f)$(<"$manifest_file")}"; do
    [[ -n "$asset_name" ]] || continue
    if [[ -f "$destination_dir/$asset_name" ]]; then
      continue
    fi
    download_asset "$asset_name" "$destination_dir" "$download_prefix" "$label" &
    batch_pids+=("$!")
    if (( ${#batch_pids[@]} >= PUBLIC_DOWNLOAD_CONCURRENCY )); then
      wait_for_download_batch "$label" "${batch_pids[@]}"
      batch_pids=()
    fi
  done
  if (( ${#batch_pids[@]} != 0 )); then
    wait_for_download_batch "$label" "${batch_pids[@]}"
  fi
}

download_and_compare_assets() {
  local source_dir="$1"
  local destination_dir="$2"
  local download_prefix="$3"
  local label="$4"
  local manifest_file="$5"
  local source_file asset_name downloaded_file source_sha downloaded_sha expected_count

  /bin/mkdir -p "$destination_dir"
  test "$(/usr/bin/find "$destination_dir" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "0"
  verify_asset_directory_matches_manifest "$source_dir" "$manifest_file" "$label-source"
  expected_count="$(/usr/bin/wc -l < "$manifest_file" | /usr/bin/tr -d ' ')"
  test "$expected_count" -gt 1

  download_assets_from_manifest "$manifest_file" "$destination_dir" \
    "$download_prefix" "$label"

  while IFS= read -r asset_name; do
    [[ -n "$asset_name" ]] || continue
    source_file="$source_dir/$asset_name"
    downloaded_file="$destination_dir/$asset_name"
    test -f "$source_file"
    test -f "$downloaded_file"
    /usr/bin/cmp -s "$source_file" "$downloaded_file"
    source_sha="$(/usr/bin/shasum -a 256 "$source_file" | /usr/bin/awk '{ print $1 }')"
    downloaded_sha="$(/usr/bin/shasum -a 256 "$downloaded_file" | /usr/bin/awk '{ print $1 }')"
    test "$source_sha" = "$downloaded_sha"
    print "$label COMPARE PASS: $asset_name $downloaded_sha"
  done < "$manifest_file"
  verify_asset_directory_matches_manifest \
    "$destination_dir" "$manifest_file" "$label-download"
}

download_release_assets() {
  local remote_manifest="$WORK_DIR/github-origin-assets.txt"
  /bin/mkdir -p "$DOWNLOAD_DIR"
  test "$(/usr/bin/find "$DOWNLOAD_DIR" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "0"
  gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" \
    --jq '.assets[].name' | LC_ALL=C /usr/bin/sort > "$remote_manifest"
  if ! rg -Fxq 'candidate-provenance.json' "$remote_manifest"; then
    print -u2 "release is missing candidate-provenance.json"
    return 1
  fi
  download_asset candidate-provenance.json "$DOWNLOAD_DIR" \
    "$GITHUB_DOWNLOAD_PREFIX" github-origin
  validate_payload_asset_manifest "$DOWNLOAD_DIR/candidate-provenance.json"
  write_candidate_release_manifest \
    "$DOWNLOAD_DIR/candidate-provenance.json" "$CANDIDATE_RELEASE_MANIFEST"
  if ! /usr/bin/cmp -s "$remote_manifest" "$CANDIDATE_RELEASE_MANIFEST"; then
    print -u2 "GitHub Release asset set does not exactly match candidate provenance"
    return 1
  fi
  download_assets_from_manifest "$CANDIDATE_RELEASE_MANIFEST" "$DOWNLOAD_DIR" \
    "$GITHUB_DOWNLOAD_PREFIX" github-origin
  verify_asset_directory_matches_manifest \
    "$DOWNLOAD_DIR" "$CANDIDATE_RELEASE_MANIFEST" github-origin-download
}

verify_cdn_assets() {
  local source_dir="$1"
  local manifest_file="$2"
  download_and_compare_assets "$source_dir" "$CDN_DOWNLOAD_DIR" \
    "$CDN_DOWNLOAD_PREFIX" cdn "$manifest_file"

  local dmg_name="Remote-Mic-$VERSION.dmg"
  local header_file="$WORK_DIR/cdn-dmg-headers.txt"
  curl --fail --silent --show-error --head \
    "$CDN_DOWNLOAD_PREFIX$dmg_name" > "$header_file"
  rg -qi '^x-remote-mic-cdn: cloudflare' "$header_file"
  rg -qi '^accept-ranges: bytes' "$header_file"

  local range_file="$WORK_DIR/cdn-dmg-range.bin"
  local expected_range="$WORK_DIR/local-dmg-range.bin"
  local range_status
  range_status="$(curl --fail --silent --show-error --location \
    --range 0-1023 \
    --output "$range_file" \
    --write-out '%{http_code}' \
    "$CDN_DOWNLOAD_PREFIX$dmg_name")"
  test "$range_status" = "206"
  /usr/bin/head -c 1024 "$source_dir/$dmg_name" > "$expected_range"
  /usr/bin/cmp -s "$expected_range" "$range_file"
}

verify_stable_download_redirect() {
  local redirect_result
  redirect_result="$(curl --silent --show-error --head --output /dev/null \
    --write-out '%{http_code}\t%{redirect_url}' \
    'https://download.sayall.app/mac')"
  test "$redirect_result" = $'302\t'"$CDN_DOWNLOAD_PREFIX""Remote-Mic-$VERSION.dmg"
}

verify_downloaded_candidate() {
  local provenance="$DOWNLOAD_DIR/candidate-provenance.json"
  test -f "$provenance"
  VERSION="$(jq -r '.version' "$provenance")"
  BUILD="$(jq -r '.build' "$provenance")"
  jq -e \
    --arg repository "$REPOSITORY" \
    --arg tag "$RELEASE_TAG" \
    --arg version "$VERSION" \
    --arg build "$BUILD" \
    '(.schemaVersion == 1 or .schemaVersion == 2 or .schemaVersion == 3) and
     .repository == $repository and .tag == $tag and
     .version == $version and .build == $build and
     (.candidateBranch | type == "string") and
     (.tagCommit | test("^[0-9a-f]{40}$")) and
     (if .schemaVersion >= 2 then (.baseMainCommit | test("^[0-9a-f]{40}$")) else true end) and
     (if .schemaVersion == 3 then
        (.requestId | type == "string" and length >= 8) and
        .attemptId == .tagCommit and
        (.requestStartedAt | type == "number" and . >= 0 and floor == .) and
        (.releaseReadyAt | type == "number") and
        (.releaseReadyAt >= .requestStartedAt) and
        (.releaseReadyAt | floor == .) and
        (.pipelineDigest | type == "string" and test("^[0-9a-f]{64}$")) and
        (.pipelineQualifiedAt | type == "string" and length > 0) and
        (.pipelineQualificationRunId | type == "number" and . > 0) and
        (.pipelineQualificationArtifactId | type == "number" and . > 0) and
        (.pipelineQualificationArtifactDigest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
        (.requestAttestationRunId | type == "number" and . > 0) and
        (.requestAttestationRunAttempt | type == "number" and . > 0)
      else true end)' \
    "$provenance" >/dev/null
  validate_payload_asset_manifest "$provenance"
  if [[ "$VERSION" != "${RELEASE_TAG#v}" || ! "$BUILD" =~ '^[0-9]+$' ]]; then
    print -u2 "candidate provenance version/build does not match $RELEASE_TAG"
    exit 1
  fi

  local schema_version tag_commit base_main_commit candidate_branch legacy_branch_prefix legacy_branch_suffix remote_branch_commit asset_name expected_size expected_sha file_path actual_size actual_sha
  schema_version="$(jq -r '.schemaVersion' "$provenance")"
  tag_commit="$(jq -r '.tagCommit' "$provenance")"
  candidate_branch="$(jq -r '.candidateBranch' "$provenance")"
  if ! git check-ref-format "refs/heads/$candidate_branch"; then
    print -u2 "candidate provenance contains an invalid branch ref"
    exit 1
  fi
  if [[ "$MODE" == "prerelease" || "$MODE" == "verify-prerelease" ]]; then
    if [[ "$candidate_branch" != "release/pre-$RELEASE_TAG" ]]; then
      print -u2 "new Preview provenance must use the single branch release/pre-$RELEASE_TAG"
      exit 1
    fi
  elif [[ "$schema_version" == "3" ]]; then
    if [[ "$candidate_branch" != "release/pre-$RELEASE_TAG" ]]; then
      print -u2 "schema 3 candidate provenance must use release/pre-$RELEASE_TAG"
      exit 1
    fi
  elif [[ "$schema_version" == "2" && \
          "$candidate_branch" != "release/pre-$RELEASE_TAG" ]]; then
    legacy_branch_prefix="release/pre-$RELEASE_TAG-rerun"
    legacy_branch_suffix="${candidate_branch#$legacy_branch_prefix}"
    if [[ "$candidate_branch" != "$legacy_branch_prefix"* || \
          ! "$legacy_branch_suffix" =~ '^([2-9][0-9]*)?$' ]]; then
      print -u2 "candidate provenance contains an unsupported branch"
      exit 1
    fi
  fi
  if [[ "$tag_commit" != "$(git rev-parse "$RELEASE_TAG^{commit}")" ]]; then
    print -u2 "candidate provenance tag commit does not match $RELEASE_TAG"
    exit 1
  fi
  remote_branch_commit="$(git ls-remote origin "refs/heads/$candidate_branch" | /usr/bin/awk 'NR == 1 { print $1 }')"
  if [[ "$remote_branch_commit" != "$tag_commit" ]]; then
    print -u2 "candidate branch is missing or no longer points to the tagged commit"
    exit 1
  fi
  if [[ "$schema_version" == "2" || "$schema_version" == "3" ]]; then
    base_main_commit="$(jq -r '.baseMainCommit' "$provenance")"
    if [[ "$(git rev-parse "$tag_commit^")" != "$base_main_commit" ]]; then
      print -u2 "candidate provenance baseMainCommit is not the tag commit's direct parent"
      exit 1
    fi
    if ! git merge-base --is-ancestor "$base_main_commit" origin/main; then
      print -u2 "candidate provenance baseMainCommit is not contained in main history"
      exit 1
    fi
  fi

  if [[ "$schema_version" == "3" && \
        ( "$MODE" == "prerelease" || "$MODE" == "verify-prerelease" ) ]]; then
    validate_request_attestation "$tag_commit" "$(jq -r '.baseMainCommit' "$provenance")"
    if ! /usr/bin/cmp -s \
      <(jq -S '{requestId,attemptId,requestStartedAt,releaseReadyAt,pipelineDigest,pipelineQualifiedAt,pipelineQualificationRunId,pipelineQualificationArtifactId,pipelineQualificationArtifactDigest}' "$REQUEST_ATTESTATION") \
      <(jq -S '{requestId,attemptId,requestStartedAt,releaseReadyAt,pipelineDigest,pipelineQualifiedAt,pipelineQualificationRunId,pipelineQualificationArtifactId,pipelineQualificationArtifactDigest}' "$provenance"); then
      print -u2 "candidate provenance does not match the immutable request attestation"
      exit 1
    fi
  fi

  write_candidate_release_manifest "$provenance" "$CANDIDATE_RELEASE_MANIFEST"
  verify_asset_directory_matches_manifest \
    "$DOWNLOAD_DIR" "$CANDIDATE_RELEASE_MANIFEST" downloaded-candidate

  while IFS=$'\t' read -r asset_name expected_size expected_sha; do
    file_path="$DOWNLOAD_DIR/$asset_name"
    test -f "$file_path"
    actual_size="$(/usr/bin/stat -f '%z' "$file_path")"
    actual_sha="$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{ print $1 }')"
    if [[ "$actual_size" != "$expected_size" || "$actual_sha" != "$expected_sha" ]]; then
      print -u2 "candidate asset digest mismatch: $asset_name"
      exit 1
    fi
  done < <(jq -r '.payloadAssets[] | [.name, (.size | tostring), .sha256] | @tsv' "$provenance")
}

download_and_compare_local_candidate() {
  local github_pid cdn_pid github_status=0 cdn_status=0
  download_and_compare_assets "$STAGING_DIR" "$DOWNLOAD_DIR" \
    "$GITHUB_DOWNLOAD_PREFIX" github-origin "$CANDIDATE_RELEASE_MANIFEST" &
  github_pid="$!"
  verify_cdn_assets "$STAGING_DIR" "$CANDIDATE_RELEASE_MANIFEST" &
  cdn_pid="$!"
  wait "$github_pid" || github_status="$?"
  wait "$cdn_pid" || cdn_status="$?"
  if (( github_status != 0 || cdn_status != 0 )); then
    print -u2 "public release asset verification failed: github=$github_status cdn=$cdn_status"
    return 1
  fi
  verify_downloaded_candidate
}

generate_stable_promotion() {
  local provenance="$DOWNLOAD_DIR/candidate-provenance.json"
  local tag_commit main_commit promoted_at
  tag_commit="$(jq -r '.tagCommit' "$provenance")"
  main_commit="$(git rev-parse origin/main)"
  promoted_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq \
    --arg tag "$RELEASE_TAG" \
    --arg tagCommit "$tag_commit" \
    --arg mainCommit "$main_commit" \
    --arg promotedAt "$promoted_at" \
    --arg actor "${GITHUB_ACTOR:-$(gh api user --jq .login)}" \
    '{
      schemaVersion: 1,
      tag: $tag,
      tagCommit: $tagCommit,
      mainCommit: $mainCommit,
      promotedAt: $promotedAt,
      actor: $actor,
      payloadAssets: .payloadAssets
    }' "$provenance" > "$STABLE_PROMOTION"
  validate_payload_asset_manifest "$STABLE_PROMOTION"
}

dispatch_preview_recording_guard() {
  gh workflow run release-guard.yml \
    --repo "$REPOSITORY" \
    --ref main \
    -f "tag=$RELEASE_TAG"
  print "PREVIEW MAIN RECORDING DISPATCHED: $RELEASE_TAG"
}

if [[ "$MODE" == "verify-prerelease" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    print -u2 "verify-prerelease requires the existing public Pre-release"
    exit 2
  fi
  verify_candidate_source
  require_expected_stable_latest
  release_state="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" --jq '[.draft, .prerelease] | @tsv')"
  test "$release_state" = $'false\ttrue'
  download_release_assets
  verify_downloaded_candidate
  verify_cdn_assets "$DOWNLOAD_DIR" "$CANDIDATE_RELEASE_MANIFEST"
  require_expected_stable_latest
  dispatch_preview_recording_guard
  print "EXISTING PRE-RELEASE VERIFICATION PASS: https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"
  exit 0
fi

if [[ "$MODE" == "prerelease" || "$MODE" == "resume-prerelease" ]]; then
  verify_local_artifacts
  stage_assets
  generate_release_notes

  if [[ "$DRY_RUN" == "1" ]]; then
    generate_candidate_provenance
    print "RELEASE NOTES:"
    /bin/cat "$RELEASE_NOTES"
    print "PUBLISH DRY RUN PASS"
    print "MODE: prerelease"
    print "TAG: $RELEASE_TAG"
    print "VERSION: $VERSION ($BUILD)"
    exit 0
  fi

  verify_candidate_source
  generate_candidate_provenance
  if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    print -u2 "release $RELEASE_TAG already exists"
    exit 1
  fi

  require_expected_stable_latest
  active_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  active_branch="${active_branch:-${RELEASE_CANDIDATE_BRANCH:-${GITHUB_REF_NAME:-}}}"
  if [[ "$active_branch" != "release/pre-$RELEASE_TAG" ]]; then
    print -u2 "candidate branch identity is unavailable or does not match $RELEASE_TAG"
    exit 1
  fi
  active_head="$(git rev-parse HEAD)"
  remote_active_head="$(git ls-remote origin "refs/heads/$active_branch" | /usr/bin/awk 'NR == 1 { print $1 }')"
  if [[ "$remote_active_head" != "$active_head" ]]; then
    print -u2 "candidate branch changed before GitHub Release creation"
    exit 1
  fi
  typeset -a release_uploads=()
  while IFS= read -r asset_name; do
    [[ -n "$asset_name" ]] || continue
    release_uploads+=("$STAGING_DIR/$asset_name")
  done < "$CANDIDATE_RELEASE_MANIFEST"
  (( ${#release_uploads[@]} > 1 ))
  gh release create "$RELEASE_TAG" "${release_uploads[@]}" \
    --repo "$REPOSITORY" \
    --verify-tag \
    --prerelease \
    --latest=false \
    --title "$PUBLIC_PRODUCT_NAME $VERSION" \
    --notes-file "$RELEASE_NOTES"

  RELEASE_STATE="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" --jq '[.draft, .prerelease] | @tsv')"
  test "$RELEASE_STATE" = $'false\ttrue'
  require_expected_stable_latest
  download_and_compare_local_candidate
  dispatch_preview_recording_guard
  print "PRE-RELEASE PUBLISH PASS: https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"
  exit 0
fi

verify_promotion_source
RELEASE_STATE="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" --jq '[.draft, .prerelease] | @tsv')"
test "$RELEASE_STATE" = $'false\ttrue'
download_release_assets
verify_downloaded_candidate
verify_cdn_assets "$DOWNLOAD_DIR" "$CANDIDATE_RELEASE_MANIFEST"

if [[ "$DRY_RUN" == "1" ]]; then
  print "PUBLISH DRY RUN PASS"
  print "MODE: promote"
  print "TAG: $RELEASE_TAG"
  print "VERSION: $VERSION ($BUILD)"
  exit 0
fi

generate_stable_promotion
gh release upload "$RELEASE_TAG" "$STABLE_PROMOTION" --repo "$REPOSITORY" --clobber
gh release edit "$RELEASE_TAG" --repo "$REPOSITORY" --prerelease=false --latest

RELEASE_STATE="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" --jq '[.draft, .prerelease] | @tsv')"
test "$RELEASE_STATE" = $'false\tfalse'
test "$(gh api "repos/$REPOSITORY/releases/latest" --jq .tag_name)" = "$RELEASE_TAG"
curl -fsSL "https://github.com/$REPOSITORY/releases/latest/download/appcast.xml" -o "$WORK_DIR/latest-appcast.xml"
/usr/bin/cmp -s "$DOWNLOAD_DIR/appcast.xml" "$WORK_DIR/latest-appcast.xml"
curl -fsSL "https://github.com/$REPOSITORY/releases/latest/download/appcast-intel.xml" -o "$WORK_DIR/latest-appcast-intel.xml"
/usr/bin/cmp -s "$DOWNLOAD_DIR/appcast-intel.xml" "$WORK_DIR/latest-appcast-intel.xml"
verify_stable_download_redirect
print "RELEASE PROMOTION PASS: https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"
