#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
PLIST="$ROOT/Resources/Info.plist"
BASE_REF="origin/main"
BRANCH="${GITHUB_REF_NAME:-}"
ALLOW_FROZEN_BASE_MAIN="${ALLOW_FROZEN_BASE_MAIN:-0}"

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
  print -u2 "preview branch must be the single candidate branch release/pre-vX.Y.Z"
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
HEAD_COMMIT="$(git rev-parse HEAD)"
CURRENT_MAIN_COMMIT="$(git rev-parse "$BASE_REF")"
BASE_MAIN_COMMIT="$(git rev-parse HEAD^)"
PARENT_COUNT="$(git show -s --format='%P' HEAD | /usr/bin/awk '{ print NF }')"
if [[ "$PARENT_COUNT" != "1" ]]; then
  print -u2 "preview candidate must be one non-merge release commit after origin/main"
  exit 1
fi
if [[ "$BASE_MAIN_COMMIT" != "$CURRENT_MAIN_COMMIT" ]]; then
  if [[ "$ALLOW_FROZEN_BASE_MAIN" != "1" ]] || \
     ! git merge-base --is-ancestor "$BASE_MAIN_COMMIT" "$CURRENT_MAIN_COMMIT"; then
    print -u2 "preview candidate must be created from the current origin/main"
    print -u2 "a frozen candidate may remain valid only when its base is still an ancestor of main and the release pipeline is unchanged"
    exit 1
  fi
fi
if [[ "$(git rev-list --count "$BASE_MAIN_COMMIT"..HEAD)" != "1" ]]; then
  print -u2 "preview candidate must contain exactly one release metadata commit after its frozen base main"
  exit 1
fi

REMOTE_CANDIDATES="$(
  git ls-remote --heads origin 'refs/heads/release/pre-v*' |
    /usr/bin/awk -v exact="refs/heads/$BRANCH" \
      '$2 == exact || index($2, exact "-") == 1 { print $1 "\t" $2 }'
)"
REMOTE_CANDIDATE_COUNT="$(
  print -r -- "$REMOTE_CANDIDATES" |
    /usr/bin/awk 'NF { count += 1 } END { print count + 0 }'
)"
if [[ "$REMOTE_CANDIDATE_COUNT" != "1" ]]; then
  print -u2 "preview version v$VERSION must have exactly one remote candidate branch"
  print -u2 "remove no branch automatically; reconcile historical aliases before dispatch"
  exit 1
fi
REMOTE_HEAD="$(print -r -- "$REMOTE_CANDIDATES" | /usr/bin/awk 'NR == 1 { print $1 }')"
REMOTE_REF="$(print -r -- "$REMOTE_CANDIDATES" | /usr/bin/awk 'NR == 1 { print $2 }')"
if [[ "$REMOTE_REF" != "refs/heads/$BRANCH" || "$REMOTE_HEAD" != "$HEAD_COMMIT" ]]; then
  print -u2 "preview branch HEAD must be the sole exact candidate already pushed to origin"
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
  print -u2 "preview validation evidence retained at: $WORK_DIR"
}
trap cleanup EXIT

git show "$PREVIOUS_TAG:Resources/Info.plist" > "$WORK_DIR/previous-Info.plist"
PREVIOUS_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$WORK_DIR/previous-Info.plist")"
if [[ ! "$PREVIOUS_BUILD" =~ '^[0-9]+$' ]] || (( BUILD <= PREVIOUS_BUILD )); then
  print -u2 "CFBundleVersion $BUILD must be greater than $PREVIOUS_BUILD from $PREVIOUS_TAG"
  exit 1
fi

git show "$BASE_MAIN_COMMIT:Resources/Info.plist" > "$WORK_DIR/base-Info.plist"
/bin/cp "$PLIST" "$WORK_DIR/candidate-Info.plist"
for plist_copy in "$WORK_DIR/base-Info.plist" "$WORK_DIR/candidate-Info.plist"; do
  /usr/bin/plutil -remove CFBundleShortVersionString "$plist_copy"
  /usr/bin/plutil -remove CFBundleVersion "$plist_copy"
done
if ! /usr/bin/cmp -s "$WORK_DIR/base-Info.plist" "$WORK_DIR/candidate-Info.plist"; then
  print -u2 "preview candidate may change only version/build fields in Resources/Info.plist"
  exit 1
fi

CHANGED_FILES=("${(@f)$(git diff --name-only "$BASE_MAIN_COMMIT"..HEAD)}")
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
  if ! print -l -- "${CHANGED_FILES[@]}" | /usr/bin/grep -Fxq "$release_history" || \
     ! /usr/bin/grep -Fq "## $VERSION" "$release_history"; then
    print -u2 "preview candidate requires a $VERSION entry in $release_history"
    exit 1
  fi
done

if /usr/bin/grep -Ein \
  '((连续|连点|点击|轻点).{0,24}(版本号|当前版本).{0,24}(次|隐藏|入口))|((tap|click).{0,24}(version|build).{0,24}(times|hidden|secret|invite|enrollment))|(隐藏入口|秘密手势|secret gesture|hidden entry|invitation-code entry)' \
  Resources/zh-Hans.lproj/ReleaseHistory.md \
  Resources/en.lproj/ReleaseHistory.md; then
  print -u2 "release history contains an internal trigger or confidential enrollment detail"
  exit 1
fi

git diff --check "$BASE_MAIN_COMMIT"..HEAD
if git diff "$BASE_MAIN_COMMIT"..HEAD | \
   /usr/bin/grep -En '^\+.*(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|MATCH_PASSWORD=|APPLE_APPLICATION_SPECIFIC_PASSWORD=|AuthKey_[A-Z0-9]+\.p8)'; then
  print -u2 "preview candidate contains a possible plaintext credential"
  exit 1
fi

print "PREVIEW BRANCH PASS"
print "BRANCH: $BRANCH"
print "VERSION: $VERSION ($BUILD)"
print "BASE_MAIN_COMMIT: $BASE_MAIN_COMMIT"
print "HEAD: $HEAD_COMMIT"
