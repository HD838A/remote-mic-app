#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/sayall-prepare-preview-release-test.XXXXXX)"
ORIGIN="$WORK_DIR/origin.git"
CHECKOUT="$WORK_DIR/checkout"
BRANCH="$WORK_DIR/metadata"
FAKE_GH="$WORK_DIR/fake-gh"

cleanup() {
  local trash_root="$HOME/.Trash"
  local trash_target="$trash_root/sayall-prepare-preview-release-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$trash_root"
  [[ -d "$WORK_DIR" ]] && /bin/mv "$WORK_DIR" "$trash_target"
}
trap cleanup EXIT

/usr/bin/git init -q --bare "$ORIGIN"
/usr/bin/git clone -q "$ORIGIN" "$CHECKOUT"
/bin/mkdir -p "$CHECKOUT/Resources/zh-Hans.lproj" "$CHECKOUT/Resources/en.lproj" "$CHECKOUT/scripts"
/bin/cp "$ROOT/scripts/prepare-preview-release.sh" "$CHECKOUT/scripts/prepare-preview-release.sh"
/bin/cp "$ROOT/scripts/verify-preview-cdn-availability.sh" "$CHECKOUT/scripts/verify-preview-cdn-availability.sh"
/bin/chmod 755 "$CHECKOUT/scripts/prepare-preview-release.sh"
/bin/chmod 755 "$CHECKOUT/scripts/verify-preview-cdn-availability.sh"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.9.10</string>
<key>CFBundleVersion</key><string>139</string>
</dict></plist>' > "$CHECKOUT/Resources/Info.plist"
print -r -- '# History

## 1.9.10

- Previous.' > "$CHECKOUT/Resources/zh-Hans.lproj/ReleaseHistory.md"
print -r -- '# History

## 1.9.10

- Previous.' > "$CHECKOUT/Resources/en.lproj/ReleaseHistory.md"
/usr/bin/git -C "$CHECKOUT" add .
/usr/bin/git -C "$CHECKOUT" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m base
/usr/bin/git -C "$CHECKOUT" branch -M main
/usr/bin/git -C "$CHECKOUT" tag v1.9.10
/usr/bin/git -C "$CHECKOUT" push -q origin main --tags
/usr/bin/git clone -q "$ORIGIN" "$BRANCH"
/usr/bin/git -C "$BRANCH" checkout -q -b codex/release-metadata origin/main

print -r -- '#!/bin/zsh
set -euo pipefail
if [[ "$1" == api && "$2" == --include ]]; then
  print -r -- "HTTP/2.0 404 Not Found"
  exit 1
fi
print -u2 -- "unexpected fake gh invocation: $*"
exit 1' > "$FAKE_GH"
/bin/chmod 755 "$FAKE_GH"

FAKE_BIN="$WORK_DIR/bin"
/bin/mkdir -p "$FAKE_BIN"
print -r -- '#!/bin/zsh
set -euo pipefail
print -rn -- 404' > "$FAKE_BIN/curl"
/bin/chmod 755 "$FAKE_BIN/curl"

zh_notes="$WORK_DIR/zh.md"
en_notes="$WORK_DIR/en.md"
print -r -- '- 修复预览发布流程。' > "$zh_notes"
print -r -- '- Improved preview release flow.' > "$en_notes"

PATH="$FAKE_BIN:$PATH" REPOSITORY_ROOT="$BRANCH" GH_BIN="$FAKE_GH" \
  "$BRANCH/scripts/prepare-preview-release.sh" 1.9.10 1 "$zh_notes" "$en_notes" \
  > "$WORK_DIR/result.txt"

/usr/bin/grep -Fq 'SELECTED_VERSION: 1.9.11' "$WORK_DIR/result.txt"
/usr/bin/grep -Fq 'SELECTED_BUILD: 140' "$WORK_DIR/result.txt"
test "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$BRANCH/Resources/Info.plist")" = 1.9.11
test "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$BRANCH/Resources/Info.plist")" = 140
test "$(/usr/bin/git -C "$BRANCH" diff --name-only | LC_ALL=C /usr/bin/sort)" = \
  $'Resources/Info.plist\nResources/en.lproj/ReleaseHistory.md\nResources/zh-Hans.lproj/ReleaseHistory.md'
/usr/bin/grep -Fq '## 1.9.11（预发布）' "$BRANCH/Resources/zh-Hans.lproj/ReleaseHistory.md"
/usr/bin/grep -Fq '## 1.9.11 (Pre-release)' "$BRANCH/Resources/en.lproj/ReleaseHistory.md"

ERROR_BRANCH="$WORK_DIR/error-branch"
ERROR_GH="$WORK_DIR/error-gh"
/usr/bin/git clone -q "$ORIGIN" "$ERROR_BRANCH"
/usr/bin/git -C "$ERROR_BRANCH" checkout -q -b codex/release-metadata-error origin/main
print -r -- '#!/bin/zsh
set -euo pipefail
if [[ "$1" == api && "$2" == --include ]]; then
  print -r -- "HTTP/2.0 500 Internal Server Error"
  exit 1
fi
exit 1' > "$ERROR_GH"
/bin/chmod 755 "$ERROR_GH"
if PATH="$FAKE_BIN:$PATH" REPOSITORY_ROOT="$ERROR_BRANCH" GH_BIN="$ERROR_GH" \
  "$ERROR_BRANCH/scripts/prepare-preview-release.sh" 1.9.11 141 "$zh_notes" "$en_notes" \
  > "$WORK_DIR/error-result.txt" 2> "$WORK_DIR/error-stderr.txt"; then
  print -u2 "prepare-preview-release treated a GitHub error as an available version"
  exit 1
fi
/usr/bin/grep -Fq 'unable to check GitHub Release v1.9.11 (HTTP 500' "$WORK_DIR/error-stderr.txt"
test "$(/usr/bin/git -C "$ERROR_BRANCH" status --porcelain)" = ""

print "PREVIEW RELEASE PREPARATION FIXTURE PASS"
