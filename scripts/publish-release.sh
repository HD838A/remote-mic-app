#!/bin/zsh
set -euo pipefail
umask 022

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
PLIST="$ROOT/Resources/Info.plist"
REPOSITORY="HD838A/remote-mic-app"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PLIST")"
RELEASE_TAG="${RELEASE_TAG:-v$VERSION}"
MODE="${1:-}"
DRY_RUN="${DRY_RUN:-0}"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-L3QHLDRPAY}"

APP="$OUTPUT_DIR/Remote Mic.app"
INSTALL_PACKAGE="$OUTPUT_DIR/Install Remote Mic.pkg"
UNINSTALL_PACKAGE="$OUTPUT_DIR/Uninstall Remote Mic.pkg"
DMG="$OUTPUT_DIR/Remote-Mic-$VERSION.dmg"
DMG_CHECKSUM="$DMG.sha256"
UPDATE_ZIP="$OUTPUT_DIR/Remote-Mic-$VERSION.zip"
APPCAST="$OUTPUT_DIR/appcast.xml"
DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/"

if [[ "$#" -ne 1 || \
      ( "$MODE" != "prerelease" && "$MODE" != "promote" && "$MODE" != "release" ) ]]; then
  print -u2 "usage: $0 prerelease|promote|release"
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
if ! print -r -- "$RELEASE_TAG" | rg -q '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
  print -u2 "RELEASE_TAG must be a version tag such as v1.5.0 or v1.5.0-rc.1"
  exit 1
fi
for command in cmp curl gh git plutil rg shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command"
    exit 1
  }
done

WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-publish-release.XXXXXX)"
STAGING_DIR="$WORK_DIR/upload"
DOWNLOAD_DIR="$WORK_DIR/download"
RELEASE_NOTES="$WORK_DIR/release-notes.md"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remotemic-publish-release.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected publish work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

/bin/mkdir -p "$STAGING_DIR" "$DOWNLOAD_DIR"

verify_local_artifacts() {
  test -d "$APP"
  test -f "$INSTALL_PACKAGE"
  test -f "$UNINSTALL_PACKAGE"
  test -f "$DMG"
  test -f "$DMG_CHECKSUM"
  test -f "$UPDATE_ZIP"
  test -f "$APPCAST"

  export EXPECTED_DEVELOPER_TEAM_ID REQUIRE_DEVELOPER_ID_SIGNING=1 REQUIRE_NOTARIZATION=1
  "$ROOT/scripts/verify-app.sh" "$APP"
  "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install
  "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall
  "$ROOT/scripts/verify-dmg.sh" "$DMG"

  rg -Fq "url=\"$DOWNLOAD_PREFIX${UPDATE_ZIP:t}\"" "$APPCAST"
  rg -Fq "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST"
  rg -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST"
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

  cmp -s "$INSTALL_PACKAGE" "$STAGING_DIR/Remote-Mic-$VERSION-Installer.pkg"
  cmp -s "$UNINSTALL_PACKAGE" "$STAGING_DIR/Remote-Mic-$VERSION-Uninstaller.pkg"
  cmp -s "$DMG" "$STAGING_DIR/${DMG:t}"
  cmp -s "$DMG_CHECKSUM" "$STAGING_DIR/${DMG_CHECKSUM:t}"
  cmp -s "$UPDATE_ZIP" "$STAGING_DIR/${UPDATE_ZIP:t}"
  cmp -s "$APPCAST" "$STAGING_DIR/appcast.xml"
}

generate_release_notes() {
  local previous_tag generated_notes target_commit
  local api_arguments

  target_commit="$(git rev-parse "$RELEASE_TAG^{commit}")"
  previous_tag="$(git describe --tags --abbrev=0 "$RELEASE_TAG^" 2>/dev/null || true)"
  api_arguments=(
    "repos/$REPOSITORY/releases/generate-notes"
    -X POST
    -f "tag_name=$RELEASE_TAG"
    -f "target_commitish=$target_commit"
  )
  if [[ -n "$previous_tag" ]]; then
    api_arguments+=(-f "previous_tag_name=$previous_tag")
  fi
  generated_notes="$(gh api "${api_arguments[@]}" --jq .body)"

  {
    print "## 更新内容"
    print
    if [[ -n "$previous_tag" ]]; then
      git log --format='- %s (`%h`)' "$previous_tag..$RELEASE_TAG"
    else
      git log -1 --format='- %s (`%h`)' "$RELEASE_TAG"
    fi
    if [[ -n "$generated_notes" ]]; then
      print
      print -r -- "$generated_notes"
    fi
  } > "$RELEASE_NOTES"

  rg -q '^- ' "$RELEASE_NOTES"
}

verify_source_identity() {
  cd "$ROOT"
  if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 "refusing to publish from a dirty worktree"
    exit 1
  fi

  local head_commit branch remote_branch_commit local_tag_commit remote_tag_commit
  head_commit="$(git rev-parse HEAD)"
  branch="$(git symbolic-ref --quiet --short HEAD)" || {
    print -u2 "refusing to publish from detached HEAD"
    exit 1
  }
  remote_branch_commit="$(git ls-remote origin "refs/heads/$branch" | awk 'NR == 1 { print $1 }')"
  if [[ "$remote_branch_commit" != "$head_commit" ]]; then
    print -u2 "current branch must be pushed to origin before publication"
    exit 1
  fi

  local_tag_commit="$(git rev-parse "$RELEASE_TAG^{commit}" 2>/dev/null)" || {
    print -u2 "local tag $RELEASE_TAG is missing"
    exit 1
  }
  if [[ "$local_tag_commit" != "$head_commit" ]]; then
    print -u2 "local tag $RELEASE_TAG does not point to HEAD"
    exit 1
  fi
  remote_tag_commit="$(git ls-remote origin "refs/tags/$RELEASE_TAG^{}" | awk 'NR == 1 { print $1 }')"
  if [[ -z "$remote_tag_commit" ]]; then
    remote_tag_commit="$(git ls-remote origin "refs/tags/$RELEASE_TAG" | awk 'NR == 1 { print $1 }')"
  fi
  if [[ "$remote_tag_commit" != "$head_commit" ]]; then
    print -u2 "remote tag $RELEASE_TAG must point to HEAD before publication"
    exit 1
  fi
}

download_and_compare() {
  /bin/rm -rf -- "$DOWNLOAD_DIR"
  /bin/mkdir -p "$DOWNLOAD_DIR"
  gh release download "$RELEASE_TAG" --repo "$REPOSITORY" --dir "$DOWNLOAD_DIR"

  local expected downloaded
  for expected in "$STAGING_DIR"/*; do
    downloaded="$DOWNLOAD_DIR/${expected:t}"
    test -f "$downloaded"
    cmp -s "$expected" "$downloaded"
  done
  test "$(find "$DOWNLOAD_DIR" -type f | wc -l | tr -d ' ')" = "6"

  curl -fsSL "${DOWNLOAD_PREFIX}appcast.xml" -o "$WORK_DIR/tag-appcast.xml"
  cmp -s "$STAGING_DIR/appcast.xml" "$WORK_DIR/tag-appcast.xml"
}

verify_local_artifacts
stage_assets

if [[ "$DRY_RUN" == "1" ]]; then
  if [[ "$MODE" == "prerelease" || "$MODE" == "release" ]]; then
    generate_release_notes
    print "RELEASE NOTES:"
    /bin/cat "$RELEASE_NOTES"
  fi
  print "PUBLISH DRY RUN PASS"
  print "MODE: $MODE"
  print "TAG: $RELEASE_TAG"
  print "VERSION: $VERSION ($BUILD)"
  exit 0
fi

verify_source_identity

if [[ "$MODE" == "prerelease" || "$MODE" == "release" ]]; then
  if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    print -u2 "release $RELEASE_TAG already exists"
    exit 1
  fi

  generate_release_notes
  LATEST_BEFORE="$(gh api "repos/$REPOSITORY/releases/latest" --jq .tag_name)"
  gh release create "$RELEASE_TAG" \
    "$STAGING_DIR/${UPDATE_ZIP:t}" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Installer.pkg" \
    "$STAGING_DIR/Remote-Mic-$VERSION-Uninstaller.pkg" \
    "$STAGING_DIR/${DMG:t}" \
    "$STAGING_DIR/${DMG_CHECKSUM:t}" \
    "$STAGING_DIR/appcast.xml" \
    --repo "$REPOSITORY" \
    --verify-tag \
    --prerelease \
    --latest=false \
    --title "Remote Mic $VERSION" \
    --notes-file "$RELEASE_NOTES"

  RELEASE_STATE="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" \
    --jq '[.draft, .prerelease] | @tsv')"
  test "$RELEASE_STATE" = $'false\ttrue'
  test "$(gh api "repos/$REPOSITORY/releases/latest" --jq .tag_name)" = "$LATEST_BEFORE"
  download_and_compare
  print "PRE-RELEASE PUBLISH PASS: https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"

  if [[ "$MODE" == "prerelease" ]]; then
    exit 0
  fi
fi

if [[ "$MODE" == "promote" ]]; then
  RELEASE_STATE="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" \
    --jq '[.draft, .prerelease] | @tsv')"
  test "$RELEASE_STATE" = $'false\ttrue'
  download_and_compare
fi

gh release edit "$RELEASE_TAG" \
  --repo "$REPOSITORY" \
  --prerelease=false \
  --latest

RELEASE_STATE="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" \
  --jq '[.draft, .prerelease] | @tsv')"
test "$RELEASE_STATE" = $'false\tfalse'
test "$(gh api "repos/$REPOSITORY/releases/latest" --jq .tag_name)" = "$RELEASE_TAG"
curl -fsSL "https://github.com/$REPOSITORY/releases/latest/download/appcast.xml" \
  -o "$WORK_DIR/latest-appcast.xml"
cmp -s "$STAGING_DIR/appcast.xml" "$WORK_DIR/latest-appcast.xml"
print "RELEASE PROMOTION PASS: https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"
