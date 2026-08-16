#!/bin/zsh
set -euo pipefail
umask 022

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
PLIST="$ROOT/Resources/Info.plist"
REPOSITORY="HD838A/remote-mic-app"
MODE="${1:-}"
DRY_RUN="${DRY_RUN:-0}"
PUBLIC_DOWNLOAD_CONCURRENCY="${PUBLIC_DOWNLOAD_CONCURRENCY:-4}"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-L3QHLDRPAY}"
PLIST_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
PLIST_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PLIST")"
REQUESTED_RELEASE_TAG="${RELEASE_TAG:-}"
VERSION="$PLIST_VERSION"
BUILD="$PLIST_BUILD"

APP="$OUTPUT_DIR/Remote Mic.app"
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
PUBLIC_PAYLOAD_ASSET_COUNT=11
PUBLIC_RELEASE_ASSET_COUNT=12

if [[ "$#" -ne 1 || ( "$MODE" != "prerelease" && "$MODE" != "promote" ) ]]; then
  print -u2 "usage: $0 prerelease|promote"
  exit 1
fi
case "$DRY_RUN" in
  0|1) ;;
  *) print -u2 "DRY_RUN must be 0 or 1"; exit 1 ;;
esac
if ! print -r -- "$PUBLIC_DOWNLOAD_CONCURRENCY" | rg -q '^[1-9][0-9]*$' || \
    (( PUBLIC_DOWNLOAD_CONCURRENCY > 8 )); then
  print -u2 "PUBLIC_DOWNLOAD_CONCURRENCY must be between 1 and 8"
  exit 1
fi
if [[ "$EXPECTED_DEVELOPER_TEAM_ID" != "L3QHLDRPAY" ]]; then
  print -u2 "refusing to publish for an unexpected Apple Developer Team"
  exit 1
fi
if [[ "$MODE" == "prerelease" ]]; then
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
if ! print -r -- "$RELEASE_TAG" | rg -q '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
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

WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-publish-release.XXXXXX)"
STAGING_DIR="$WORK_DIR/upload"
DOWNLOAD_DIR="$WORK_DIR/download"
CDN_DOWNLOAD_DIR="$WORK_DIR/cdn-download"
RELEASE_NOTES="$WORK_DIR/release-notes.md"
CANDIDATE_PROVENANCE="$STAGING_DIR/candidate-provenance.json"
STABLE_PROMOTION="$WORK_DIR/stable-promotion.json"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remotemic-publish-release.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected publish work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

/bin/mkdir -p "$STAGING_DIR" "$DOWNLOAD_DIR" "$CDN_DOWNLOAD_DIR"

verify_update_zip() {
  local archive="$1"
  local variant="$2"
  local extract_dir="$WORK_DIR/verify-$variant-update-zip"
  /bin/mkdir -p "$extract_dir"
  /usr/bin/ditto -x -k "$archive" "$extract_dir"
  if [[ "$variant" == "intel" ]]; then
    RELEASE_VARIANT=intel "$ROOT/scripts/verify-app.sh" "$extract_dir/Remote Mic.app"
  else
    "$ROOT/scripts/verify-app.sh" "$extract_dir/Remote Mic.app"
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
  "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall
  "$ROOT/scripts/verify-dmg.sh" "$DMG"
  RELEASE_VARIANT=intel "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INTEL_UNINSTALL_PACKAGE" uninstall
  RELEASE_VARIANT=intel "$ROOT/scripts/verify-dmg.sh" "$INTEL_DMG"

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
    ' "$ROOT/Resources/zh-Hans.lproj/ReleaseHistory.md"
  } > "$RELEASE_NOTES"

  rg -q '^- ' "$RELEASE_NOTES"

  if rg -i -q \
    '((连续|连点|点击|轻点).{0,24}(版本号|当前版本).{0,24}(次|隐藏|入口))|((tap|click).{0,24}(version|build).{0,24}(times|hidden|secret|invite|enrollment))|(隐藏入口|秘密手势|secret gesture|hidden entry|invitation-code entry)' \
    "$ROOT/Resources/zh-Hans.lproj/ReleaseHistory.md" \
    "$ROOT/Resources/en.lproj/ReleaseHistory.md" \
    "$RELEASE_NOTES"; then
    print -u2 "release notes contain an internal trigger or confidential enrollment detail"
    exit 1
  fi
}

generate_candidate_provenance() {
  local branch head_commit base_main_commit payload_json_file file_path file_name file_size file_sha
  branch="$(git symbolic-ref --quiet --short HEAD)"
  head_commit="$(git rev-parse HEAD)"
  base_main_commit="$(git rev-parse HEAD^)"
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
    '{
      schemaVersion: 2,
      repository: $repository,
      candidateBranch: $candidateBranch,
      tag: $tag,
      tagCommit: $tagCommit,
      baseMainCommit: $baseMainCommit,
      version: $version,
      build: $build,
      payloadAssets: .
    }' "$payload_json_file" > "$CANDIDATE_PROVENANCE"

  test "$(jq '.payloadAssets | length' "$CANDIDATE_PROVENANCE")" = \
    "$PUBLIC_PAYLOAD_ASSET_COUNT"
}

verify_candidate_source() {
  cd "$ROOT"
  if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 "refusing to publish from a dirty worktree"
    exit 1
  fi

  "$ROOT/scripts/verify-preview-branch.sh"

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
  cd "$ROOT"
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

require_supported_payload_asset_count() {
  case "$1" in
    11|14|16) ;;
    *)
      print -u2 "unsupported release payload asset count: $1"
      return 1
      ;;
  esac
}

require_supported_release_asset_count() {
  case "$1" in
    12|15|17) ;;
    *)
      print -u2 "unsupported public release asset count: $1"
      return 1
      ;;
  esac
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
  local manifest_file="$WORK_DIR/$label-assets.txt"
  local source_file asset_name downloaded_file source_sha downloaded_sha expected_count

  /bin/mkdir -p "$destination_dir"
  test "$(/usr/bin/find "$destination_dir" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "0"
  : > "$manifest_file"
  for source_file in "$source_dir"/*(.N); do
    print -r -- "${source_file:t}" >> "$manifest_file"
  done
  LC_ALL=C /usr/bin/sort -o "$manifest_file" "$manifest_file"
  expected_count="$(/usr/bin/wc -l < "$manifest_file" | /usr/bin/tr -d ' ')"
  require_supported_release_asset_count "$expected_count"

  download_assets_from_manifest "$manifest_file" "$destination_dir" \
    "$download_prefix" "$label"

  for source_file in "$source_dir"/*; do
    asset_name="${source_file:t}"
    downloaded_file="$destination_dir/$asset_name"
    test -f "$downloaded_file"
    /usr/bin/cmp -s "$source_file" "$downloaded_file"
    source_sha="$(/usr/bin/shasum -a 256 "$source_file" | /usr/bin/awk '{ print $1 }')"
    downloaded_sha="$(/usr/bin/shasum -a 256 "$downloaded_file" | /usr/bin/awk '{ print $1 }')"
    test "$source_sha" = "$downloaded_sha"
    print "$label COMPARE PASS: $asset_name $downloaded_sha"
  done
  test "$(/usr/bin/find "$destination_dir" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = \
    "$expected_count"
}

download_release_assets() {
  local manifest_file="$WORK_DIR/github-origin-assets.txt"
  local expected_count
  /bin/mkdir -p "$DOWNLOAD_DIR"
  test "$(/usr/bin/find "$DOWNLOAD_DIR" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "0"
  gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" \
    --jq '.assets[].name' | LC_ALL=C /usr/bin/sort > "$manifest_file"
  expected_count="$(/usr/bin/wc -l < "$manifest_file" | /usr/bin/tr -d ' ')"
  require_supported_release_asset_count "$expected_count"
  download_assets_from_manifest "$manifest_file" "$DOWNLOAD_DIR" \
    "$GITHUB_DOWNLOAD_PREFIX" github-origin
  test "$(/usr/bin/find "$DOWNLOAD_DIR" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = \
    "$expected_count"
}

verify_cdn_assets() {
  local source_dir="$1"
  download_and_compare_assets "$source_dir" "$CDN_DOWNLOAD_DIR" \
    "$CDN_DOWNLOAD_PREFIX" cdn

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
    '(.schemaVersion == 1 or .schemaVersion == 2) and
     .repository == $repository and .tag == $tag and
     .version == $version and .build == $build and
     .candidateBranch == ("release/pre-" + $tag) and
     (.tagCommit | test("^[0-9a-f]{40}$")) and
     (if .schemaVersion == 2 then (.baseMainCommit | test("^[0-9a-f]{40}$")) else true end) and
     ((.payloadAssets | length) == 11 or
      (.payloadAssets | length) == 14 or
      (.payloadAssets | length) == 16)' "$provenance" >/dev/null
  if [[ "$VERSION" != "${RELEASE_TAG#v}" || ! "$BUILD" =~ '^[0-9]+$' ]]; then
    print -u2 "candidate provenance version/build does not match $RELEASE_TAG"
    exit 1
  fi

  local schema_version tag_commit base_main_commit candidate_branch remote_branch_commit asset_name expected_size expected_sha file_path actual_size actual_sha
  schema_version="$(jq -r '.schemaVersion' "$provenance")"
  require_supported_payload_asset_count "$(jq '.payloadAssets | length' "$provenance")"
  tag_commit="$(jq -r '.tagCommit' "$provenance")"
  candidate_branch="$(jq -r '.candidateBranch' "$provenance")"
  if [[ "$tag_commit" != "$(git rev-parse "$RELEASE_TAG^{commit}")" ]]; then
    print -u2 "candidate provenance tag commit does not match $RELEASE_TAG"
    exit 1
  fi
  remote_branch_commit="$(git ls-remote origin "refs/heads/$candidate_branch" | /usr/bin/awk 'NR == 1 { print $1 }')"
  if [[ "$remote_branch_commit" != "$tag_commit" ]]; then
    print -u2 "candidate branch is missing or no longer points to the tagged commit"
    exit 1
  fi
  if [[ "$schema_version" == "2" ]]; then
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
    "$GITHUB_DOWNLOAD_PREFIX" github-origin &
  github_pid="$!"
  verify_cdn_assets "$STAGING_DIR" &
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
  jq -e '((.payloadAssets | length) == 11 or
          (.payloadAssets | length) == 14 or
          (.payloadAssets | length) == 16)' \
    "$STABLE_PROMOTION" >/dev/null
}

if [[ "$MODE" == "prerelease" ]]; then
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
  test "$(/usr/bin/find "$STAGING_DIR" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = \
    "$PUBLIC_RELEASE_ASSET_COUNT"
  if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    print -u2 "release $RELEASE_TAG already exists"
    exit 1
  fi

  LATEST_BEFORE="$(gh api "repos/$REPOSITORY/releases/latest" --jq .tag_name)"
  gh release create "$RELEASE_TAG" \
    "$STAGING_DIR/${UPDATE_ZIP:t}" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Uninstaller.pkg" \
    "$STAGING_DIR/${DMG:t}" \
    "$STAGING_DIR/$SHARED_CHECKSUM_BASENAME" \
    "$STAGING_DIR/appcast.xml" \
    "$STAGING_DIR/${ZH_RELEASE_NOTES:t}" \
    "$STAGING_DIR/${EN_RELEASE_NOTES:t}" \
    "$STAGING_DIR/${INTEL_UPDATE_ZIP:t}" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Intel-Uninstaller.pkg" \
    "$STAGING_DIR/${INTEL_DMG:t}" \
    "$STAGING_DIR/appcast-intel.xml" \
    "$CANDIDATE_PROVENANCE" \
    --repo "$REPOSITORY" \
    --verify-tag \
    --prerelease \
    --latest=false \
    --title "Remote Mic $VERSION" \
    --notes-file "$RELEASE_NOTES"

  RELEASE_STATE="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" --jq '[.draft, .prerelease] | @tsv')"
  test "$RELEASE_STATE" = $'false\ttrue'
  test "$(gh api "repos/$REPOSITORY/releases/latest" --jq .tag_name)" = "$LATEST_BEFORE"
  download_and_compare_local_candidate
  gh workflow run release-guard.yml \
    --repo "$REPOSITORY" \
    --ref main \
    -f "tag=$RELEASE_TAG"
  print "PREVIEW MAIN RECORDING DISPATCHED: $RELEASE_TAG"
  print "PRE-RELEASE PUBLISH PASS: https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"
  exit 0
fi

verify_promotion_source
RELEASE_STATE="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" --jq '[.draft, .prerelease] | @tsv')"
test "$RELEASE_STATE" = $'false\ttrue'
download_release_assets
verify_downloaded_candidate
verify_cdn_assets "$DOWNLOAD_DIR"

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
