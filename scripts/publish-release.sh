#!/bin/zsh
set -euo pipefail
umask 022

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
PLIST="$ROOT/Resources/Info.plist"
REPOSITORY="HD838A/remote-mic-app"
MODE="${1:-}"
DRY_RUN="${DRY_RUN:-0}"
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

if [[ "$#" -ne 1 || ( "$MODE" != "prerelease" && "$MODE" != "promote" ) ]]; then
  print -u2 "usage: $0 prerelease|promote"
  exit 1
fi
case "$DRY_RUN" in
  0|1) ;;
  *) print -u2 "DRY_RUN must be 0 or 1"; exit 1 ;;
esac
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

verify_local_artifacts() {
  test -d "$APP"
  test -f "$INSTALL_PACKAGE"
  test -f "$UNINSTALL_PACKAGE"
  test -f "$DMG"
  test -f "$DMG_CHECKSUM"
  test -f "$UPDATE_ZIP"
  test -f "$APPCAST"
  test -f "$ZH_RELEASE_NOTES"
  test -f "$EN_RELEASE_NOTES"
  test -f "$INTEL_INSTALL_PACKAGE"
  test -f "$INTEL_UNINSTALL_PACKAGE"
  test -f "$INTEL_DMG"
  test -f "$INTEL_DMG_CHECKSUM"
  test -f "$INTEL_UPDATE_ZIP"
  test -f "$INTEL_APPCAST"

  export EXPECTED_DEVELOPER_TEAM_ID REQUIRE_DEVELOPER_ID_SIGNING=1 REQUIRE_NOTARIZATION=1
  "$ROOT/scripts/verify-app.sh" "$APP"
  "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install
  "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall
  "$ROOT/scripts/verify-dmg.sh" "$DMG"
  RELEASE_VARIANT=intel "$ROOT/scripts/verify-app.sh" "$INTEL_OUTPUT_DIR/Remote Mic.app"
  RELEASE_VARIANT=intel "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INTEL_INSTALL_PACKAGE" install
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
  /usr/bin/ditto --norsrc --noqtn --noacl "$INSTALL_PACKAGE" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Installer.pkg"
  /usr/bin/ditto --norsrc --noqtn --noacl "$UNINSTALL_PACKAGE" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Uninstaller.pkg"
  /usr/bin/ditto --norsrc --noqtn --noacl "$DMG" "$STAGING_DIR/${DMG:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl "$DMG_CHECKSUM" "$STAGING_DIR/${DMG_CHECKSUM:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl "$UPDATE_ZIP" "$STAGING_DIR/${UPDATE_ZIP:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl "$APPCAST" "$STAGING_DIR/appcast.xml"
  /usr/bin/ditto --norsrc --noqtn --noacl \
    "$ZH_RELEASE_NOTES" "$STAGING_DIR/${ZH_RELEASE_NOTES:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl \
    "$EN_RELEASE_NOTES" "$STAGING_DIR/${EN_RELEASE_NOTES:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl "$INTEL_INSTALL_PACKAGE" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Intel-Installer.pkg"
  /usr/bin/ditto --norsrc --noqtn --noacl "$INTEL_UNINSTALL_PACKAGE" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Intel-Uninstaller.pkg"
  /usr/bin/ditto --norsrc --noqtn --noacl "$INTEL_DMG" "$STAGING_DIR/${INTEL_DMG:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl \
    "$INTEL_DMG_CHECKSUM" "$STAGING_DIR/${INTEL_DMG_CHECKSUM:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl \
    "$INTEL_UPDATE_ZIP" "$STAGING_DIR/${INTEL_UPDATE_ZIP:t}"
  /usr/bin/ditto --norsrc --noqtn --noacl "$INTEL_APPCAST" "$STAGING_DIR/appcast-intel.xml"

  /usr/bin/cmp -s "$INSTALL_PACKAGE" "$STAGING_DIR/Remote-Mic-$VERSION-Installer.pkg"
  /usr/bin/cmp -s "$UNINSTALL_PACKAGE" "$STAGING_DIR/Remote-Mic-$VERSION-Uninstaller.pkg"
  /usr/bin/cmp -s "$DMG" "$STAGING_DIR/${DMG:t}"
  /usr/bin/cmp -s "$DMG_CHECKSUM" "$STAGING_DIR/${DMG_CHECKSUM:t}"
  /usr/bin/cmp -s "$UPDATE_ZIP" "$STAGING_DIR/${UPDATE_ZIP:t}"
  /usr/bin/cmp -s "$APPCAST" "$STAGING_DIR/appcast.xml"
  /usr/bin/cmp -s "$ZH_RELEASE_NOTES" "$STAGING_DIR/${ZH_RELEASE_NOTES:t}"
  /usr/bin/cmp -s "$EN_RELEASE_NOTES" "$STAGING_DIR/${EN_RELEASE_NOTES:t}"
  /usr/bin/cmp -s "$INTEL_INSTALL_PACKAGE" "$STAGING_DIR/Remote-Mic-$VERSION-Intel-Installer.pkg"
  /usr/bin/cmp -s "$INTEL_UNINSTALL_PACKAGE" "$STAGING_DIR/Remote-Mic-$VERSION-Intel-Uninstaller.pkg"
  /usr/bin/cmp -s "$INTEL_DMG" "$STAGING_DIR/${INTEL_DMG:t}"
  /usr/bin/cmp -s "$INTEL_DMG_CHECKSUM" "$STAGING_DIR/${INTEL_DMG_CHECKSUM:t}"
  /usr/bin/cmp -s "$INTEL_UPDATE_ZIP" "$STAGING_DIR/${INTEL_UPDATE_ZIP:t}"
  /usr/bin/cmp -s "$INTEL_APPCAST" "$STAGING_DIR/appcast-intel.xml"
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
}

generate_candidate_provenance() {
  local branch head_commit payload_json_file file_path file_name file_size file_sha
  branch="$(git symbolic-ref --quiet --short HEAD)"
  head_commit="$(git rev-parse HEAD)"
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
    --arg version "$VERSION" \
    --arg build "$BUILD" \
    '{
      schemaVersion: 1,
      repository: $repository,
      candidateBranch: $candidateBranch,
      tag: $tag,
      tagCommit: $tagCommit,
      version: $version,
      build: $build,
      payloadAssets: .
    }' "$payload_json_file" > "$CANDIDATE_PROVENANCE"

  test "$(jq '.payloadAssets | length' "$CANDIDATE_PROVENANCE")" = "14"
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

download_release_assets() {
  /bin/rm -rf -- "$DOWNLOAD_DIR"
  /bin/mkdir -p "$DOWNLOAD_DIR"
  gh release download "$RELEASE_TAG" --repo "$REPOSITORY" --dir "$DOWNLOAD_DIR"
}

verify_cdn_assets() {
  local source_dir="$1"
  local source_file asset_name downloaded_file expected_count
  /bin/rm -rf -- "$CDN_DOWNLOAD_DIR"
  /bin/mkdir -p "$CDN_DOWNLOAD_DIR"

  expected_count=0
  for source_file in "$source_dir"/*; do
    asset_name="${source_file:t}"
    downloaded_file="$CDN_DOWNLOAD_DIR/$asset_name"
    curl --fail --silent --show-error --location \
      --retry 5 --retry-all-errors \
      "$CDN_DOWNLOAD_PREFIX$asset_name" \
      --output "$downloaded_file"
    /usr/bin/cmp -s "$source_file" "$downloaded_file"
    expected_count=$((expected_count + 1))
  done
  test "$(/usr/bin/find "$CDN_DOWNLOAD_DIR" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "$expected_count"

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
    '.schemaVersion == 1 and .repository == $repository and .tag == $tag and
     .version == $version and .build == $build and
     .candidateBranch == ("release/pre-" + $tag) and
     (.tagCommit | test("^[0-9a-f]{40}$")) and
     (.payloadAssets | length == 14)' "$provenance" >/dev/null
  if [[ "$VERSION" != "${RELEASE_TAG#v}" || ! "$BUILD" =~ '^[0-9]+$' ]]; then
    print -u2 "candidate provenance version/build does not match $RELEASE_TAG"
    exit 1
  fi

  local tag_commit candidate_branch remote_branch_commit asset_name expected_size expected_sha file_path actual_size actual_sha
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
  download_release_assets
  local expected downloaded
  for expected in "$STAGING_DIR"/*; do
    downloaded="$DOWNLOAD_DIR/${expected:t}"
    test -f "$downloaded"
    /usr/bin/cmp -s "$expected" "$downloaded"
  done
  test "$(/usr/bin/find "$DOWNLOAD_DIR" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "15"
  curl -fsSL "${GITHUB_DOWNLOAD_PREFIX}appcast.xml" -o "$WORK_DIR/tag-appcast.xml"
  /usr/bin/cmp -s "$STAGING_DIR/appcast.xml" "$WORK_DIR/tag-appcast.xml"
  curl -fsSL "${GITHUB_DOWNLOAD_PREFIX}appcast-intel.xml" -o "$WORK_DIR/tag-appcast-intel.xml"
  /usr/bin/cmp -s "$STAGING_DIR/appcast-intel.xml" "$WORK_DIR/tag-appcast-intel.xml"
  verify_downloaded_candidate
  verify_cdn_assets "$STAGING_DIR"
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
  test "$(jq '.payloadAssets | length' "$STABLE_PROMOTION")" = "14"
}

if [[ "$MODE" == "prerelease" ]]; then
  verify_local_artifacts
  stage_assets
  generate_release_notes
  generate_candidate_provenance

  if [[ "$DRY_RUN" == "1" ]]; then
    print "RELEASE NOTES:"
    /bin/cat "$RELEASE_NOTES"
    print "PUBLISH DRY RUN PASS"
    print "MODE: prerelease"
    print "TAG: $RELEASE_TAG"
    print "VERSION: $VERSION ($BUILD)"
    exit 0
  fi

  verify_candidate_source
  if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    print -u2 "release $RELEASE_TAG already exists"
    exit 1
  fi

  LATEST_BEFORE="$(gh api "repos/$REPOSITORY/releases/latest" --jq .tag_name)"
  gh release create "$RELEASE_TAG" \
    "$STAGING_DIR/${UPDATE_ZIP:t}" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Installer.pkg" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Uninstaller.pkg" \
    "$STAGING_DIR/${DMG:t}" \
    "$STAGING_DIR/${DMG_CHECKSUM:t}" \
    "$STAGING_DIR/appcast.xml" \
    "$STAGING_DIR/${ZH_RELEASE_NOTES:t}" \
    "$STAGING_DIR/${EN_RELEASE_NOTES:t}" \
    "$STAGING_DIR/${INTEL_UPDATE_ZIP:t}" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Intel-Installer.pkg" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Intel-Uninstaller.pkg" \
    "$STAGING_DIR/${INTEL_DMG:t}" \
    "$STAGING_DIR/${INTEL_DMG_CHECKSUM:t}" \
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
