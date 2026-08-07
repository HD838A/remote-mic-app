#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
PLIST="$ROOT/Resources/Info.plist"
REPOSITORY="HD838A/remote-mic-app"
EXPECTED_TEAM_ID="L3QHLDRPAY"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PLIST")"
RELEASE_TAG="v$VERSION"
SECRETS_REPO="${REMOTEMIC_NOTARY_SECRETS_REPO:-${ROOT:h}/remotemic-notary-secrets}"
SECRETS_VALIDATOR="$SECRETS_REPO/skills/remotemic-notary-secrets/scripts/validate-notary-secrets-repo.sh"
ISOLATED_KEYCHAIN_RUNNER="$SECRETS_REPO/run-with-isolated-release-keychain.sh"
SPARKLE_KEY="${SPARKLE_PRIVATE_KEY_FILE:-$HOME/.config/RemoteMic/sparkle-ed25519.key}"
PRODUCTION_ENV="$ROOT/Apps/MobileWeb/.private/production.env"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-fast-release.XXXXXX)"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remotemic-fast-release.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected fast-release path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: ALLOW_ISOLATED_RELEASE_KEYCHAIN=1 $0"
  exit 1
fi
if [[ "${ALLOW_ISOLATED_RELEASE_KEYCHAIN:-0}" != "1" ]]; then
  print -u2 "Set ALLOW_ISOLATED_RELEASE_KEYCHAIN=1 to authorize the temporary release Keychain"
  exit 1
fi
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || ! "$BUILD" =~ '^[0-9]+$' ]]; then
  print -u2 "fast release requires a stable semantic version and numeric build"
  exit 1
fi
for command in cmp curl gh git plutil rg xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command"
    exit 1
  }
done
for required_file in \
  "$SECRETS_VALIDATOR" \
  "$ISOLATED_KEYCHAIN_RUNNER" \
  "$SPARKLE_KEY" \
  "$PRODUCTION_ENV"; do
  if [[ ! -r "$required_file" ]]; then
    print -u2 "Required local release file is unavailable: $required_file"
    exit 1
  fi
done

cd "$ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "fast release requires a clean committed worktree"
  exit 1
fi
BRANCH="$(git symbolic-ref --quiet --short HEAD)" || {
  print -u2 "fast release requires a branch, not detached HEAD"
  exit 1
}
if [[ "$BRANCH" != "main" ]]; then
  print -u2 "fast release is restricted to main"
  exit 1
fi

git fetch origin main --tags
if ! git merge-base --is-ancestor origin/main HEAD; then
  print -u2 "local main does not contain the current origin/main"
  exit 1
fi

LATEST_TAG="$(gh api "repos/$REPOSITORY/releases/latest" --jq .tag_name)"
if ! git rev-parse "$LATEST_TAG^{commit}" >/dev/null 2>&1; then
  print -u2 "latest release tag is unavailable locally: $LATEST_TAG"
  exit 1
fi
if [[ "$LATEST_TAG" == "$RELEASE_TAG" ]]; then
  print -u2 "Resources/Info.plist must be bumped beyond $LATEST_TAG"
  exit 1
fi
if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  print -u2 "release $RELEASE_TAG already exists"
  exit 1
fi

LATEST_APPCAST="$WORK_DIR/latest-appcast.xml"
curl -fsSL "https://github.com/$REPOSITORY/releases/latest/download/appcast.xml" \
  -o "$LATEST_APPCAST"
LATEST_BUILD="$(/usr/bin/sed -n 's:.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*:\1:p' \
  "$LATEST_APPCAST" | /usr/bin/head -n 1)"
if [[ ! "$LATEST_BUILD" =~ '^[0-9]+$' ]] || (( BUILD <= LATEST_BUILD )); then
  print -u2 "CFBundleVersion must be greater than the latest release build $LATEST_BUILD"
  exit 1
fi

CHANGED_FILES=("${(@f)$(git diff --name-only "$LATEST_TAG^{commit}"..HEAD)}")
if [[ -z "${CHANGED_FILES[1]:-}" ]]; then
  print -u2 "no changes exist after $LATEST_TAG"
  exit 1
fi
for changed_file in "${CHANGED_FILES[@]}"; do
  case "$changed_file" in
    Resources/Info.plist|\
    Resources/*.lproj/Localizable.strings|\
    Resources/*.lproj/ReleaseHistory.md|\
    Resources/*.lproj/Glossary.md|\
    Resources/首次安装说明*.md|\
    README.md|README.en.md|\
    TECHNICAL.md|TECHNICAL.en.md|\
    TROUBLESHOOTING.md|TROUBLESHOOTING.en.md|\
    COPYRIGHT.md|COPYRIGHT.en.md|\
    LICENSE.md|LOGO-LICENSE.md|THIRD_PARTY_NOTICES.md|TODO.md)
      ;;
    *)
      print -u2 "fast release rejected non-document/resource change: $changed_file"
      print -u2 "Use the full candidate release workflow for this version"
      exit 1
      ;;
  esac
done

git diff --check "$LATEST_TAG^{commit}"..HEAD
if git diff "$LATEST_TAG^{commit}"..HEAD | \
   rg -n '^\+.*(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|MATCH_PASSWORD=|APPLE_APPLICATION_SPECIFIC_PASSWORD=|AuthKey_[A-Z0-9]+\.p8)'; then
  print -u2 "fast release rejected a possible plaintext credential in the release diff"
  exit 1
fi
for release_history in \
  Resources/zh-Hans.lproj/ReleaseHistory.md \
  Resources/en.lproj/ReleaseHistory.md; do
  if ! print -l -- "${CHANGED_FILES[@]}" | rg -Fxq "$release_history" || \
     ! rg -Fq "## $VERSION" "$release_history"; then
    print -u2 "fast release requires a $VERSION entry in $release_history"
    exit 1
  fi
done

OLD_PLIST="$WORK_DIR/previous-Info.plist"
CURRENT_PLIST="$WORK_DIR/current-Info.plist"
git show "$LATEST_TAG:Resources/Info.plist" > "$OLD_PLIST"
/bin/cp "$PLIST" "$CURRENT_PLIST"
for plist_copy in "$OLD_PLIST" "$CURRENT_PLIST"; do
  /usr/bin/plutil -remove CFBundleShortVersionString "$plist_copy"
  /usr/bin/plutil -remove CFBundleVersion "$plist_copy"
done
if ! cmp -s "$OLD_PLIST" "$CURRENT_PLIST"; then
  print -u2 "fast release allows only version/build changes in Resources/Info.plist"
  exit 1
fi

"$SECRETS_VALIDATOR" "$SECRETS_REPO"
xcrun swift test
git push origin main

SPARKLE_PRIVATE_KEY_FILE="$SPARKLE_KEY" \
PARALLEL_PACKAGE_NOTARIZATION=1 \
EXPECTED_DEVELOPER_TEAM_ID="$EXPECTED_TEAM_ID" \
ALLOW_ISOLATED_RELEASE_KEYCHAIN=1 \
  "$ISOLATED_KEYCHAIN_RUNNER" -- "$ROOT/scripts/notarize-release.sh"

HEAD_COMMIT="$(git rev-parse HEAD)"
if git show-ref --verify --quiet "refs/tags/$RELEASE_TAG"; then
  if [[ "$(git rev-parse "$RELEASE_TAG^{commit}")" != "$HEAD_COMMIT" ]]; then
    print -u2 "local tag $RELEASE_TAG points to another commit"
    exit 1
  fi
else
  git tag -a "$RELEASE_TAG" -m "Remote Mic $VERSION"
fi

REMOTE_TAG_COMMIT="$(git ls-remote origin "refs/tags/$RELEASE_TAG^{}" | \
  /usr/bin/awk 'NR == 1 { print $1 }')"
if [[ -z "$REMOTE_TAG_COMMIT" ]]; then
  git push origin "refs/tags/$RELEASE_TAG"
elif [[ "$REMOTE_TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
  print -u2 "remote tag $RELEASE_TAG points to another commit"
  exit 1
fi

SPARKLE_PRIVATE_KEY_FILE="$SPARKLE_KEY" \
EXPECTED_DEVELOPER_TEAM_ID="$EXPECTED_TEAM_ID" \
  "$ROOT/scripts/publish-release.sh" release

print "FAST RELEASE PASS: https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"
