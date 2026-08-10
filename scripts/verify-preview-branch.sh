#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
PLIST="$ROOT/Resources/Info.plist"
BASE_REF="${PREVIEW_BASE_REF:-origin/main}"
BRANCH="${GITHUB_REF_NAME:-}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

cd "$ROOT"
if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git symbolic-ref --quiet --short HEAD)" || {
    print -u2 "preview validation requires a branch, not detached HEAD"
    exit 1
  }
fi
if [[ ! "$BRANCH" =~ '^release/pre-v([0-9]+\.[0-9]+\.[0-9]+)$' ]]; then
  print -u2 "preview branch must match release/pre-vX.Y.Z"
  exit 1
fi

BRANCH_VERSION="${match[1]}"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PLIST")"
if [[ "$VERSION" != "$BRANCH_VERSION" ]]; then
  print -u2 "preview branch version $BRANCH_VERSION does not match Info.plist $VERSION"
  exit 1
fi
if [[ ! "$BUILD" =~ '^[0-9]+$' ]]; then
  print -u2 "CFBundleVersion must be numeric"
  exit 1
fi

git fetch origin main --tags >/dev/null
git rev-parse --verify "$BASE_REF^{commit}" >/dev/null
if ! git merge-base --is-ancestor "$BASE_REF" HEAD; then
  print -u2 "preview candidate must contain the latest origin/main"
  exit 1
fi
if git merge-base --is-ancestor HEAD "$BASE_REF"; then
  print -u2 "preview candidate must add a release commit after origin/main"
  exit 1
fi

HEAD_COMMIT="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git ls-remote origin "refs/heads/$BRANCH" | /usr/bin/awk 'NR == 1 { print $1 }')"
if [[ "$REMOTE_HEAD" != "$HEAD_COMMIT" ]]; then
  print -u2 "preview branch HEAD must already be pushed to origin"
  exit 1
fi

PREVIOUS_TAG="$(
  git for-each-ref --sort=-version:refname --format='%(refname:short)' 'refs/tags/v[0-9]*' |
    while IFS= read -r tag_name; do
      [[ "$tag_name" == "v$VERSION" ]] && continue
      print -r -- "$tag_name"
      break
    done
)"
if [[ -z "$PREVIOUS_TAG" ]]; then
  print -u2 "no previous macOS version tag is available"
  exit 1
fi

PREVIOUS_VERSION="${PREVIOUS_TAG#v}"
autoload -Uz is-at-least
if [[ "$VERSION" == "$PREVIOUS_VERSION" ]] || ! is-at-least "$PREVIOUS_VERSION" "$VERSION"; then
  print -u2 "preview version $VERSION must be greater than $PREVIOUS_VERSION"
  exit 1
fi

WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-preview-branch.XXXXXX)"
cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remotemic-preview-branch.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected preview validation path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

git show "$PREVIOUS_TAG:Resources/Info.plist" > "$WORK_DIR/previous-Info.plist"
PREVIOUS_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$WORK_DIR/previous-Info.plist")"
if [[ ! "$PREVIOUS_BUILD" =~ '^[0-9]+$' ]] || (( BUILD <= PREVIOUS_BUILD )); then
  print -u2 "CFBundleVersion $BUILD must be greater than $PREVIOUS_BUILD from $PREVIOUS_TAG"
  exit 1
fi

git show "$BASE_REF:Resources/Info.plist" > "$WORK_DIR/base-Info.plist"
/bin/cp "$PLIST" "$WORK_DIR/candidate-Info.plist"
for plist_copy in "$WORK_DIR/base-Info.plist" "$WORK_DIR/candidate-Info.plist"; do
  /usr/bin/plutil -remove CFBundleShortVersionString "$plist_copy"
  /usr/bin/plutil -remove CFBundleVersion "$plist_copy"
done
if ! /usr/bin/cmp -s "$WORK_DIR/base-Info.plist" "$WORK_DIR/candidate-Info.plist"; then
  print -u2 "preview candidate may change only version/build fields in Resources/Info.plist"
  exit 1
fi

CHANGED_FILES=("${(@f)$(git diff --name-only "$BASE_REF"..HEAD)}")
if [[ -z "${CHANGED_FILES[1]:-}" ]]; then
  print -u2 "preview candidate has no release metadata changes"
  exit 1
fi
for changed_file in "${CHANGED_FILES[@]}"; do
  case "$changed_file" in
    Resources/Info.plist|\
    Resources/en.lproj/ReleaseHistory.md|\
    Resources/zh-Hans.lproj/ReleaseHistory.md|\
    Testing/*.md)
      ;;
    *)
      print -u2 "preview candidate contains a non-release change: $changed_file"
      print -u2 "merge product changes into main before creating the candidate branch"
      exit 1
      ;;
  esac
done

for release_history in \
  Resources/zh-Hans.lproj/ReleaseHistory.md \
  Resources/en.lproj/ReleaseHistory.md; do
  if ! print -l -- "${CHANGED_FILES[@]}" | rg -Fxq "$release_history" || \
     ! rg -Fq "## $VERSION" "$release_history"; then
    print -u2 "preview candidate requires a $VERSION entry in $release_history"
    exit 1
  fi
done

git diff --check "$BASE_REF"..HEAD
if git diff "$BASE_REF"..HEAD | \
   rg -n '^\+.*(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|MATCH_PASSWORD=|APPLE_APPLICATION_SPECIFIC_PASSWORD=|AuthKey_[A-Z0-9]+\.p8)'; then
  print -u2 "preview candidate contains a possible plaintext credential"
  exit 1
fi

print "PREVIEW BRANCH PASS"
print "BRANCH: $BRANCH"
print "VERSION: $VERSION ($BUILD)"
print "BASE: $(git rev-parse "$BASE_REF")"
print "HEAD: $HEAD_COMMIT"
