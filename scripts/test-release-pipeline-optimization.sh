#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-release-pipeline-test.XXXXXX)"
TEST_REPO="$WORK_DIR/repo"
FAKE_GH="$WORK_DIR/fake-gh"
FAKE_WATCHDOG_GH="$WORK_DIR/fake-watchdog-gh"
FAKE_ATTEST_GH="$WORK_DIR/fake-attestation-gh"
FAKE_RUNNER="$WORK_DIR/fake-release-variant-runner"
FAKE_STAGE_COMMAND="$WORK_DIR/fake-stage-command"
FAKE_CURL="$WORK_DIR/fake-curl-bin/curl"
NO_RG_BIN="$WORK_DIR/no-rg-bin"
METADATA_REPO="$WORK_DIR/metadata-repo"

cleanup() {
  print -u2 "release pipeline test evidence retained at: $WORK_DIR"
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
/bin/cp "$ROOT/.github/workflows/mac-stable-promote.yml" "$TEST_REPO/.github/workflows/"
/bin/cp "$ROOT/scripts/verify-release-dependency-pins.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-preview-candidate-ci.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-release-ready-main-ci.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/run-trusted-release-validation.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/resolve-release-request-attestation.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/release-slo-ledger.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/release-user-wall-watchdog.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-release-metadata-diff.sh" "$TEST_REPO/scripts/"
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
/bin/cp "$ROOT/scripts/publish-release.sh" "$TEST_REPO/scripts/"
/bin/mkdir -p "$TEST_REPO/Resources"
/bin/cp "$ROOT/Resources/Info.plist" "$TEST_REPO/Resources/"
/bin/cp "$ROOT/Package.swift" "$ROOT/Package.resolved" "$TEST_REPO/"
print '#!/bin/zsh' > "$TEST_REPO/scripts/verify-preview-branch.sh"
print 'exit 0' >> "$TEST_REPO/scripts/verify-preview-branch.sh"
print '#!/bin/zsh' > "$TEST_REPO/scripts/run-trusted-release-validation.sh"
print 'exit 0' >> "$TEST_REPO/scripts/run-trusted-release-validation.sh"
/bin/chmod 755 "$TEST_REPO/scripts/"*.sh

/usr/bin/grep -Fq 'timeout-minutes: 10' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'SIGNED_RELEASE_TIMEOUT_SECONDS: 540' \
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
package_job_source="$(/usr/bin/awk '
  /^  package:/ { capture = 1 }
  /^  publish:/ { capture = 0 }
  capture { print }
' "$TEST_REPO/.github/workflows/mac-release-package.yml")"
if print -r -- "$package_job_source" | \
     /usr/bin/grep -Eq 'contents:[[:space:]]*write|gh release|git tag' || \
   /usr/bin/grep -Eq 'contents:[[:space:]]*write|gh release|git tag' \
     "$TEST_REPO/scripts/verify-release-canary-provenance.sh"; then
  print -u2 "secret-bearing package/canary path unexpectedly has release mutation capability"
  exit 1
fi
"$TEST_REPO/scripts/verify-release-timeout-budgets.sh" \
  > "$WORK_DIR/timeout-budgets-pass.txt"
/usr/bin/grep -Fq \
  'app-swift-build=300s app-build=330s signed-variant=525s signed-release=540s step=600s' \
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
/usr/bin/grep -Fq 'run-trusted-release-validation.sh' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq 'timeout-minutes: 3' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq "needs.classify-candidate.outputs.reuse_parent_main_ci == 'true'" \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq "needs.classify-candidate.outputs.reuse_parent_main_ci != 'true'" \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq 'Require the recording PR to be the sole full-CI producer' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
if /usr/bin/grep -Eq 'swift test|swift build -c release|build-dmg\.sh' \
    "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"; then
  print -u2 "Preview workflow unexpectedly duplicates full product-code CI"
  exit 1
fi
/usr/bin/grep -Fq 'if: ${{ !contains(github.ref_name, '\''-canary-'\'') }}' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq 'PREVIEW CANDIDATE PACKAGING SKIPPED FOR RELEASE CANARY' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq \
  "grep -Eq '^release/pre-v[0-9]+\\.[0-9]+\\.[0-9]+-canary-" \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq 'run-trusted-release-validation.sh' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq 'GITHUB_REF_NAME: ${{ github.head_ref }}' \
  "$TEST_REPO/.github/workflows/mac-ci.yml"
/usr/bin/grep -Fq 'reuse_parent_main_ci=false' \
  "$TEST_REPO/.github/workflows/mac-ci.yml"
/usr/bin/grep -Fq 'run-trusted-release-validation.sh' \
  "$TEST_REPO/.github/workflows/mac-ci.yml"
/usr/bin/grep -Fq 'TOTAL_SLO_SECONDS: 1740' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'READY_SLO_SECONDS: 840' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'timeout-minutes: 30' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq '.releaseReadyAt' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'request_id:' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'PREVIEW_PUBLISHED_SLO_SECONDS: 840' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'PUBLICATION_MAX_SECONDS: 180' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'release-slo-ledger-published-${{ github.run_id }}' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'release-slo-ledger-failed-${{ github.run_id }}' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'release-user-wall-watchdog.sh' \
  "$TEST_REPO/scripts/release-pipeline-digest.sh"
/usr/bin/grep -Fq 'run-trusted-release-validation.sh' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'git ls-remote origin "refs/tags/$RELEASE_TAG^{}"' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'test "$remote_tag_commit" = "$head_commit"' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'SLO_SECONDS: 1800' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'STABLE_COMPLETION_SLO_SECONDS: 1740' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'Enforce 30-minute user-wall stable SLO' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'reconciliation-requires-release-manager:' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'if: github.event_name == '\''workflow_dispatch'\''' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'workflow_run reconciliation has no authoritative user-request timestamp.' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq './scripts/publish-release.sh promote' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
if /usr/bin/grep -Eq 'package-macos-release|notarize-release|build-app|build-dmg' \
    "$TEST_REPO/.github/workflows/mac-stable-promote.yml"; then
  print -u2 "stable promotion unexpectedly rebuilds candidate assets"
  exit 1
fi
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
/usr/bin/grep -Fq 'PUBLIC_PRODUCT_NAME="无线麦SayAll.app"' \
  "$ROOT/scripts/publish-release.sh" "$ROOT/scripts/fast-release.sh"
/usr/bin/grep -Fq -- '--title "$PUBLIC_PRODUCT_NAME $VERSION"' \
  "$ROOT/scripts/publish-release.sh"
if /usr/bin/grep -Fq -- '--title "Remote Mic $VERSION"' \
    "$ROOT/scripts/publish-release.sh"; then
  print -u2 "release title regressed to the retired Remote Mic brand"
  exit 1
fi

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
git -C "$TEST_REPO" commit -m "release-ready main" >/dev/null
TEST_BASE_COMMIT="$(git -C "$TEST_REPO" rev-parse HEAD)"
git -C "$TEST_REPO" commit --allow-empty -m "release candidate" >/dev/null
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
  print -r -- '  "run list") if [[ "$*" == *"--workflow mac-ci.yml"* ]]; then print 43; else print 42; fi ;;'
  print -r -- '  "run view")'
  print -r -- '    if [[ "${3:-}" == "43" ]]; then'
  print -r -- '      main_sha="$(git rev-parse origin/main)"'
  print -r -- '      [[ "$mode" == "main-wrong-sha" ]] && main_sha=0000000000000000000000000000000000000000'
  print -r -- '      build_steps="[{\"name\":\"Run Swift tests\",\"conclusion\":\"success\"},{\"name\":\"Run project self-test\",\"conclusion\":\"success\"},{\"name\":\"Build release configuration\",\"conclusion\":\"success\"}]"'
  print -r -- '      [[ "$mode" == "main-docs-only" ]] && build_steps="[{\"name\":\"Confirm documentation-only fast path\",\"conclusion\":\"success\"}]"'
  print -r -- '      main_jobs="[{\"name\":\"Swift tests and build (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$build_steps},{\"name\":\"Swift tests and build (Intel Ventura)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$build_steps}]"'
  print -r -- '      [[ "$mode" == "main-missing-intel" ]] && main_jobs="[{\"name\":\"Swift tests and build (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$build_steps}]"'
  print -r -- '      print -r -- "{\"workflowName\":\"macOS CI\",\"event\":\"push\",\"status\":\"completed\",\"conclusion\":\"success\",\"headBranch\":\"main\",\"headSha\":\"$main_sha\",\"jobs\":$main_jobs,\"url\":\"https://example.invalid/run/43\",\"updatedAt\":\"2026-08-20T10:00:00Z\"}"'
  print -r -- '      exit 0'
  print -r -- '    fi'
  print -r -- '    case "$mode" in'
  print -r -- '      wrong-sha) head_sha=0000000000000000000000000000000000000000; conclusion=success ;;'
  print -r -- '      failed) head_sha="$head_commit"; conclusion=failure ;;'
  print -r -- '      *) head_sha="$head_commit"; conclusion=success ;;'
  print -r -- '    esac'
  print -r -- '    proof_steps="[{\"name\":\"Reuse exact parent main product-code proof\",\"conclusion\":\"success\"}]"'
  print -r -- '    jobs="[{\"name\":\"Validate and package preview candidate (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$proof_steps},{\"name\":\"Validate and package preview candidate (Intel Ventura)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$proof_steps}]"'
  print -r -- '    if [[ "$mode" == "missing-intel" ]]; then jobs="[{\"name\":\"Validate and package preview candidate (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$proof_steps}]"; fi'
  print -r -- '    print -r -- "{\"workflowName\":\"macOS Preview Candidate\",\"event\":\"push\",\"status\":\"completed\",\"conclusion\":\"$conclusion\",\"headBranch\":\"release/pre-v9.9.9\",\"headSha\":\"$head_sha\",\"jobs\":$jobs,\"url\":\"https://example.invalid/run/42\"}"'
  print -r -- '    ;;'
  print -r -- '  "pr list")'
  print -r -- '    case "$mode" in'
  print -r -- '      draft|pr-pending|pr-failed) print -r -- "[{\"number\":9,\"url\":\"https://example.invalid/pr/9\",\"isDraft\":true,\"headRefOid\":\"$head_commit\"}]" ;;'
  print -r -- '      non-draft) print -r -- "[{\"number\":9,\"url\":\"https://example.invalid/pr/9\",\"isDraft\":false,\"headRefOid\":\"$head_commit\"}]" ;;'
  print -r -- '      *) print "[]" ;;'
  print -r -- '    esac'
  print -r -- '    ;;'
  print -r -- '  "pr view")'
  print -r -- '    apple_status=COMPLETED; apple_conclusion=SUCCESS; intel_status=COMPLETED; intel_conclusion=SUCCESS'
  print -r -- '    [[ "$mode" == "pr-pending" ]] && apple_status=IN_PROGRESS && apple_conclusion=null'
  print -r -- '    [[ "$mode" == "pr-failed" ]] && intel_conclusion=FAILURE'
  print -r -- '    print -r -- "{\"statusCheckRollup\":[{\"name\":\"Swift tests and build (Apple Silicon)\",\"status\":\"$apple_status\",\"conclusion\":\"$apple_conclusion\"},{\"name\":\"Swift tests and build (Intel Ventura)\",\"status\":\"$intel_status\",\"conclusion\":\"$intel_conclusion\"}]}"'
  print -r -- '    ;;'
  print -r -- '  "pr create") print "https://example.invalid/pr/10" ;;'
  print -r -- '  *) print -u2 "unexpected fake gh command: $*"; exit 1 ;;'
  print -r -- 'esac'
} > "$FAKE_GH"
/bin/chmod 755 "$FAKE_GH"

git -C "$TEST_REPO" update-ref refs/remotes/origin/main "$TEST_BASE_COMMIT"
MAIN_CI_COMMIT="$(git -C "$TEST_REPO" rev-parse origin/main)"
(
  cd "$TEST_REPO"
  GH_BIN="$FAKE_GH" RELEASE_READY_PROOF_OUTPUT="$WORK_DIR/main-proof.json" \
    ./scripts/verify-release-ready-main-ci.sh "$MAIN_CI_COMMIT"
) > "$WORK_DIR/main-ci-pass.txt"
/usr/bin/grep -Fq 'RELEASE-READY MAIN CI PASS' "$WORK_DIR/main-ci-pass.txt"
for failure_mode in main-wrong-sha main-missing-intel main-docs-only; do
  if (
    cd "$TEST_REPO"
    GH_BIN="$FAKE_GH" FAKE_GH_MODE="$failure_mode" \
      ./scripts/verify-release-ready-main-ci.sh "$MAIN_CI_COMMIT"
  ) > "$WORK_DIR/$failure_mode.txt" 2>&1; then
    print -u2 "release-ready main CI verification unexpectedly passed: $failure_mode"
    exit 1
  fi
done

{
  print '#!/bin/zsh'
  print 'set -euo pipefail'
  print 'if [[ "$*" == *"actions/artifacts?name="* ]]; then'
  print '  if [[ -n "${FAKE_ATTEST_ZIP:-}" ]]; then print -r -- '\''{"artifacts":[{"id":91,"expired":false}]}'\''; else print -r -- '\''{"artifacts":[]}'\''; fi'
  print 'elif [[ "$*" == *"actions/artifacts/91/zip"* ]]; then'
  print '  /bin/cat "$FAKE_ATTEST_ZIP"'
  print 'else exit 2; fi'
} > "$FAKE_ATTEST_GH"
/bin/chmod 755 "$FAKE_ATTEST_GH"

GH_BIN="$FAKE_ATTEST_GH" GITHUB_REPOSITORY=HD838A/remote-mic-app \
  "$ROOT/scripts/resolve-release-request-attestation.sh" \
    req-12345 v9.9.9 1787219000 \
    "$HEAD_COMMIT" \
    "$WORK_DIR/main-proof.json" "$WORK_DIR/release-request-attestation.json" \
    > "$WORK_DIR/attestation-first.txt"
/usr/bin/grep -Fq 'RELEASE REQUEST ATTESTATION PASS' "$WORK_DIR/attestation-first.txt"
/bin/mkdir -p "$WORK_DIR/attestation-artifact"
/bin/cp "$WORK_DIR/release-request-attestation.json" \
  "$WORK_DIR/attestation-artifact/release-request-attestation.json"
(cd "$WORK_DIR/attestation-artifact" && /usr/bin/zip -q "$WORK_DIR/attestation.zip" release-request-attestation.json)
if GH_BIN="$FAKE_ATTEST_GH" FAKE_ATTEST_ZIP="$WORK_DIR/attestation.zip" \
   GITHUB_REPOSITORY=HD838A/remote-mic-app \
    "$ROOT/scripts/resolve-release-request-attestation.sh" \
      req-12345 v9.9.9 1787219060 \
      "$HEAD_COMMIT" \
      "$WORK_DIR/main-proof.json" "$WORK_DIR/release-request-attestation-late.json" \
      > "$WORK_DIR/attestation-late.txt" 2>&1; then
  print -u2 "release request attestation allowed a later retry timestamp"
  exit 1
fi
/usr/bin/grep -Fq 'timestamps/identity are immutable' "$WORK_DIR/attestation-late.txt"

/bin/mkdir -p "$METADATA_REPO"
git -C "$METADATA_REPO" init -b main >/dev/null
git -C "$METADATA_REPO" config user.name "Release Metadata Test"
git -C "$METADATA_REPO" config user.email "release-metadata@example.invalid"
/bin/mkdir -p "$METADATA_REPO/Resources/en.lproj" \
  "$METADATA_REPO/Resources/zh-Hans.lproj"
print '<plist><dict>' > "$METADATA_REPO/Resources/Info.plist"
print '<key>CFBundleDisplayName</key><string>SayAll</string>' >> "$METADATA_REPO/Resources/Info.plist"
print '<key>CFBundleShortVersionString</key>' >> "$METADATA_REPO/Resources/Info.plist"
print '<string>9.9.8</string>' >> "$METADATA_REPO/Resources/Info.plist"
print '<key>CFBundleVersion</key>' >> "$METADATA_REPO/Resources/Info.plist"
print '<string>998</string>' >> "$METADATA_REPO/Resources/Info.plist"
print '</dict></plist>' >> "$METADATA_REPO/Resources/Info.plist"
print '# English' > "$METADATA_REPO/Resources/en.lproj/ReleaseHistory.md"
print '# 中文' > "$METADATA_REPO/Resources/zh-Hans.lproj/ReleaseHistory.md"
git -C "$METADATA_REPO" add Resources
git -C "$METADATA_REPO" commit -m base >/dev/null
METADATA_BASE="$(git -C "$METADATA_REPO" rev-parse HEAD)"
/usr/bin/sed -e 's/>9.9.8</>9.9.9</' -e 's/>998</>999</' \
  "$METADATA_REPO/Resources/Info.plist" > "$WORK_DIR/candidate-Info.plist"
/bin/mv "$WORK_DIR/candidate-Info.plist" "$METADATA_REPO/Resources/Info.plist"
print '## 9.9.9' >> "$METADATA_REPO/Resources/en.lproj/ReleaseHistory.md"
print '## 9.9.9' >> "$METADATA_REPO/Resources/zh-Hans.lproj/ReleaseHistory.md"
git -C "$METADATA_REPO" add Resources
git -C "$METADATA_REPO" commit -m candidate >/dev/null
METADATA_HEAD="$(git -C "$METADATA_REPO" rev-parse HEAD)"
(
  cd "$METADATA_REPO"
  "$ROOT/scripts/verify-release-metadata-diff.sh" \
    "$METADATA_BASE" "$METADATA_HEAD" release/pre-v9.9.9
) > "$WORK_DIR/metadata-pass.txt"
/usr/bin/grep -Fq 'RELEASE METADATA DIFF PASS' "$WORK_DIR/metadata-pass.txt"
/bin/mkdir -p "$METADATA_REPO/Sources"
print 'let productCode = true' > "$METADATA_REPO/Sources/Product.swift"
git -C "$METADATA_REPO" add Sources
git -C "$METADATA_REPO" commit -m nonmetadata >/dev/null
if (
  cd "$METADATA_REPO"
  "$ROOT/scripts/verify-release-metadata-diff.sh" \
    "$METADATA_HEAD" "$(git rev-parse HEAD)" release/pre-v9.9.10
) > "$WORK_DIR/metadata-reject.txt" 2>&1; then
  print -u2 "non-metadata release candidate unexpectedly passed"
  exit 1
fi
/usr/bin/grep -Fq 'non-release change: Sources/Product.swift' \
  "$WORK_DIR/metadata-reject.txt"

if (
  cd "$METADATA_REPO"
  "$ROOT/scripts/verify-release-metadata-diff.sh" \
    "$METADATA_BASE" "$(git rev-parse HEAD)" release/pre-v9.9.9
) > "$WORK_DIR/metadata-nondirect.txt" 2>&1; then
  print -u2 "non-direct candidate unexpectedly reused main CI"
  exit 1
fi
/usr/bin/grep -Fq 'must be one direct commit after base main' \
  "$WORK_DIR/metadata-nondirect.txt"

PLIST_REPO="$WORK_DIR/unsafe-info-plist"
git clone -q "$METADATA_REPO" "$PLIST_REPO"
git -C "$PLIST_REPO" config user.name "Release Metadata Test"
git -C "$PLIST_REPO" config user.email "release-metadata@example.invalid"
git -C "$PLIST_REPO" switch --detach "$METADATA_BASE" >/dev/null
/usr/bin/sed \
  -e 's/>SayAll</>Unsafe Name</' \
  -e 's/>9.9.8</>9.9.9</' \
  -e 's/>998</>999</' \
  "$PLIST_REPO/Resources/Info.plist" > "$WORK_DIR/unsafe-Info.plist"
/bin/mv "$WORK_DIR/unsafe-Info.plist" "$PLIST_REPO/Resources/Info.plist"
print '## 9.9.9' >> "$PLIST_REPO/Resources/en.lproj/ReleaseHistory.md"
print '## 9.9.9' >> "$PLIST_REPO/Resources/zh-Hans.lproj/ReleaseHistory.md"
git -C "$PLIST_REPO" add Resources
git -C "$PLIST_REPO" commit -m "unsafe plist metadata" >/dev/null
if (
  cd "$PLIST_REPO"
  "$ROOT/scripts/verify-release-metadata-diff.sh" \
    "$METADATA_BASE" "$(git rev-parse HEAD)" release/pre-v9.9.9
) > "$WORK_DIR/unsafe-info-plist.txt" 2>&1; then
  print -u2 "non-version Info.plist change unexpectedly reused main CI"
  exit 1
fi
/usr/bin/grep -Fq 'may change only version/build values in Info.plist' \
  "$WORK_DIR/unsafe-info-plist.txt"

for unsafe_path in \
  Package.swift \
  Config/RemoteMic.entitlements \
  .github/workflows/mac-release-package.yml \
  scripts/package-macos-release-variants.sh; do
  unsafe_repo="$WORK_DIR/unsafe-${unsafe_path:t:r}"
  git clone -q "$METADATA_REPO" "$unsafe_repo"
  git -C "$unsafe_repo" config user.name "Release Metadata Test"
  git -C "$unsafe_repo" config user.email "release-metadata@example.invalid"
  git -C "$unsafe_repo" switch --detach "$METADATA_BASE" >/dev/null
  /bin/mkdir -p "${unsafe_repo}/${unsafe_path:h}"
  print 'unsafe release input' > "$unsafe_repo/$unsafe_path"
  git -C "$unsafe_repo" add "$unsafe_path"
  git -C "$unsafe_repo" commit -m "unsafe $unsafe_path" >/dev/null
  if (
    cd "$unsafe_repo"
    "$ROOT/scripts/verify-release-metadata-diff.sh" \
      "$METADATA_BASE" "$(git rev-parse HEAD)" release/pre-v9.9.9
  ) > "$WORK_DIR/unsafe-${unsafe_path:t:r}.txt" 2>&1; then
    print -u2 "unsafe release input unexpectedly reused main CI: $unsafe_path"
    exit 1
  fi
  /usr/bin/grep -Fq "non-release change: $unsafe_path" \
    "$WORK_DIR/unsafe-${unsafe_path:t:r}.txt"
done

ledger_now="$(date +%s)"
ledger_file="$WORK_DIR/release-slo.tsv"
"$ROOT/scripts/release-slo-ledger.sh" init "$ledger_file" "$(( ledger_now - 2 ))"
"$ROOT/scripts/release-slo-ledger.sh" start "$ledger_file" "$(( ledger_now - 2 ))" candidate
"$ROOT/scripts/release-slo-ledger.sh" finish "$ledger_file" "$(( ledger_now - 2 ))" candidate success
"$ROOT/scripts/release-slo-ledger.sh" check "$ledger_file" "$(( ledger_now - 2 ))" 10
"$ROOT/scripts/release-slo-ledger.sh" report "$ledger_file" "$(( ledger_now - 2 ))" \
  > "$WORK_DIR/ledger-report.txt"
/usr/bin/grep -Fq 'TOTAL_USER_WALL_SECONDS=' "$WORK_DIR/ledger-report.txt"
if "$ROOT/scripts/release-slo-ledger.sh" init "$WORK_DIR/future.tsv" "$(( ledger_now + 60 ))" \
    > "$WORK_DIR/ledger-future.txt" 2>&1; then
  print -u2 "release ledger unexpectedly accepted a future request time"
  exit 1
fi
if "$ROOT/scripts/release-slo-ledger.sh" init "$WORK_DIR/invalid.tsv" invalid \
    > "$WORK_DIR/ledger-invalid.txt" 2>&1; then
  print -u2 "release ledger unexpectedly accepted an invalid request time"
  exit 1
fi
set +e
"$ROOT/scripts/release-slo-ledger.sh" check "$ledger_file" "$(( ledger_now - 20 ))" 1 \
  > "$WORK_DIR/ledger-overrun.txt" 2>&1
ledger_overrun_status="$?"
set -e
test "$ledger_overrun_status" = "124"
/usr/bin/grep -Fq 'RELEASE SLO EXCEEDED' "$WORK_DIR/ledger-overrun.txt"

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

for pr_failure_mode in pr-pending pr-failed; do
  if (
    cd "$TEST_REPO"
    GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" FAKE_GH_MODE="$pr_failure_mode" \
      REQUIRE_PREVIEW_RECORDING_PR=1 RELEASE_TAG=v9.9.9 \
      ./scripts/verify-preview-candidate-ci.sh 42
  ) > "$WORK_DIR/candidate-$pr_failure_mode.txt" 2>&1; then
    print -u2 "candidate verification unexpectedly accepted PR checks: $pr_failure_mode"
    exit 1
  fi
done

{
  print '#!/bin/zsh'
  print 'set -euo pipefail'
  print 'print -r -- "$*" >> "$FAKE_WATCHDOG_LOG"'
  print 'if [[ "${1:-} ${2:-}" == "run view" ]]; then'
  print '  run_id="${3:-}"'
  print '  if [[ "$run_id" == "77" ]]; then'
  print '    print -r -- '\''{"workflowName":"macOS Stable Promotion","headSha":"1111111111111111111111111111111111111111","headBranch":"main"}'\'''
  print '  else'
  print '    print -r -- '\''{"workflowName":"wrong workflow","headSha":"2222222222222222222222222222222222222222","headBranch":"wrong"}'\'''
  print '  fi'
  print 'fi'
} > "$FAKE_WATCHDOG_GH"
/bin/chmod 755 "$FAKE_WATCHDOG_GH"

watchdog_now="$(date +%s)"
print -r -- "{\"mode\":\"preview\",\"requestId\":\"req-12345\",\"target\":\"release/pre-v9.9.9\",\"requestStartedAt\":$watchdog_now,\"releaseReadyAt\":$watchdog_now,\"status\":\"published-and-verified\"}" > "$WORK_DIR/watchdog-complete"
GH_BIN="$FAKE_WATCHDOG_GH" FAKE_WATCHDOG_LOG="$WORK_DIR/watchdog-pass.log" \
  "$TEST_REPO/scripts/release-user-wall-watchdog.sh" preview \
    "$watchdog_now" "$watchdog_now" req-12345 release/pre-v9.9.9 "$WORK_DIR/watchdog-complete" "$WORK_DIR/watchdog-empty-runs" \
    > "$WORK_DIR/watchdog-pass.txt"
/usr/bin/grep -Fq 'RELEASE USER-WALL WATCHDOG PASS' "$WORK_DIR/watchdog-pass.txt"

print -r -- "{\"mode\":\"preview\",\"requestId\":\"wrong-request\",\"target\":\"release/pre-v9.9.9\",\"requestStartedAt\":$watchdog_now,\"releaseReadyAt\":$watchdog_now,\"status\":\"published-and-verified\"}" > "$WORK_DIR/watchdog-wrong-complete"
set +e
GH_BIN="$FAKE_WATCHDOG_GH" FAKE_WATCHDOG_LOG="$WORK_DIR/watchdog-wrong.log" \
RELEASE_WATCHDOG_POLL_SECONDS=1 \
  "$TEST_REPO/scripts/release-user-wall-watchdog.sh" preview \
    "$(( watchdog_now - 1000 ))" "$(( watchdog_now - 900 ))" req-12345 release/pre-v9.9.9 "$WORK_DIR/watchdog-wrong-complete" "$WORK_DIR/watchdog-empty-runs" \
    > "$WORK_DIR/watchdog-wrong.txt" 2>&1
wrong_completion_status="$?"
set -e
test "$wrong_completion_status" = "124"
/usr/bin/grep -Fq 'Ignoring completion file with mismatched release identity' "$WORK_DIR/watchdog-wrong.txt"

set +e
GH_BIN="$FAKE_WATCHDOG_GH" FAKE_WATCHDOG_LOG="$WORK_DIR/watchdog-expired.log" \
RELEASE_WATCHDOG_POLL_SECONDS=1 \
  "$TEST_REPO/scripts/release-user-wall-watchdog.sh" preview \
    "$(( $(date +%s) - 1000 ))" "$(( $(date +%s) - 900 ))" req-12345 release/pre-v9.9.9 "$WORK_DIR/watchdog-never-completes" "$WORK_DIR/watchdog-empty-runs" \
    > "$WORK_DIR/watchdog-expired.txt" 2>&1
watchdog_status="$?"
set -e
test "$watchdog_status" = "124"
if [[ -s "$WORK_DIR/watchdog-expired.log" ]]; then
  print -u2 "watchdog unexpectedly cancelled an unregistered run"
  exit 1
fi
/usr/bin/grep -Fq 'RELEASE USER-WALL SLO EXCEEDED' "$WORK_DIR/watchdog-expired.txt"

print -r -- '{"runId":77,"workflow":"macOS Stable Promotion","headSha":"1111111111111111111111111111111111111111","headBranch":"main","target":"v9.9.9","requestId":"req-12345"}' > "$WORK_DIR/watchdog-runs"
print -r -- 'invalid' >> "$WORK_DIR/watchdog-runs"
print -r -- '{"runId":88,"workflow":"macOS Stable Promotion","headSha":"2222222222222222222222222222222222222222","headBranch":"main","target":"v9.9.9","requestId":"req-12345"}' >> "$WORK_DIR/watchdog-runs"
set +e
GH_BIN="$FAKE_WATCHDOG_GH" FAKE_WATCHDOG_LOG="$WORK_DIR/watchdog-registered.log" \
RELEASE_WATCHDOG_POLL_SECONDS=1 \
  "$TEST_REPO/scripts/release-user-wall-watchdog.sh" stable \
    "$(( $(date +%s) - 1800 ))" "$(( $(date +%s) - 1800 ))" req-12345 v9.9.9 "$WORK_DIR/watchdog-never-completes" "$WORK_DIR/watchdog-runs" \
    > "$WORK_DIR/watchdog-registered.txt" 2>&1
registered_watchdog_status="$?"
set -e
test "$registered_watchdog_status" = "124"
/usr/bin/grep -Fq 'run cancel 77' "$WORK_DIR/watchdog-registered.log"
/usr/bin/grep -Fq 'run view 88' "$WORK_DIR/watchdog-registered.log"
if /usr/bin/grep -Fq 'run cancel 88' "$WORK_DIR/watchdog-registered.log"; then
  print -u2 "watchdog cancelled a remotely mismatched run"
  exit 1
fi
/usr/bin/grep -Fq 'Ignoring malformed workflow run manifest entry' "$WORK_DIR/watchdog-registered.txt"
/usr/bin/grep -Fq 'remote identity does not match' "$WORK_DIR/watchdog-registered.txt"

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
