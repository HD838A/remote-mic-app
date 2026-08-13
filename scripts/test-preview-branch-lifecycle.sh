#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
VERIFIER="$ROOT/scripts/verify-preview-branch.sh"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-preview-lifecycle.XXXXXX)"
REMOTE_REPO="$WORK_DIR/origin.git"
TEST_REPO="$WORK_DIR/repo"
FAKE_BIN="$WORK_DIR/bin"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remotemic-preview-lifecycle.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected preview lifecycle path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

/bin/mkdir -p \
  "$REMOTE_REPO" \
  "$TEST_REPO/scripts" \
  "$TEST_REPO/Resources/en.lproj" \
  "$TEST_REPO/Resources/zh-Hans.lproj" \
  "$FAKE_BIN"
git init --bare "$REMOTE_REPO" >/dev/null
git -C "$TEST_REPO" init -b main >/dev/null
git -C "$TEST_REPO" config user.name "Release Lifecycle Test"
git -C "$TEST_REPO" config user.email "release-lifecycle@example.invalid"
git -C "$TEST_REPO" remote add origin "$REMOTE_REPO"

/bin/cp "$VERIFIER" "$TEST_REPO/scripts/verify-preview-branch.sh"
/bin/chmod 755 "$TEST_REPO/scripts/verify-preview-branch.sh"
/bin/cp "$ROOT/Resources/Info.plist" "$TEST_REPO/Resources/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "1.8.14" \
  "$TEST_REPO/Resources/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "106" \
  "$TEST_REPO/Resources/Info.plist"
for locale in en zh-Hans; do
  print "## 1.8.14" > "$TEST_REPO/Resources/$locale.lproj/ReleaseHistory.md"
  print -- "- Previous preview" >> "$TEST_REPO/Resources/$locale.lproj/ReleaseHistory.md"
done
git -C "$TEST_REPO" add Resources scripts/verify-preview-branch.sh
git -C "$TEST_REPO" commit -m "main baseline" >/dev/null
git -C "$TEST_REPO" tag v1.8.14
git -C "$TEST_REPO" push -u origin main --tags >/dev/null

for tool_name in awk cmp grep mktemp plutil rm; do
  /bin/ln -s "/usr/bin/$tool_name" "$FAKE_BIN/$tool_name" 2>/dev/null || \
    /bin/ln -s "/bin/$tool_name" "$FAKE_BIN/$tool_name"
done
print '#!/bin/zsh' > "$FAKE_BIN/git"
print 'if [[ "$1" == "fetch" ]]; then exit 0; fi' >> "$FAKE_BIN/git"
print 'exec /usr/bin/git "$@"' >> "$FAKE_BIN/git"
/bin/chmod 755 "$FAKE_BIN/git"

prepare_candidate() {
  local branch="$1"
  local version="$2"
  local build="$3"
  local message="$4"
  git -C "$TEST_REPO" switch -c "$branch" >/dev/null
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$version" \
    "$TEST_REPO/Resources/Info.plist"
  /usr/bin/plutil -replace CFBundleVersion -string "$build" \
    "$TEST_REPO/Resources/Info.plist"
  for locale in en zh-Hans; do
    {
      print "## $version"
      print -- "- Candidate"
      print
      /bin/cat "$TEST_REPO/Resources/$locale.lproj/ReleaseHistory.md"
    } > "$WORK_DIR/$locale-release-history.md"
    /bin/cp "$WORK_DIR/$locale-release-history.md" \
      "$TEST_REPO/Resources/$locale.lproj/ReleaseHistory.md"
  done
  git -C "$TEST_REPO" add Resources
  git -C "$TEST_REPO" commit -m "$message" >/dev/null
  git -C "$TEST_REPO" push -u origin "$branch" >/dev/null
}

prepare_candidate "release/pre-v1.8.15" "1.8.15" "107" "prepare 1.8.15"
(
  cd "$TEST_REPO"
  GITHUB_REF_NAME="" PATH="$FAKE_BIN:/usr/bin:/bin" ./scripts/verify-preview-branch.sh
) > "$WORK_DIR/valid-output.txt"
/usr/bin/grep -Fq "PREVIEW BRANCH PASS" "$WORK_DIR/valid-output.txt"

prepare_candidate "release/pre-v1.8.16" "1.8.16" "108" "prepare 1.8.16"
if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME="" PATH="$FAKE_BIN:/usr/bin:/bin" ./scripts/verify-preview-branch.sh
) > "$WORK_DIR/chained-output.txt" 2>&1; then
  print -u2 "chained preview candidate unexpectedly passed"
  exit 1
fi
/usr/bin/grep -Fq "must exactly equal the latest origin/main" "$WORK_DIR/chained-output.txt"

print "PREVIEW BRANCH LIFECYCLE TEST PASS"
