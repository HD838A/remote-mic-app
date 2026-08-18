#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-release-pipeline-test.XXXXXX)"
TEST_REPO="$WORK_DIR/repo"
FAKE_GH="$WORK_DIR/fake-gh"
FAKE_RUNNER="$WORK_DIR/fake-release-variant-runner"
FAKE_STAGE_COMMAND="$WORK_DIR/fake-stage-command"
FAKE_CURL="$WORK_DIR/fake-curl-bin/curl"
NO_RG_BIN="$WORK_DIR/no-rg-bin"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remotemic-release-pipeline-test.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected release pipeline test path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

/bin/mkdir -p "$TEST_REPO/.github/workflows" "$TEST_REPO/scripts"
/bin/cp "$ROOT/.github/workflows/mac-ci.yml" "$TEST_REPO/.github/workflows/"
/bin/cp "$ROOT/.github/workflows/mac-preview-candidate.yml" "$TEST_REPO/.github/workflows/"
/bin/cp "$ROOT/.github/workflows/mac-release-package.yml" "$TEST_REPO/.github/workflows/"
/bin/cp "$ROOT/scripts/verify-release-dependency-pins.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-preview-candidate-ci.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/prepare-preview-recording-pr.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/package-macos-release-variants.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/run-release-stage.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/build-app.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/notarize-release.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-release-timeout-budgets.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-release-canary-provenance.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/release-pipeline-digest.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/build-dmg.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/build-doubao-driver.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/build-doubao-driver-pkg.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/package-macos-release-in-actions.sh" "$TEST_REPO/scripts/"
/bin/mkdir -p "$TEST_REPO/Resources"
/bin/cp "$ROOT/Resources/Info.plist" "$TEST_REPO/Resources/"
print '#!/bin/zsh' > "$TEST_REPO/scripts/verify-preview-branch.sh"
print 'exit 0' >> "$TEST_REPO/scripts/verify-preview-branch.sh"
/bin/chmod 755 "$TEST_REPO/scripts/"*.sh

/usr/bin/grep -Fq 'timeout-minutes: 10' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'SIGNED_RELEASE_TIMEOUT_SECONDS: 590' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'if: ${{ !inputs.canary }}' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'PROTECTED RELEASE CANARY PROVENANCE PASS' \
  "$TEST_REPO/scripts/verify-release-canary-provenance.sh"
/usr/bin/grep -Fq 'No Tag, Release, or downloadable artifact was created.' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'environment: mac-release' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'contents: read' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
if /usr/bin/grep -Eq 'contents:[[:space:]]*write|gh release|git tag' \
    "$TEST_REPO/.github/workflows/mac-release-package.yml" \
    "$TEST_REPO/scripts/verify-release-canary-provenance.sh"; then
  print -u2 "release canary unexpectedly has release mutation capability"
  exit 1
fi
"$TEST_REPO/scripts/verify-release-timeout-budgets.sh" \
  > "$WORK_DIR/timeout-budgets-pass.txt"
/usr/bin/grep -Fq \
  'app-swift-build=300s app-build=330s signed-variant=560s signed-release=590s step=600s' \
  "$WORK_DIR/timeout-budgets-pass.txt"

/usr/bin/sed \
  's/RELEASE_SWIFT_BUILD_TIMEOUT_SECONDS:-300/RELEASE_SWIFT_BUILD_TIMEOUT_SECONDS:-180/' \
  "$TEST_REPO/scripts/build-app.sh" > "$WORK_DIR/build-app-old-timeout.sh"
if "$TEST_REPO/scripts/verify-release-timeout-budgets.sh" \
    "$WORK_DIR/build-app-old-timeout.sh" \
    "$TEST_REPO/scripts/notarize-release.sh" \
    "$TEST_REPO/scripts/package-macos-release-variants.sh" \
    "$TEST_REPO/.github/workflows/mac-release-package.yml" \
    > "$WORK_DIR/timeout-old-budget.txt" 2>&1; then
  print -u2 "obsolete 180-second Swift build budget unexpectedly passed"
  exit 1
fi
/usr/bin/grep -Fq 'obsolete 180-second budget' \
  "$WORK_DIR/timeout-old-budget.txt"

/usr/bin/sed \
  's/RELEASE_APP_BUILD_TIMEOUT_SECONDS:-330/RELEASE_APP_BUILD_TIMEOUT_SECONDS:-300/' \
  "$TEST_REPO/scripts/notarize-release.sh" > "$WORK_DIR/notarize-inverted-timeout.sh"
if "$TEST_REPO/scripts/verify-release-timeout-budgets.sh" \
    "$TEST_REPO/scripts/build-app.sh" \
    "$WORK_DIR/notarize-inverted-timeout.sh" \
    "$TEST_REPO/scripts/package-macos-release-variants.sh" \
    "$TEST_REPO/.github/workflows/mac-release-package.yml" \
    > "$WORK_DIR/timeout-inverted-budget.txt" 2>&1; then
  print -u2 "inverted app build timeout relationship unexpectedly passed"
  exit 1
fi
/usr/bin/grep -Fq 'at least 30 seconds beyond app-swift-build' \
  "$WORK_DIR/timeout-inverted-budget.txt"
/usr/bin/grep -Fq 'command -v rg >/dev/null || missing_formulae+=(ripgrep)' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
if /usr/bin/grep -Fq 'brew install age fastlane ripgrep' \
    "$TEST_REPO/.github/workflows/mac-release-package.yml"; then
  print -u2 "signed release workflow still reinstalls every tool"
  exit 1
fi
/usr/bin/grep -Fq 'SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq 'if: ${{ !contains(github.ref_name, '\''-canary-'\'') }}' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq 'PREVIEW CANDIDATE PACKAGING SKIPPED FOR RELEASE CANARY' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq \
  "grep -Eq '^release/pre-v[0-9]+\\.[0-9]+\\.[0-9]+-canary-" \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq './scripts/verify-preview-branch.sh' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq 'Build and verify ad-hoc candidate DMG' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq 'SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh' \
  "$TEST_REPO/.github/workflows/mac-ci.yml"
/usr/bin/grep -Fq 'PUBLIC_DOWNLOAD_CONCURRENCY="${PUBLIC_DOWNLOAD_CONCURRENCY:-4}"' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'download_and_compare_assets "$STAGING_DIR" "$DOWNLOAD_DIR"' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'verify_cdn_assets "$STAGING_DIR" &' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq '/usr/bin/cmp -s "$source_file" "$downloaded_file"' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'downloaded_sha="$(/usr/bin/shasum -a 256' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'public release asset verification failed: github=$github_status cdn=$cdn_status' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq -- '--cache-path "$BUILD_CACHE_PATH"' "$ROOT/scripts/build-app.sh"
/usr/bin/grep -Fq 'REMOTE_MIC_BUILD_CACHE_PATH' "$ROOT/scripts/notarize-release.sh"
/usr/bin/grep -Fq 'PUBLIC_PAYLOAD_ASSET_COUNT=11' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'PUBLIC_RELEASE_ASSET_COUNT=12' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'Remote-Mic-$VERSION.dmg.sha256' \
  "$ROOT/scripts/publish-release.sh"

/bin/mkdir -p "$NO_RG_BIN"
for command_name in cmp curl gh git jq plutil shasum stat; do
  /bin/ln -s "$(command -v "$command_name")" "$NO_RG_BIN/$command_name"
done

if PATH="$NO_RG_BIN" PUBLIC_DOWNLOAD_CONCURRENCY=9 \
    "$ROOT/scripts/publish-release.sh" promote \
    > "$WORK_DIR/invalid-download-concurrency.txt" 2>&1; then
  print -u2 "publish script unexpectedly accepted excessive download concurrency"
  exit 1
fi
/usr/bin/grep -Fq 'PUBLIC_DOWNLOAD_CONCURRENCY must be between 1 and 8' \
  "$WORK_DIR/invalid-download-concurrency.txt"

if PATH="$NO_RG_BIN" RELEASE_TAG=v1.8.25 \
    "$ROOT/scripts/publish-release.sh" promote \
    > "$WORK_DIR/missing-rg.txt" 2>&1; then
  print -u2 "publish script unexpectedly accepted a PATH without ripgrep"
  exit 1
fi
/usr/bin/grep -Fxq 'Missing required command: rg' "$WORK_DIR/missing-rg.txt"

if SKIP_SWIFT_PACKAGE_BUILD=invalid "$ROOT/scripts/test.sh" \
    > "$WORK_DIR/invalid-skip-package-build.txt" 2>&1; then
  print -u2 "self-test unexpectedly accepted an invalid package-build skip flag"
  exit 1
fi
/usr/bin/grep -Fq 'SKIP_SWIFT_PACKAGE_BUILD must be 0 or 1' \
  "$WORK_DIR/invalid-skip-package-build.txt"

download_functions="$(/usr/bin/awk '
  /^wait_for_download_batch\(\)/ { capture = 1 }
  /^verify_stable_download_redirect\(\)/ { capture = 0 }
  capture { print }
' "$ROOT/scripts/publish-release.sh")"
eval "$download_functions"

/bin/mkdir -p "$WORK_DIR/fake-curl-bin" "$WORK_DIR/public-assets" \
  "$WORK_DIR/public-download-pass" "$WORK_DIR/public-download-failure" \
  "$WORK_DIR/legacy-public-assets" "$WORK_DIR/legacy-public-download"
for asset_number in {1..12}; do
  print -r -- "asset-$asset_number" > "$WORK_DIR/public-assets/asset-$asset_number.bin"
done
for asset_number in {1..17}; do
  print -r -- "legacy-asset-$asset_number" > \
    "$WORK_DIR/legacy-public-assets/legacy-asset-$asset_number.bin"
done
{
  print '#!/bin/zsh'
  print 'set -euo pipefail'
  print 'output_file=""'
  print 'asset_url=""'
  print 'while (( $# != 0 )); do'
  print '  case "$1" in'
  print '    --output) output_file="$2"; shift 2 ;;'
  print '    http://*|https://*) asset_url="$1"; shift ;;'
  print '    *) shift ;;'
  print '  esac'
  print 'done'
  print 'asset_name="${asset_url:t}"'
  print 'if [[ "${FAKE_CURL_FAIL_ASSET:-}" == "$asset_name" ]]; then exit 7; fi'
  print '/bin/cp "$FAKE_CURL_SOURCE/$asset_name" "$output_file"'
} > "$FAKE_CURL"
/bin/chmod 755 "$FAKE_CURL"

PUBLIC_DOWNLOAD_CONCURRENCY=4 \
WORK_DIR="$WORK_DIR" \
PATH="${FAKE_CURL:h}:$PATH" \
FAKE_CURL_SOURCE="$WORK_DIR/public-assets" \
  download_and_compare_assets \
    "$WORK_DIR/public-assets" \
    "$WORK_DIR/public-download-pass" \
    'https://example.invalid/releases/v9.9.9/' \
    test-origin > "$WORK_DIR/public-download-pass.txt"
test "$(/usr/bin/find "$WORK_DIR/public-download-pass" -type f | \
  /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "12"

if PUBLIC_DOWNLOAD_CONCURRENCY=4 \
   WORK_DIR="$WORK_DIR" \
   PATH="${FAKE_CURL:h}:$PATH" \
   FAKE_CURL_SOURCE="$WORK_DIR/public-assets" \
   FAKE_CURL_FAIL_ASSET=asset-7.bin \
     download_and_compare_assets \
       "$WORK_DIR/public-assets" \
       "$WORK_DIR/public-download-failure" \
       'https://example.invalid/releases/v9.9.9/' \
       test-failure > "$WORK_DIR/public-download-failure.txt" 2>&1; then
  print -u2 "parallel public download unexpectedly ignored an asset failure"
  exit 1
fi
test "$(/usr/bin/find "$WORK_DIR/public-download-failure" -type f | \
  /usr/bin/wc -l | /usr/bin/tr -d ' ')" -lt "12"

PUBLIC_DOWNLOAD_CONCURRENCY=4 \
WORK_DIR="$WORK_DIR" \
PATH="${FAKE_CURL:h}:$PATH" \
FAKE_CURL_SOURCE="$WORK_DIR/legacy-public-assets" \
  download_and_compare_assets \
    "$WORK_DIR/legacy-public-assets" \
    "$WORK_DIR/legacy-public-download" \
    'https://example.invalid/releases/v1.8.25/' \
    legacy-origin > "$WORK_DIR/legacy-public-download.txt"
test "$(/usr/bin/find "$WORK_DIR/legacy-public-download" -type f | \
  /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "17"
require_supported_release_asset_count 15
if require_supported_release_asset_count 13 \
    > "$WORK_DIR/unsupported-release-count.txt" 2>&1; then
  print -u2 "unsupported release asset count unexpectedly passed"
  exit 1
fi

git -C "$TEST_REPO" init -b release/pre-v9.9.9 >/dev/null
git -C "$TEST_REPO" config user.name "Release Pipeline Test"
git -C "$TEST_REPO" config user.email "release-pipeline@example.invalid"
git -C "$TEST_REPO" add .
git -C "$TEST_REPO" commit -m "release candidate" >/dev/null
HEAD_COMMIT="$(git -C "$TEST_REPO" rev-parse HEAD)"

CANARY_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
  "$TEST_REPO/Resources/Info.plist")"
CANARY_BRANCH="release/pre-v$CANARY_VERSION-canary-timeout-budget"
CANARY_REMOTE="$WORK_DIR/canary-origin.git"
git init --bare "$CANARY_REMOTE" >/dev/null
git -C "$TEST_REPO" push "$CANARY_REMOTE" \
  "HEAD:refs/heads/$CANARY_BRANCH" >/dev/null
CANARY_DIGEST="$(cd "$TEST_REPO" && ./scripts/release-pipeline-digest.sh)"
(
  cd "$TEST_REPO"
  GITHUB_REF_NAME="$CANARY_BRANCH" \
  CANARY_REMOTE_NAME="$CANARY_REMOTE" \
  EXPECTED_COMMIT="$HEAD_COMMIT" \
  EXPECTED_PIPELINE_DIGEST="$CANARY_DIGEST" \
  RELEASE_TAG="v$CANARY_VERSION" \
    ./scripts/verify-release-canary-provenance.sh
) > "$WORK_DIR/canary-provenance-pass.txt"
/usr/bin/grep -Fq 'PROTECTED RELEASE CANARY PROVENANCE PASS' \
  "$WORK_DIR/canary-provenance-pass.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME="release/pre-v$CANARY_VERSION" \
  CANARY_REMOTE_NAME="$CANARY_REMOTE" \
  EXPECTED_COMMIT="$HEAD_COMMIT" \
  EXPECTED_PIPELINE_DIGEST="$CANARY_DIGEST" \
  RELEASE_TAG="v$CANARY_VERSION" \
    ./scripts/verify-release-canary-provenance.sh
) > "$WORK_DIR/canary-normal-branch.txt" 2>&1; then
  print -u2 "release canary unexpectedly accepted a normal preview branch"
  exit 1
fi
/usr/bin/grep -Fq 'release/pre-vX.Y.Z-canary-name' \
  "$WORK_DIR/canary-normal-branch.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME="release/pre-v$CANARY_VERSION-canary-unpushed" \
  CANARY_REMOTE_NAME="$CANARY_REMOTE" \
  EXPECTED_COMMIT="$HEAD_COMMIT" \
  EXPECTED_PIPELINE_DIGEST="$CANARY_DIGEST" \
  RELEASE_TAG="v$CANARY_VERSION" \
    ./scripts/verify-release-canary-provenance.sh
) > "$WORK_DIR/canary-unpushed-branch.txt" 2>&1; then
  print -u2 "release canary unexpectedly accepted an unpushed branch"
  exit 1
fi
/usr/bin/grep -Fq 'remote head must match' \
  "$WORK_DIR/canary-unpushed-branch.txt"

(
  cd "$TEST_REPO"
  ./scripts/verify-release-dependency-pins.sh
) > "$WORK_DIR/pins-pass.txt"
/usr/bin/grep -Fq "RELEASE DEPENDENCY PINS PASS" "$WORK_DIR/pins-pass.txt"

/bin/cp "$TEST_REPO/.github/workflows/mac-ci.yml" "$WORK_DIR/mac-ci.yml"
/usr/bin/awk '
  !changed && index($0, "01beeceac9c4091e7e8e122ad1e840ac5e5cee1c") {
    sub("01beeceac9c4091e7e8e122ad1e840ac5e5cee1c", "1111111111111111111111111111111111111111")
    changed = 1
  }
  { print }
' "$TEST_REPO/.github/workflows/mac-ci.yml" > "$WORK_DIR/mac-ci-mismatch.yml"
/bin/mv "$WORK_DIR/mac-ci-mismatch.yml" "$TEST_REPO/.github/workflows/mac-ci.yml"
if (
  cd "$TEST_REPO"
  ./scripts/verify-release-dependency-pins.sh
) > "$WORK_DIR/pins-mismatch.txt" 2>&1; then
  print -u2 "mismatched private dependency pins unexpectedly passed"
  exit 1
fi
/usr/bin/grep -Fq "commit differs across macOS CI, preview, and signed release workflows" \
  "$WORK_DIR/pins-mismatch.txt"
/bin/cp "$WORK_DIR/mac-ci.yml" "$TEST_REPO/.github/workflows/mac-ci.yml"

{
  print -r -- '#!/bin/zsh'
  print -r -- 'set -euo pipefail'
  print -r -- 'mode="${FAKE_GH_MODE:-success}"'
  print -r -- 'command_name="${1:-} ${2:-}"'
  print -r -- 'if [[ -n "${FAKE_GH_LOG:-}" ]]; then print -r -- "$*" >> "$FAKE_GH_LOG"; fi'
  print -r -- 'head_commit="$(git rev-parse HEAD)"'
  print -r -- 'case "$command_name" in'
  print -r -- '  "run list") print 42 ;;'
  print -r -- '  "run view")'
  print -r -- '    case "$mode" in'
  print -r -- '      wrong-sha) head_sha=0000000000000000000000000000000000000000; conclusion=success ;;'
  print -r -- '      failed) head_sha="$head_commit"; conclusion=failure ;;'
  print -r -- '      *) head_sha="$head_commit"; conclusion=success ;;'
  print -r -- '    esac'
  print -r -- '    jobs="[{\"name\":\"Validate and package preview candidate (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\"},{\"name\":\"Validate and package preview candidate (Intel Ventura)\",\"status\":\"completed\",\"conclusion\":\"success\"}]"'
  print -r -- '    if [[ "$mode" == "missing-intel" ]]; then jobs="[{\"name\":\"Validate and package preview candidate (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\"}]"; fi'
  print -r -- '    print -r -- "{\"workflowName\":\"macOS Preview Candidate\",\"event\":\"push\",\"status\":\"completed\",\"conclusion\":\"$conclusion\",\"headBranch\":\"release/pre-v9.9.9\",\"headSha\":\"$head_sha\",\"jobs\":$jobs,\"url\":\"https://example.invalid/run/42\"}"'
  print -r -- '    ;;'
  print -r -- '  "pr list")'
  print -r -- '    case "$mode" in'
  print -r -- '      draft) print -r -- "[{\"number\":9,\"url\":\"https://example.invalid/pr/9\",\"isDraft\":true,\"headRefOid\":\"$head_commit\"}]" ;;'
  print -r -- '      non-draft) print -r -- "[{\"number\":9,\"url\":\"https://example.invalid/pr/9\",\"isDraft\":false,\"headRefOid\":\"$head_commit\"}]" ;;'
  print -r -- '      *) print "[]" ;;'
  print -r -- '    esac'
  print -r -- '    ;;'
  print -r -- '  "pr create") print "https://example.invalid/pr/10" ;;'
  print -r -- '  *) print -u2 "unexpected fake gh command: $*"; exit 1 ;;'
  print -r -- 'esac'
} > "$FAKE_GH"
/bin/chmod 755 "$FAKE_GH"

(
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" \
    ./scripts/verify-preview-candidate-ci.sh 42
) > "$WORK_DIR/candidate-pass.txt"
/usr/bin/grep -Fq "PREVIEW CANDIDATE CI PASS" "$WORK_DIR/candidate-pass.txt"

(
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" FAKE_GH_MODE=draft \
    REQUIRE_PREVIEW_RECORDING_PR=1 RELEASE_TAG=v9.9.9 \
    ./scripts/verify-preview-candidate-ci.sh 42
) > "$WORK_DIR/candidate-draft-pass.txt"

for failure_mode in wrong-sha failed missing-intel; do
  if (
    cd "$TEST_REPO"
    GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" FAKE_GH_MODE="$failure_mode" \
      ./scripts/verify-preview-candidate-ci.sh 42
  ) > "$WORK_DIR/candidate-$failure_mode.txt" 2>&1; then
    print -u2 "candidate verification unexpectedly passed: $failure_mode"
    exit 1
  fi
done

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" RELEASE_TAG=v9.9.8 \
    ./scripts/verify-preview-candidate-ci.sh 42
) > "$WORK_DIR/tag-mismatch.txt" 2>&1; then
  print -u2 "candidate verification unexpectedly accepted a mismatched release tag"
  exit 1
fi

(
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" FAKE_GH_LOG="$WORK_DIR/gh.log" \
    ./scripts/prepare-preview-recording-pr.sh
) > "$WORK_DIR/prepare-pr.txt"
/usr/bin/grep -Fq -- "--draft" "$WORK_DIR/gh.log"
/usr/bin/grep -Fq "PREVIEW RECORDING DRAFT PR READY" "$WORK_DIR/prepare-pr.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" FAKE_GH_MODE=non-draft \
    ./scripts/prepare-preview-recording-pr.sh
) > "$WORK_DIR/non-draft-pr.txt" 2>&1; then
  print -u2 "prepare script unexpectedly accepted a non-Draft PR"
  exit 1
fi

{
  print '#!/bin/zsh'
  print 'set -euo pipefail'
  print 'print -r -- $$ > "$PARALLEL_TEST_DIR/$RELEASE_VARIANT.pid"'
  print 'touch "$PARALLEL_TEST_DIR/$RELEASE_VARIANT.started"'
  print 'case "$RELEASE_VARIANT" in apple-silicon) other=intel ;; intel) other=apple-silicon ;; *) exit 2 ;; esac'
  print 'for attempt in {1..100}; do'
  print '  [[ -f "$PARALLEL_TEST_DIR/$other.started" ]] && break'
  print '  /bin/sleep 0.02'
  print 'done'
  print 'test -f "$PARALLEL_TEST_DIR/$other.started"'
  print 'if [[ "${FAKE_VARIANT_FAIL:-}" == "$RELEASE_VARIANT" ]]; then /bin/sleep 0.2; exit 7; fi'
  print 'if [[ "${FAKE_VARIANT_HANG:-}" == "$RELEASE_VARIANT" ]]; then'
  print '  trap '\''touch "$PARALLEL_TEST_DIR/$RELEASE_VARIANT.terminated"; exit 143'\'' TERM INT'
  print '  /bin/sleep 60 &'
  print '  print -r -- $! > "$PARALLEL_TEST_DIR/$RELEASE_VARIANT.child.pid"'
  print '  wait'
  print 'fi'
  print 'touch "$PARALLEL_TEST_DIR/$RELEASE_VARIANT.finished"'
} > "$FAKE_RUNNER"
/bin/chmod 755 "$FAKE_RUNNER"
/bin/mkdir "$WORK_DIR/parallel"
(
  cd "$TEST_REPO"
  PARALLEL_RELEASE_VARIANTS=1 PARALLEL_TEST_DIR="$WORK_DIR/parallel" \
    GENERATE_SPARKLE_UPDATE=0 \
    RELEASE_VARIANT_RUNNER="$FAKE_RUNNER" ./scripts/package-macos-release-variants.sh
) > "$WORK_DIR/parallel-pass.txt"
test -f "$WORK_DIR/parallel/apple-silicon.finished"
test -f "$WORK_DIR/parallel/intel.finished"

/bin/mkdir "$WORK_DIR/parallel-failure"
parallel_failure_start="$(date +%s)"
if (
  cd "$TEST_REPO"
  PARALLEL_RELEASE_VARIANTS=1 RELEASE_STAGE_TIMEOUTS=1 \
    RELEASE_VARIANT_TIMEOUT_SECONDS=30 \
    GENERATE_SPARKLE_UPDATE=0 \
    PARALLEL_TEST_DIR="$WORK_DIR/parallel-failure" \
    RELEASE_VARIANT_RUNNER="$FAKE_RUNNER" FAKE_VARIANT_FAIL=intel \
    FAKE_VARIANT_HANG=apple-silicon \
    ./scripts/package-macos-release-variants.sh
) > "$WORK_DIR/parallel-failure.txt" 2>&1; then
  print -u2 "parallel release wrapper unexpectedly ignored a variant failure"
  exit 1
fi
parallel_failure_elapsed=$(( $(date +%s) - parallel_failure_start ))
if (( parallel_failure_elapsed >= 10 )); then
  print -u2 "parallel release wrapper did not fail fast"
  exit 1
fi
for pid_file in "$WORK_DIR/parallel-failure/"*.pid(N); do
  process_id="$(<"$pid_file")"
  for attempt in {1..20}; do
    process_state="$(/bin/ps -o stat= -p "$process_id" 2>/dev/null | /usr/bin/tr -d ' ' || true)"
    [[ -z "$process_state" || "$process_state" == Z* ]] && break
    /bin/sleep 0.1
  done
  if [[ -n "$process_state" && "$process_state" != Z* ]]; then
    print -u2 "parallel release wrapper left a child process running: $process_id"
    exit 1
  fi
done

{
  print '#!/bin/zsh'
  print 'set -euo pipefail'
  print 'print -r -- $$ > "$FAKE_STAGE_DIR/parent.pid"'
  print '/bin/zsh -c '\''trap "" TERM INT HUP; /bin/sleep 60 & print -r -- $! > "$FAKE_STAGE_DIR/grandchild.pid"; wait'\'' &'
  print 'print -r -- $! > "$FAKE_STAGE_DIR/child.pid"'
  print 'wait'
} > "$FAKE_STAGE_COMMAND"
/bin/chmod 755 "$FAKE_STAGE_COMMAND"

quick_stage_start="$(date +%s)"
"$TEST_REPO/scripts/run-release-stage.sh" test quick-exit 5 -- /usr/bin/true \
  > "$WORK_DIR/stage-quick-exit.txt" 2>&1
quick_stage_elapsed=$(( $(date +%s) - quick_stage_start ))
if (( quick_stage_elapsed >= 3 )); then
  print -u2 "release stage did not reap a quick exit promptly"
  exit 1
fi
/usr/bin/grep -Fq 'RELEASE STAGE PASS lane=test stage=quick-exit' \
  "$WORK_DIR/stage-quick-exit.txt"

/bin/mkdir "$WORK_DIR/stage-timeout"
set +e
RELEASE_HEARTBEAT_SECONDS=1 FAKE_STAGE_DIR="$WORK_DIR/stage-timeout" \
  "$TEST_REPO/scripts/run-release-stage.sh" intel test-hang 2 -- \
  "$FAKE_STAGE_COMMAND" > "$WORK_DIR/stage-timeout.txt" 2>&1
stage_timeout_status=$?
set -e
if [[ "$stage_timeout_status" != "124" ]]; then
  print -u2 "release stage timeout returned $stage_timeout_status instead of 124"
  exit 1
fi
for expected_log in \
  'RELEASE STAGE START lane=intel stage=test-hang' \
  'RELEASE STAGE HEARTBEAT lane=intel stage=test-hang' \
  'RELEASE STAGE TIMEOUT lane=intel stage=test-hang'; do
  /usr/bin/grep -Fq "$expected_log" "$WORK_DIR/stage-timeout.txt"
done
for pid_file in "$WORK_DIR/stage-timeout/"*.pid(N); do
  process_id="$(<"$pid_file")"
  for attempt in {1..20}; do
    process_state="$(/bin/ps -o stat= -p "$process_id" 2>/dev/null | /usr/bin/tr -d ' ' || true)"
    [[ -z "$process_state" || "$process_state" == Z* ]] && break
    /bin/sleep 0.1
  done
  if [[ -n "$process_state" && "$process_state" != Z* ]]; then
    print -u2 "release stage timeout left a child process running: $process_id"
    exit 1
  fi
done

print "RELEASE PIPELINE OPTIMIZATION TEST PASS"
print "HEAD: $HEAD_COMMIT"
