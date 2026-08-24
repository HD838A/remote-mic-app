#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-release-pipeline-test.XXXXXX)"
TEST_REPO="$WORK_DIR/repo"
FAKE_GH="$WORK_DIR/fake-gh"
FAKE_QUALIFICATION_GH="$WORK_DIR/fake-qualification-gh"
FAKE_QUALIFICATION_ARTIFACT_GH="$WORK_DIR/fake-qualification-artifact-gh"
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
/bin/cp "$ROOT/.github/workflows/release-guard.yml" "$TEST_REPO/.github/workflows/"
/bin/cp "$ROOT/scripts/verify-release-dependency-pins.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-preview-candidate-ci.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-release-ready-main-ci.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/run-trusted-release-validation.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/resolve-release-request-attestation.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/resolve-stable-request-attestation.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/release-slo-ledger.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/release-user-wall-watchdog.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-release-metadata-diff.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/prepare-preview-recording-pr.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/package-macos-release-variants.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/run-release-stage.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/build-app.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/notarize-release.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-release-timeout-budgets.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-release-pipeline-qualification-source.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-release-pipeline-qualification.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-release-workflow-gh-token.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/release-pipeline-digest.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/build-dmg.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/build-doubao-driver.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/build-doubao-driver-pkg.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/package-macos-release-in-actions.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/publish-release.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/check-repository-boundaries.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/fast-release.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/reconcile-release-event.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/release-variant.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/test.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-app.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-dmg.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-doubao-driver.sh" "$TEST_REPO/scripts/"
/bin/cp "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$TEST_REPO/scripts/"
/bin/mkdir -p "$TEST_REPO/packaging" "$TEST_REPO/third_party"
/bin/cp -R "$ROOT/packaging/release-variants" "$TEST_REPO/packaging/"
/bin/cp -R "$ROOT/packaging/doubao-driver" "$TEST_REPO/packaging/"
/bin/cp -R "$ROOT/third_party/blackhole" "$TEST_REPO/third_party/"
/bin/mkdir -p "$TEST_REPO/Resources"
/bin/cp "$ROOT/Resources/Info.plist" "$TEST_REPO/Resources/"
/bin/cp "$ROOT/Package.swift" "$ROOT/Package.resolved" "$TEST_REPO/"
if [[ ! -x "$ROOT/scripts/verify-release-pipeline-qualification-source.sh" ]]; then
  print -u2 "release qualification source verifier must be executable in Git"
  exit 1
fi
print '#!/bin/zsh' > "$TEST_REPO/scripts/verify-preview-branch.sh"
print 'exit 0' >> "$TEST_REPO/scripts/verify-preview-branch.sh"
print '#!/bin/zsh' > "$TEST_REPO/scripts/run-trusted-release-validation.sh"
print 'exit 0' >> "$TEST_REPO/scripts/run-trusted-release-validation.sh"
/bin/chmod 755 "$TEST_REPO/scripts/"*.sh

/usr/bin/grep -Fq 'timeout-minutes: 10' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'SIGNED_RELEASE_TIMEOUT_SECONDS: 540' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'release_mode:' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'run-name: mac-release ${{ inputs.release_mode }}' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq -- '- qualification' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq -- '- preview' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq "if: \${{ inputs.release_mode == 'qualification' }}" \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq "if: \${{ inputs.release_mode == 'preview' }}" \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
if /usr/bin/grep -Fq 'inputs.canary' \
    "$TEST_REPO/.github/workflows/mac-release-package.yml"; then
  print -u2 "signed release workflow still exposes the ambiguous canary boolean"
  exit 1
fi
/usr/bin/grep -Fq 'PROTECTED RELEASE PIPELINE QUALIFICATION PASS' \
  "$TEST_REPO/scripts/verify-release-pipeline-qualification-source.sh"
/usr/bin/grep -Fq 'verify-release-pipeline-qualification.sh' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'mac-release-pipeline-qualification-${{ inputs.expected_pipeline_digest }}' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq "format('mac-release-qualification-{0}', inputs.expected_pipeline_digest)" \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq "format('mac-signed-tag-{0}', inputs.tag)" \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'EXPECTED_STABLE_TAG: v1.8.3' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'Preview requires stable latest $EXPECTED_STABLE_TAG' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'No Tag, GitHub Release, appcast, or distributable App asset was created.' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'Verify active source before protected credentials' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'Verify active preview before signed artifact handoff' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'git -C "$match_repo" update-ref refs/heads/main "$match_commit"' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'git ls-remote "file://$match_repo" refs/heads/main' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'readonly Match checkout must expose local main at its exact pinned HEAD' \
  "$TEST_REPO/scripts/package-macos-release-in-actions.sh"
/usr/bin/grep -Fq 'environment: mac-release' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'contents: read' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
REPOSITORY_ROOT="$TEST_REPO" \
  "$TEST_REPO/scripts/verify-release-workflow-gh-token.sh"

match_fixture_source="$WORK_DIR/match-fixture-source"
match_fixture_checkout="$WORK_DIR/match-fixture-checkout"
match_fixture_consumer="$WORK_DIR/match-fixture-consumer"
/usr/bin/git init -q -b main "$match_fixture_source"
/bin/mkdir -p \
  "$match_fixture_source/certs/developer_id_application" \
  "$match_fixture_source/certs/developer_id_installer"
print 'encrypted application fixture' > \
  "$match_fixture_source/certs/developer_id_application/application.cer"
print 'encrypted installer fixture' > \
  "$match_fixture_source/certs/developer_id_installer/installer.cer"
/usr/bin/git -C "$match_fixture_source" add certs
/usr/bin/git -C "$match_fixture_source" \
  -c user.name='Release Test' -c user.email='release-test@example.invalid' \
  commit -q -m 'test: add encrypted Match fixtures'
match_fixture_commit="$(/usr/bin/git -C "$match_fixture_source" rev-parse HEAD)"
/usr/bin/git init -q "$match_fixture_checkout"
/usr/bin/git -C "$match_fixture_checkout" remote add origin "file://$match_fixture_source"
/usr/bin/git -C "$match_fixture_checkout" fetch -q --no-tags --depth=1 \
  origin "$match_fixture_commit"
/usr/bin/git -C "$match_fixture_checkout" checkout -q --force "$match_fixture_commit"
if [[ -n "$(/usr/bin/git ls-remote "file://$match_fixture_checkout" refs/heads/main)" ]]; then
  print -u2 "detached Match fixture unexpectedly exposed a main branch"
  exit 1
fi
/usr/bin/git -C "$match_fixture_checkout" \
  update-ref refs/heads/main "$match_fixture_commit"
test "$(/usr/bin/git -C "$match_fixture_checkout" rev-parse refs/heads/main)" = \
  "$match_fixture_commit"
test "$(/usr/bin/git ls-remote "file://$match_fixture_checkout" refs/heads/main | \
  /usr/bin/awk 'NR == 1 { print $1 }')" = "$match_fixture_commit"
/usr/bin/git clone -q --branch main --single-branch \
  "file://$match_fixture_checkout" "$match_fixture_consumer"
test "$(/usr/bin/git -C "$match_fixture_consumer" rev-parse refs/remotes/origin/main)" = \
  "$match_fixture_commit"
test -f "$match_fixture_consumer/certs/developer_id_application/application.cer"
test -f "$match_fixture_consumer/certs/developer_id_installer/installer.cer"

package_job_source="$(/usr/bin/awk '
  /^  package:/ { capture = 1 }
  /^  publish:/ { capture = 0 }
  capture { print }
' "$TEST_REPO/.github/workflows/mac-release-package.yml")"
if print -r -- "$package_job_source" | \
     /usr/bin/grep -Eq 'contents:[[:space:]]*write|gh release|git tag' || \
   /usr/bin/grep -Eq 'contents:[[:space:]]*write|gh release|git tag' \
     "$TEST_REPO/scripts/verify-release-pipeline-qualification-source.sh"; then
  print -u2 "secret-bearing package/qualification path unexpectedly has release mutation capability"
  exit 1
fi

release_critical_workflows=(
  "$TEST_REPO/.github/workflows/mac-ci.yml"
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
  "$TEST_REPO/.github/workflows/release-guard.yml"
)
if /usr/bin/grep -En \
    'uses:[[:space:]]*[^[:space:]#]+@v[0-9]+([.][0-9]+)*([[:space:]#]|$)' \
    "${release_critical_workflows[@]}" \
    > "$WORK_DIR/mutable-release-action-tags.txt"; then
  print -u2 "release-critical workflow still uses a mutable Actions version tag"
  /bin/cat "$WORK_DIR/mutable-release-action-tags.txt" >&2
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
if /usr/bin/grep -Fq -- '-canary-' \
    "$TEST_REPO/.github/workflows/mac-preview-candidate.yml" || \
   /usr/bin/grep -Fq 'skip-release-canary:' \
    "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"; then
  print -u2 "Preview workflow still contains a dedicated canary branch exception"
  exit 1
fi
/usr/bin/grep -Fq 'run-trusted-release-validation.sh' \
  "$TEST_REPO/.github/workflows/mac-preview-candidate.yml"
/usr/bin/grep -Fq 'GITHUB_REF_NAME: ${{ github.head_ref }}' \
  "$TEST_REPO/.github/workflows/mac-ci.yml"
/usr/bin/grep -Fq 'reuse_parent_main_ci=false' \
  "$TEST_REPO/.github/workflows/mac-ci.yml"
/usr/bin/grep -Fq 'run-trusted-release-validation.sh' \
  "$TEST_REPO/.github/workflows/mac-ci.yml"
if ! /usr/bin/awk '
  $0 == "  classify_changes:" { section = 1; next }
  section && $0 ~ /^  [A-Za-z_][A-Za-z0-9_-]*:/ { exit(found ? 0 : 1) }
  section && $0 == "    runs-on: ubuntu-latest" { exit 1 }
  section && $0 == "    runs-on: macos-15" { found = 1 }
  END { if (section && !found) exit 1 }
' "$TEST_REPO/.github/workflows/mac-ci.yml"; then
  print -u2 "macOS CI classifier must run on a zsh-capable macOS runner"
  exit 1
fi
/usr/bin/grep -Fq 'READY_SLO_SECONDS: 1740' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
if /usr/bin/grep -Fq 'TOTAL_SLO_SECONDS:' \
    "$TEST_REPO/.github/workflows/mac-release-package.yml"; then
  print -u2 "preview workflow still truncates the release-ready window with a request-total SLO"
  exit 1
fi
/usr/bin/grep -Fq 'timeout-minutes: 30' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq '.releaseReadyAt' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'request_id:' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'PREVIEW_READY_SLO_SECONDS: 1740' \
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
/usr/bin/grep -Fq 'READY_SLO_SECONDS: 1740' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'STABLE_READY_SLO_SECONDS: 1740' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'Enforce 30-minute release-ready stable promotion SLO' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'request_id:' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'resolve-stable-request-attestation.sh' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'stable-request-attestation-${{ inputs.tag }}' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'stable promotion source must be an existing published pre-release' \
  "$TEST_REPO/scripts/resolve-stable-request-attestation.sh"
/usr/bin/grep -Fq 'release_ready_at="$(jq -r' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'reconciliation-requires-release-manager:' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'if: github.event_name == '\''workflow_dispatch'\''' \
  "$TEST_REPO/.github/workflows/mac-stable-promote.yml"
/usr/bin/grep -Fq 'workflow_run reconciliation has no authoritative command to promote a specified pre-release.' \
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
/usr/bin/grep -Fq 'EXPECTED_STABLE_TAG="${EXPECTED_STABLE_TAG:-v1.8.3}"' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'stable latest must remain $EXPECTED_STABLE_TAG during Preview publication' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'download_and_compare_assets "$STAGING_DIR" "$DOWNLOAD_DIR"' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'verify_cdn_assets "$STAGING_DIR" "$CANDIDATE_RELEASE_MANIFEST" &' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq './scripts/publish-release.sh verify-prerelease' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq '/usr/bin/cmp -s "$source_file" "$downloaded_file"' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'downloaded_sha="$(/usr/bin/shasum -a 256' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'public release asset verification failed: github=$github_status cdn=$cdn_status' \
  "$ROOT/scripts/publish-release.sh"

stable_latest_guard="$(/usr/bin/awk '
  /^require_expected_stable_latest\(\)/ { capture = 1 }
  /^verify_update_zip\(\)/ { capture = 0 }
  capture { print }
' "$ROOT/scripts/publish-release.sh")"
(
  eval "$stable_latest_guard"
  gh() { print -r -- v1.8.3; }
  EXPECTED_STABLE_TAG=v1.8.3
  REPOSITORY=HD838A/remote-mic-app
  require_expected_stable_latest
)
if (
  eval "$stable_latest_guard"
  gh() { print -r -- v1.9.9; }
  EXPECTED_STABLE_TAG=v1.8.3
  REPOSITORY=HD838A/remote-mic-app
  require_expected_stable_latest
) > "$WORK_DIR/wrong-stable-latest.txt" 2>&1; then
  print -u2 "Preview stable-latest guard unexpectedly accepted v1.9.9"
  exit 1
fi
/usr/bin/grep -Fq 'stable latest must remain v1.8.3 during Preview publication; found v1.9.9' \
  "$WORK_DIR/wrong-stable-latest.txt"
/usr/bin/grep -Fq -- '--cache-path "$BUILD_CACHE_PATH"' "$ROOT/scripts/build-app.sh"
/usr/bin/grep -Fq 'REMOTE_MIC_BUILD_CACHE_PATH' "$ROOT/scripts/notarize-release.sh"
if /usr/bin/grep -Eq 'PUBLIC_(PAYLOAD_)?ASSET_COUNT|11\|14\|16|12\|15\|17' \
    "$ROOT/scripts/publish-release.sh"; then
  print -u2 "publish script still hard-codes a release asset count matrix"
  exit 1
fi
/usr/bin/grep -Fq 'write_candidate_release_manifest' "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'asset set does not exactly match candidate provenance' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'release_uploads+=("$STAGING_DIR/$asset_name")' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'release mutation is restricted to the expected protected GitHub workflow' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'Remote-Mic-$VERSION.dmg.sha256' \
  "$ROOT/scripts/publish-release.sh"
/usr/bin/grep -Fq 'PUBLIC_PRODUCT_NAME="无线麦SayAll.app"' \
  "$ROOT/scripts/publish-release.sh" "$ROOT/scripts/fast-release.sh"
/usr/bin/grep -Fq 'EXPECTED_RUN_TITLE="mac-release preview $RELEASE_TAG $REQUEST_ID $HEAD_COMMIT"' \
  "$ROOT/scripts/fast-release.sh"
/usr/bin/grep -Fq '.displayTitle == $runTitle' "$ROOT/scripts/fast-release.sh"
/usr/bin/grep -Fq '.display_title == $runTitle' "$ROOT/scripts/fast-release.sh"
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
  /^validate_payload_asset_manifest\(\)/ { capture = 1 }
  /^verify_stable_download_redirect\(\)/ { capture = 0 }
  capture { print }
' "$ROOT/scripts/publish-release.sh")"
eval "$download_functions"

/bin/mkdir -p "$WORK_DIR/fake-curl-bin" "$WORK_DIR/public-assets" \
  "$WORK_DIR/public-download-pass" "$WORK_DIR/public-download-failure" \
  "$WORK_DIR/public-download-duplicate" \
  "$WORK_DIR/legacy-public-assets" "$WORK_DIR/legacy-public-download" \
  "$WORK_DIR/legacy-small-assets" "$WORK_DIR/legacy-small-download"
for asset_number in {1..12}; do
  print -r -- "asset-$asset_number" > "$WORK_DIR/public-assets/asset-$asset_number.bin"
done
for asset_number in {1..17}; do
  print -r -- "legacy-asset-$asset_number" > \
    "$WORK_DIR/legacy-public-assets/legacy-asset-$asset_number.bin"
done
for asset_number in {1..9}; do
  print -r -- "legacy-small-asset-$asset_number" > \
    "$WORK_DIR/legacy-small-assets/legacy-small-asset-$asset_number.bin"
done
for asset_file in "$WORK_DIR/public-assets"/*(.N); do
  print -r -- "${asset_file:t}"
done | LC_ALL=C /usr/bin/sort > "$WORK_DIR/public-assets.txt"
for asset_file in "$WORK_DIR/legacy-public-assets"/*(.N); do
  print -r -- "${asset_file:t}"
done | LC_ALL=C /usr/bin/sort > "$WORK_DIR/legacy-public-assets.txt"
for asset_file in "$WORK_DIR/legacy-small-assets"/*(.N); do
  print -r -- "${asset_file:t}"
done | LC_ALL=C /usr/bin/sort > "$WORK_DIR/legacy-small-assets.txt"
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
    test-origin "$WORK_DIR/public-assets.txt" \
    > "$WORK_DIR/public-download-pass.txt"
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
       test-failure "$WORK_DIR/public-assets.txt" \
       > "$WORK_DIR/public-download-failure.txt" 2>&1; then
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
    legacy-origin "$WORK_DIR/legacy-public-assets.txt" \
    > "$WORK_DIR/legacy-public-download.txt"
test "$(/usr/bin/find "$WORK_DIR/legacy-public-download" -type f | \
  /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "17"

PUBLIC_DOWNLOAD_CONCURRENCY=4 \
WORK_DIR="$WORK_DIR" \
PATH="${FAKE_CURL:h}:$PATH" \
FAKE_CURL_SOURCE="$WORK_DIR/legacy-small-assets" \
  download_and_compare_assets \
    "$WORK_DIR/legacy-small-assets" \
    "$WORK_DIR/legacy-small-download" \
    'https://example.invalid/releases/v1.8.12/' \
    legacy-small-origin "$WORK_DIR/legacy-small-assets.txt" \
    > "$WORK_DIR/legacy-small-download.txt"
test "$(/usr/bin/find "$WORK_DIR/legacy-small-download" -type f | \
  /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "9"

{
  /bin/cat "$WORK_DIR/public-assets.txt"
  print -r -- 'asset-1.bin'
} | LC_ALL=C /usr/bin/sort > "$WORK_DIR/duplicate-public-assets.txt"
if PUBLIC_DOWNLOAD_CONCURRENCY=4 \
   WORK_DIR="$WORK_DIR" \
   PATH="${FAKE_CURL:h}:$PATH" \
   FAKE_CURL_SOURCE="$WORK_DIR/public-assets" \
     download_and_compare_assets \
       "$WORK_DIR/public-assets" \
       "$WORK_DIR/public-download-duplicate" \
       'https://example.invalid/releases/v9.9.9/' \
       duplicate-manifest "$WORK_DIR/duplicate-public-assets.txt" \
       > "$WORK_DIR/duplicate-public-assets-output.txt" 2>&1; then
  print -u2 "duplicate manifest asset unexpectedly passed"
  exit 1
fi

print -r -- \
  '{"payloadAssets":[{"name":"asset.bin","size":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"},{"name":"asset.bin","size":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}' \
  > "$WORK_DIR/duplicate-provenance.json"
if validate_payload_asset_manifest "$WORK_DIR/duplicate-provenance.json"; then
  print -u2 "duplicate provenance asset unexpectedly passed"
  exit 1
fi
print -r -- \
  '{"payloadAssets":[{"name":"asset?token.bin","size":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}' \
  > "$WORK_DIR/unsafe-name-provenance.json"
if validate_payload_asset_manifest "$WORK_DIR/unsafe-name-provenance.json"; then
  print -u2 "unsafe provenance asset name unexpectedly passed"
  exit 1
fi

print 'release pipeline digest fixture' \
  > "$TEST_REPO/packaging/release-variants/digest-fixture.txt"

git -C "$TEST_REPO" init -b release/pre-v9.9.9 >/dev/null
git -C "$TEST_REPO" config user.name "Release Pipeline Test"
git -C "$TEST_REPO" config user.email "release-pipeline@example.invalid"
git -C "$TEST_REPO" add .
git -C "$TEST_REPO" commit -m "release-ready main" >/dev/null
TEST_BASE_COMMIT="$(git -C "$TEST_REPO" rev-parse HEAD)"
git -C "$TEST_REPO" commit --allow-empty -m "release candidate" >/dev/null
HEAD_COMMIT="$(git -C "$TEST_REPO" rev-parse HEAD)"

QUALIFICATION_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
  "$TEST_REPO/Resources/Info.plist")"
QUALIFICATION_BRANCH="release/pipeline-qualification/pr-999"
QUALIFICATION_REMOTE="$WORK_DIR/qualification-origin.git"
git init --bare "$QUALIFICATION_REMOTE" >/dev/null
git -C "$TEST_REPO" push "$QUALIFICATION_REMOTE" \
  "HEAD:refs/heads/$QUALIFICATION_BRANCH" >/dev/null
git -C "$TEST_REPO" push "$QUALIFICATION_REMOTE" \
  "HEAD:refs/pull/999/head" >/dev/null
QUALIFICATION_DIGEST="$(cd "$TEST_REPO" && ./scripts/release-pipeline-digest.sh)"
QUALIFICATION_REF_DIGEST="$(
  cd "$TEST_REPO"
  ./scripts/release-pipeline-digest.sh HEAD
)"
if [[ "$QUALIFICATION_REF_DIGEST" != "$QUALIFICATION_DIGEST" ]]; then
  print -u2 "worktree and committed release pipeline digests differ"
  exit 1
fi

DIGEST_FIXTURE="$TEST_REPO/packaging/release-variants/digest-fixture.txt"
/bin/cp "$DIGEST_FIXTURE" "$WORK_DIR/digest-fixture-original"
print 'changed closure content' >> "$DIGEST_FIXTURE"
DIGEST_AFTER_CONTENT_CHANGE="$(
  cd "$TEST_REPO"
  ./scripts/release-pipeline-digest.sh
)"
if [[ "$DIGEST_AFTER_CONTENT_CHANGE" == "$QUALIFICATION_DIGEST" ]]; then
  print -u2 "release pipeline digest ignored a packaging closure content change"
  exit 1
fi
/bin/cp "$WORK_DIR/digest-fixture-original" "$DIGEST_FIXTURE"

DIGEST_FIXTURE_MODE="$(/usr/bin/stat -f '%Lp' "$DIGEST_FIXTURE")"
/bin/chmod 755 "$DIGEST_FIXTURE"
DIGEST_AFTER_MODE_CHANGE="$(
  cd "$TEST_REPO"
  ./scripts/release-pipeline-digest.sh
)"
if [[ "$DIGEST_AFTER_MODE_CHANGE" == "$QUALIFICATION_DIGEST" ]]; then
  print -u2 "release pipeline digest ignored a tracked file mode change"
  exit 1
fi
/bin/chmod "$DIGEST_FIXTURE_MODE" "$DIGEST_FIXTURE"

/bin/mv "$DIGEST_FIXTURE" "$WORK_DIR/digest-fixture-regular"
/bin/ln -s "$WORK_DIR/digest-fixture-regular" "$DIGEST_FIXTURE"
DIGEST_AFTER_TYPE_CHANGE="$(
  cd "$TEST_REPO"
  ./scripts/release-pipeline-digest.sh
)"
if [[ "$DIGEST_AFTER_TYPE_CHANGE" == "$QUALIFICATION_DIGEST" ]]; then
  print -u2 "release pipeline digest ignored a tracked file type change"
  exit 1
fi
/bin/mv "$DIGEST_FIXTURE" "$WORK_DIR/digest-fixture-symlink"
/bin/mv "$WORK_DIR/digest-fixture-regular" "$DIGEST_FIXTURE"

if [[ "$(cd "$TEST_REPO" && ./scripts/release-pipeline-digest.sh)" != \
      "$QUALIFICATION_DIGEST" ]]; then
  print -u2 "release pipeline digest fixture did not restore to its reviewed state"
  exit 1
fi

{
  print '#!/bin/zsh'
  print 'set -euo pipefail'
  print 'head_commit="$(git rev-parse HEAD)"'
  print 'case "${FAKE_QUALIFICATION_MODE:-open-pr}" in'
  print -r -- '  open-pr) print -r -- "[{\"number\":999,\"html_url\":\"https://example.invalid/pr/999\",\"draft\":true,\"state\":\"open\",\"base\":{\"ref\":\"main\"},\"head\":{\"ref\":\"release/pipeline-qualification/pr-999\",\"sha\":\"$head_commit\",\"repo\":{\"full_name\":\"HD838A/remote-mic-app\"}}}]" ;;'
  print '  missing-pr) print -r -- "[]" ;;'
  print '  *) print -u2 "unexpected fake qualification mode"; exit 2 ;;'
  print 'esac'
} > "$FAKE_QUALIFICATION_GH"
/bin/chmod 755 "$FAKE_QUALIFICATION_GH"

(
  cd "$TEST_REPO"
  GITHUB_REF_NAME="$QUALIFICATION_BRANCH" \
  RELEASE_QUALIFICATION_REMOTE_NAME="$QUALIFICATION_REMOTE" \
  GH_BIN="$FAKE_QUALIFICATION_GH" \
  GITHUB_REPOSITORY=HD838A/remote-mic-app \
  EXPECTED_COMMIT="$HEAD_COMMIT" \
  EXPECTED_PIPELINE_DIGEST="$QUALIFICATION_DIGEST" \
  RELEASE_MODE=qualification \
  RELEASE_TAG="v$QUALIFICATION_VERSION" \
    ./scripts/verify-release-pipeline-qualification-source.sh
) > "$WORK_DIR/qualification-provenance-pass.txt"
/usr/bin/grep -Fq 'PROTECTED RELEASE PIPELINE QUALIFICATION PASS' \
  "$WORK_DIR/qualification-provenance-pass.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME="release/pre-v$QUALIFICATION_VERSION" \
  RELEASE_QUALIFICATION_REMOTE_NAME="$QUALIFICATION_REMOTE" \
  GH_BIN="$FAKE_QUALIFICATION_GH" \
  EXPECTED_COMMIT="$HEAD_COMMIT" \
  EXPECTED_PIPELINE_DIGEST="$QUALIFICATION_DIGEST" \
  RELEASE_MODE=qualification \
  RELEASE_TAG="v$QUALIFICATION_VERSION" \
    ./scripts/verify-release-pipeline-qualification-source.sh
) > "$WORK_DIR/qualification-candidate-branch.txt" 2>&1; then
  print -u2 "release qualification unexpectedly accepted a preview candidate branch"
  exit 1
fi
/usr/bin/grep -Fq 'release/pipeline-qualification/' \
  "$WORK_DIR/qualification-candidate-branch.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME="$QUALIFICATION_BRANCH" \
  RELEASE_QUALIFICATION_REMOTE_NAME="$QUALIFICATION_REMOTE" \
  GH_BIN="$FAKE_QUALIFICATION_GH" \
  EXPECTED_COMMIT="$HEAD_COMMIT" \
  EXPECTED_PIPELINE_DIGEST="$QUALIFICATION_DIGEST" \
  RELEASE_MODE=preview \
  RELEASE_TAG="v$QUALIFICATION_VERSION" \
    ./scripts/verify-release-pipeline-qualification-source.sh
) > "$WORK_DIR/qualification-mode-disabled.txt" 2>&1; then
  print -u2 "release qualification unexpectedly accepted qualification mode disabled"
  exit 1
fi
/usr/bin/grep -Fq 'requires explicit qualification mode' \
  "$WORK_DIR/qualification-mode-disabled.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME="release/pipeline-qualification/unpushed" \
  RELEASE_QUALIFICATION_REMOTE_NAME="$QUALIFICATION_REMOTE" \
  GH_BIN="$FAKE_QUALIFICATION_GH" \
  EXPECTED_COMMIT="$HEAD_COMMIT" \
  EXPECTED_PIPELINE_DIGEST="$QUALIFICATION_DIGEST" \
  RELEASE_MODE=qualification \
  RELEASE_TAG="v$QUALIFICATION_VERSION" \
    ./scripts/verify-release-pipeline-qualification-source.sh
) > "$WORK_DIR/qualification-unpushed-branch.txt" 2>&1; then
  print -u2 "release qualification unexpectedly accepted an unpushed branch"
  exit 1
fi
/usr/bin/grep -Fq 'remote head must match the expected commit' \
  "$WORK_DIR/qualification-unpushed-branch.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME="$QUALIFICATION_BRANCH" \
  RELEASE_QUALIFICATION_REMOTE_NAME="$QUALIFICATION_REMOTE" \
  GH_BIN="$FAKE_QUALIFICATION_GH" \
  FAKE_QUALIFICATION_MODE=missing-pr \
  EXPECTED_COMMIT="$HEAD_COMMIT" \
  EXPECTED_PIPELINE_DIGEST="$QUALIFICATION_DIGEST" \
  RELEASE_MODE=qualification \
  RELEASE_TAG="v$QUALIFICATION_VERSION" \
    ./scripts/verify-release-pipeline-qualification-source.sh
) > "$WORK_DIR/qualification-missing-pr.txt" 2>&1; then
  print -u2 "release qualification unexpectedly accepted a commit without an open main PR"
  exit 1
fi
/usr/bin/grep -Fq 'exactly one open same-repository PR targeting main' \
  "$WORK_DIR/qualification-missing-pr.txt"

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
  print -r -- 'head_branch="${FAKE_HEAD_BRANCH:-release/pre-v9.9.9}"'
  print -r -- 'case "$command_name" in'
  print -r -- '  "run list") if [[ "$*" == *"--workflow mac-ci.yml"* ]]; then print 43; else print 42; fi ;;'
  print -r -- '  "run view")'
  print -r -- '    run_id="${3:-}"'
  print -r -- '    if [[ "$run_id" == "43" ]]; then'
  print -r -- '      main_sha="$(git rev-parse origin/main)"'
  print -r -- '      [[ "$mode" == "main-wrong-sha" ]] && main_sha=0000000000000000000000000000000000000000'
  print -r -- '      build_steps="[{\"name\":\"Run Swift tests\",\"conclusion\":\"success\"},{\"name\":\"Run project self-test\",\"conclusion\":\"success\"},{\"name\":\"Build release configuration\",\"conclusion\":\"success\"}]"'
  print -r -- '      [[ "$mode" == "main-docs-only" ]] && build_steps="[{\"name\":\"Confirm documentation-only fast path\",\"conclusion\":\"success\"}]"'
  print -r -- '      main_jobs="[{\"name\":\"Swift tests and build (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$build_steps},{\"name\":\"Swift tests and build (Intel Ventura)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$build_steps}]"'
  print -r -- '      [[ "$mode" == "main-missing-intel" ]] && main_jobs="[{\"name\":\"Swift tests and build (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$build_steps}]"'
  print -r -- '      print -r -- "{\"workflowName\":\"macOS CI\",\"event\":\"push\",\"status\":\"completed\",\"conclusion\":\"success\",\"headBranch\":\"main\",\"headSha\":\"$main_sha\",\"jobs\":$main_jobs,\"url\":\"https://example.invalid/run/43\",\"updatedAt\":\"2026-08-20T10:00:00Z\"}"'
  print -r -- '      exit 0'
  print -r -- '    fi'
  print -r -- '    if [[ "$run_id" == "44" ]]; then'
  print -r -- '      pr_steps="[{\"name\":\"Reuse exact parent main CI for release metadata\",\"conclusion\":\"success\"}]"'
  print -r -- '      pr_jobs="[{\"name\":\"Swift tests and build (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$pr_steps},{\"name\":\"Swift tests and build (Intel Ventura)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$pr_steps}]"'
  print -r -- '      print -r -- "{\"workflowName\":\"macOS CI\",\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"success\",\"headBranch\":\"$head_branch\",\"headSha\":\"$head_commit\",\"jobs\":$pr_jobs,\"url\":\"https://example.invalid/run/44\",\"updatedAt\":\"2026-08-20T10:10:00Z\"}"'
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
  print -r -- '    print -r -- "{\"workflowName\":\"macOS Preview Candidate\",\"event\":\"push\",\"status\":\"completed\",\"conclusion\":\"$conclusion\",\"headBranch\":\"$head_branch\",\"headSha\":\"$head_sha\",\"jobs\":$jobs,\"url\":\"https://example.invalid/run/42\",\"updatedAt\":\"2026-08-20T10:05:00Z\"}"'
  print -r -- '    ;;'
  print -r -- '  api*)'
  print -r -- '    endpoint="${2:-}"'
  print -r -- '    preview_steps="[{\"name\":\"Reuse exact parent main product-code proof\",\"conclusion\":\"success\"}]"'
  print -r -- '    preview_jobs="[{\"name\":\"Validate and package preview candidate (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$preview_steps},{\"name\":\"Validate and package preview candidate (Intel Ventura)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$preview_steps}]"'
  print -r -- '    [[ "$mode" == "missing-intel" ]] && preview_jobs="[{\"name\":\"Validate and package preview candidate (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$preview_steps}]"'
  print -r -- '    pr_steps="[{\"name\":\"Reuse exact parent main CI for release metadata\",\"conclusion\":\"success\"}]"'
  print -r -- '    pr_jobs="[{\"name\":\"Swift tests and build (Apple Silicon)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$pr_steps},{\"name\":\"Swift tests and build (Intel Ventura)\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":$pr_steps}]"'
  print -r -- '    if [[ "$endpoint" == *"/actions/runs/42/attempts/1/jobs"* ]]; then'
  print -r -- '      print -r -- "{\"jobs\":$preview_jobs}"'
  print -r -- '    elif [[ "$endpoint" == *"/actions/runs/44/attempts/1/jobs"* ]]; then'
  print -r -- '      print -r -- "{\"jobs\":$pr_jobs}"'
  print -r -- '    elif [[ "$endpoint" == *"/actions/runs/42" ]]; then'
  print -r -- '      preview_path=".github/workflows/mac-preview-candidate.yml"; preview_sha="$head_commit"; preview_conclusion=success'
  print -r -- '      [[ "$mode" == "preview-wrong-workflow-path" ]] && preview_path=".github/workflows/mac-ci.yml"'
  print -r -- '      [[ "$mode" == "wrong-sha" ]] && preview_sha=0000000000000000000000000000000000000000'
  print -r -- '      [[ "$mode" == "failed" ]] && preview_conclusion=failure'
  print -r -- '      print -r -- "{\"name\":\"macOS Preview Candidate\",\"path\":\"$preview_path\",\"event\":\"push\",\"status\":\"completed\",\"conclusion\":\"$preview_conclusion\",\"head_branch\":\"$head_branch\",\"head_sha\":\"$preview_sha\",\"run_attempt\":1,\"updated_at\":\"2026-08-20T10:05:00Z\"}"'
  print -r -- '    elif [[ "$endpoint" == *"/actions/runs/44" ]]; then'
  print -r -- '      pr_path=".github/workflows/mac-ci.yml"'
  print -r -- '      [[ "$mode" == "pr-wrong-workflow-path" ]] && pr_path=".github/workflows/mac-preview-candidate.yml"'
  print -r -- '      print -r -- "{\"name\":\"macOS CI\",\"path\":\"$pr_path\",\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"success\",\"head_branch\":\"$head_branch\",\"head_sha\":\"$head_commit\",\"run_attempt\":1,\"updated_at\":\"2026-08-20T10:10:00Z\"}"'
  print -r -- '    else'
  print -r -- '      case "$mode" in'
  print -r -- '        duplicate-pr) raw_json="[{\"number\":9,\"html_url\":\"https://example.invalid/pr/9\",\"draft\":true,\"state\":\"open\",\"base\":{\"ref\":\"main\"},\"head\":{\"ref\":\"release/pre-v9.9.9\",\"sha\":\"$head_commit\",\"repo\":{\"full_name\":\"HD838A/remote-mic-app\"}}},{\"number\":10,\"html_url\":\"https://example.invalid/pr/10\",\"draft\":true,\"state\":\"open\",\"base\":{\"ref\":\"main\"},\"head\":{\"ref\":\"release/pre-v9.9.9-rerun\",\"sha\":\"$head_commit\",\"repo\":{\"full_name\":\"HD838A/remote-mic-app\"}}}]" ;;'
  print -r -- '        draft|pr-pending|pr-failed|checks-old-failure-new-success|checks-old-success-new-failure|pr-wrong-workflow-path) raw_json="[{\"number\":9,\"html_url\":\"https://example.invalid/pr/9\",\"draft\":true,\"state\":\"open\",\"base\":{\"ref\":\"main\"},\"head\":{\"ref\":\"$head_branch\",\"sha\":\"$head_commit\",\"repo\":{\"full_name\":\"HD838A/remote-mic-app\"}}}]" ;;'
  print -r -- '        non-draft) raw_json="[{\"number\":9,\"html_url\":\"https://example.invalid/pr/9\",\"draft\":false,\"state\":\"open\",\"base\":{\"ref\":\"main\"},\"head\":{\"ref\":\"$head_branch\",\"sha\":\"$head_commit\",\"repo\":{\"full_name\":\"HD838A/remote-mic-app\"}}}]" ;;'
  print -r -- '        success)'
  print -r -- '          if [[ -n "${FAKE_GH_LOG:-}" && -f "$FAKE_GH_LOG" ]] && /usr/bin/grep -Fq "pr create" "$FAKE_GH_LOG"; then'
  print -r -- '            raw_json="[{\"number\":10,\"html_url\":\"https://example.invalid/pr/10\",\"draft\":true,\"state\":\"open\",\"base\":{\"ref\":\"main\"},\"head\":{\"ref\":\"$head_branch\",\"sha\":\"$head_commit\",\"repo\":{\"full_name\":\"HD838A/remote-mic-app\"}}}]"'
  print -r -- '          else raw_json="[]"; fi ;;'
  print -r -- '        *) raw_json="[]" ;;'
  print -r -- '      esac'
  print -r -- '      jq_filter=""'
  print -r -- '      arguments=("$@")'
  print -r -- '      for (( argument_index = 1; argument_index <= ${#arguments}; argument_index++ )); do'
  print -r -- '        if [[ "${arguments[$argument_index]}" == "--jq" ]]; then jq_filter="${arguments[$(( argument_index + 1 ))]}"; break; fi'
  print -r -- '      done'
  print -r -- '      if [[ -n "$jq_filter" ]]; then print -r -- "$raw_json" | jq -c "$jq_filter"; else print -r -- "$raw_json"; fi'
  print -r -- '    fi'
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
  print -r -- '    if [[ "$mode" == "checks-old-failure-new-success" ]]; then'
  print -r -- '      print -r -- '\''{"statusCheckRollup":[{"workflowName":"macOS CI","name":"Swift tests and build (Apple Silicon)","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-20T10:10:00Z","detailsUrl":"https://github.com/HD838A/remote-mic-app/actions/runs/44/job/4401"},{"workflowName":"macOS CI","name":"Swift tests and build (Apple Silicon)","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-08-20T10:00:00Z","detailsUrl":"https://github.com/HD838A/remote-mic-app/actions/runs/41/job/4101"},{"workflowName":"macOS CI","name":"Swift tests and build (Intel Ventura)","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-20T10:10:00Z","detailsUrl":"https://github.com/HD838A/remote-mic-app/actions/runs/44/job/4402"}]}'\'''
  print -r -- '    elif [[ "$mode" == "checks-old-success-new-failure" ]]; then'
  print -r -- '      print -r -- '\''{"statusCheckRollup":[{"workflowName":"macOS CI","name":"Swift tests and build (Apple Silicon)","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-08-20T10:10:00Z","detailsUrl":"https://github.com/HD838A/remote-mic-app/actions/runs/44/job/4401"},{"workflowName":"macOS CI","name":"Swift tests and build (Apple Silicon)","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-20T10:00:00Z","detailsUrl":"https://github.com/HD838A/remote-mic-app/actions/runs/41/job/4101"},{"workflowName":"macOS CI","name":"Swift tests and build (Intel Ventura)","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-20T10:10:00Z","detailsUrl":"https://github.com/HD838A/remote-mic-app/actions/runs/44/job/4402"}]}'\'''
  print -r -- '    else'
  print -r -- '      print -r -- "{\"statusCheckRollup\":[{\"workflowName\":\"macOS CI\",\"name\":\"Swift tests and build (Apple Silicon)\",\"status\":\"$apple_status\",\"conclusion\":\"$apple_conclusion\",\"startedAt\":\"2026-08-20T10:10:00Z\",\"detailsUrl\":\"https://github.com/HD838A/remote-mic-app/actions/runs/44/job/4401\"},{\"workflowName\":\"macOS CI\",\"name\":\"Swift tests and build (Intel Ventura)\",\"status\":\"$intel_status\",\"conclusion\":\"$intel_conclusion\",\"startedAt\":\"2026-08-20T10:10:00Z\",\"detailsUrl\":\"https://github.com/HD838A/remote-mic-app/actions/runs/44/job/4402\"}]}"'
  print -r -- '    fi'
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

jq '. + {candidateGateCompletedAt:"2026-08-20T10:05:00Z"}' \
  "$WORK_DIR/main-proof.json" > "$WORK_DIR/release-ready-proof.json"

QUALIFICATION_RUN_ID=77
QUALIFICATION_RUN_ATTEMPT=2
/bin/mkdir -p "$WORK_DIR/qualification-artifact"
jq -n \
  --arg pipelineDigest "$QUALIFICATION_DIGEST" \
  --arg sourceCommit "$HEAD_COMMIT" \
  --arg sourceBranch "$QUALIFICATION_BRANCH" \
  --argjson sourcePullRequest 999 \
  --argjson workflowRunId "$QUALIFICATION_RUN_ID" \
  --argjson workflowRunAttempt "$QUALIFICATION_RUN_ATTEMPT" \
  --arg qualifiedAt "2026-08-20T10:06:00Z" \
  --arg ageVersion "v1.3.1" \
  --arg fastlaneVersion "2.237.0" \
  --arg xcodeVersion "26.4" \
  --arg xcodeBuild "17E192" \
  --arg imageOS "macos15" \
  --arg imageVersion "20260817.1" \
  --arg jqVersion "jq-1.7.1" \
  --arg ripgrepVersion "15.0.0" \
  --arg ghVersion "2.78.0" \
  --arg gitVersion "git version 2.50.1" \
  --arg swiftVersion "Apple Swift version 6.2" \
  '{
    schemaVersion:2,
    pipelineDigest:$pipelineDigest,
    sourceCommit:$sourceCommit,
    sourceBranch:$sourceBranch,
    sourcePullRequest:$sourcePullRequest,
    workflowRunId:$workflowRunId,
    workflowRunAttempt:$workflowRunAttempt,
    qualifiedAt:$qualifiedAt,
    expectedTeamId:"L3QHLDRPAY",
    ageVersion:$ageVersion,
    fastlaneVersion:$fastlaneVersion,
    xcodeVersion:$xcodeVersion,
    xcodeBuild:$xcodeBuild,
    imageOS:$imageOS,
    imageVersion:$imageVersion,
    jqVersion:$jqVersion,
    ripgrepVersion:$ripgrepVersion,
    ghVersion:$ghVersion,
    gitVersion:$gitVersion,
    swiftVersion:$swiftVersion,
    externalDependencies:{
      actionsCheckoutCommit:"fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
      actionsDownloadArtifactCommit:"634f93cb2916e3fdff6788551b99b062d0335ce0",
      actionsUploadArtifactCommit:"ea165f8d65b6e75b540449e92b4886f43607fa02",
      notarySecretsCommit:"5baaeaf56f6cd5fbd0fb0e08c9290077ba8b5b5d",
      matchCommit:"2e271768593821611c54f3d1b376f39e503f53be",
      sayAllAICommit:"01beeceac9c4091e7e8e122ad1e840ac5e5cee1c",
      sayAllMacroPlatformCommit:"b71482ccb3c5d3be319abe7cd61915ab90cbc3ba",
      sayAllMacRemoteCommit:"3f3c782180eef4024b53941c1f65d80e7cff4c66"
    }
  }' \
  > "$WORK_DIR/qualification-artifact/release-pipeline-qualification.json"
(
  cd "$WORK_DIR/qualification-artifact"
  /usr/bin/zip -q "$WORK_DIR/qualification-artifact.zip" \
    release-pipeline-qualification.json
)
QUALIFICATION_ARTIFACT_DIGEST="sha256:$(
  /usr/bin/shasum -a 256 "$WORK_DIR/qualification-artifact.zip" | \
    /usr/bin/awk '{ print $1 }'
)"
{
  print '#!/bin/zsh'
  print 'set -euo pipefail'
  print 'endpoint="$*"'
  print 'mode="${FAKE_QUALIFICATION_ARTIFACT_MODE:-valid}"'
  print 'if [[ "$endpoint" == *"actions/artifacts?name="* ]]; then'
  print '  artifact_run_id=77'
  print '  [[ "$mode" == "artifact-run-mismatch" ]] && artifact_run_id=88'
  print '  artifact_digest="$FAKE_QUALIFICATION_ARTIFACT_DIGEST"'
  print '  [[ "$mode" == "artifact-digest-malformed" ]] && artifact_digest="sha256:invalid"'
  print -r -- '  print -r -- "{\"artifacts\":[{\"id\":91,\"expired\":false,\"created_at\":\"2026-08-20T10:06:30Z\",\"digest\":\"$artifact_digest\",\"workflow_run\":{\"id\":$artifact_run_id}}]}"'
  print 'elif [[ "$endpoint" == *"actions/artifacts/91/zip"* ]]; then'
  print '  /bin/cat "$FAKE_QUALIFICATION_ARTIFACT_ZIP"'
  print 'elif [[ "$endpoint" == *"actions/runs/77/attempts/2/jobs"* ]]; then'
  print -r -- '  print -r -- "{\"jobs\":[{\"name\":\"Verify exact preview candidate CI and Draft recording PR\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":[{\"name\":\"Verify exact candidate or pipeline qualification provenance\",\"conclusion\":\"success\"}]},{\"name\":\"Sign and notarize Apple Silicon and Intel packages\",\"status\":\"completed\",\"conclusion\":\"success\",\"steps\":[{\"name\":\"Sign, notarize, staple, and verify both variants\",\"conclusion\":\"success\"},{\"name\":\"Record protected release pipeline qualification\",\"conclusion\":\"success\"},{\"name\":\"Upload protected release pipeline qualification\",\"conclusion\":\"success\"}]}]}"'
  print 'elif [[ "$endpoint" == *"actions/runs/77/attempts/2"* ]]; then'
  print '  run_attempt=2; run_sha="$FAKE_QUALIFICATION_SOURCE_COMMIT"; run_branch="$FAKE_QUALIFICATION_SOURCE_BRANCH"; run_path=".github/workflows/mac-release-package.yml"'
  print '  [[ "$mode" == "run-attempt-mismatch" ]] && run_attempt=3'
  print '  [[ "$mode" == "run-sha-mismatch" ]] && run_sha=0000000000000000000000000000000000000000'
  print '  [[ "$mode" == "run-branch-mismatch" ]] && run_branch=release/pipeline-qualification/other'
  print '  [[ "$mode" == "run-workflow-mismatch" ]] && run_path=".github/workflows/mac-ci.yml"'
  print -r -- '  print -r -- "{\"event\":\"workflow_dispatch\",\"status\":\"completed\",\"conclusion\":\"success\",\"head_branch\":\"$run_branch\",\"head_sha\":\"$run_sha\",\"run_attempt\":$run_attempt,\"path\":\"$run_path\",\"created_at\":\"2026-08-20T10:00:00Z\",\"updated_at\":\"2026-08-20T10:07:00Z\"}"'
  print 'elif [[ "$endpoint" == *"pulls/999"* ]]; then'
  print -r -- '  print -r -- "{\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$FAKE_QUALIFICATION_SOURCE_COMMIT\",\"repo\":{\"full_name\":\"HD838A/remote-mic-app\"}},\"merged_at\":\"2026-08-20T10:08:00Z\"}"'
  print 'else'
  print '  print -u2 "unexpected fake qualification artifact API: $endpoint"'
  print '  exit 2'
  print 'fi'
} > "$FAKE_QUALIFICATION_ARTIFACT_GH"
/bin/chmod 755 "$FAKE_QUALIFICATION_ARTIFACT_GH"

(
  cd "$TEST_REPO"
  GH_BIN="$FAKE_QUALIFICATION_ARTIFACT_GH" \
  GITHUB_REPOSITORY=HD838A/remote-mic-app \
  RELEASE_QUALIFICATION_REMOTE_NAME="$QUALIFICATION_REMOTE" \
  FAKE_QUALIFICATION_ARTIFACT_ZIP="$WORK_DIR/qualification-artifact.zip" \
  FAKE_QUALIFICATION_ARTIFACT_DIGEST="$QUALIFICATION_ARTIFACT_DIGEST" \
  FAKE_QUALIFICATION_SOURCE_COMMIT="$HEAD_COMMIT" \
  FAKE_QUALIFICATION_SOURCE_BRANCH="$QUALIFICATION_BRANCH" \
  RELEASE_READY_PROOF_OUTPUT="$WORK_DIR/release-ready-proof.json" \
  RELEASE_QUALIFICATION_WORK_DIR="$WORK_DIR/qualification-proof-pass" \
    ./scripts/verify-release-pipeline-qualification.sh "$QUALIFICATION_DIGEST"
) > "$WORK_DIR/qualification-artifact-pass.txt"
/usr/bin/grep -Fq 'RELEASE PIPELINE QUALIFICATION PASS' \
  "$WORK_DIR/qualification-artifact-pass.txt"
test "$(jq -r '.pipelineDigest' "$WORK_DIR/release-ready-proof.json")" = \
  "$QUALIFICATION_DIGEST"
test "$(jq -r '.pipelineQualificationRunId' "$WORK_DIR/release-ready-proof.json")" = \
  "$QUALIFICATION_RUN_ID"
test "$(jq -r '.pipelineQualifiedAt' "$WORK_DIR/release-ready-proof.json")" = \
  "2026-08-20T10:06:30Z"
test "$(jq -r '.pipelineQualificationArtifactId' "$WORK_DIR/release-ready-proof.json")" = \
  "91"
test "$(jq -r '.pipelineQualificationArtifactDigest' "$WORK_DIR/release-ready-proof.json")" = \
  "$QUALIFICATION_ARTIFACT_DIGEST"
test "$(jq -r '.ageVersion' "$WORK_DIR/release-ready-proof.json")" = "v1.3.1"
test "$(jq -r '.fastlaneVersion' "$WORK_DIR/release-ready-proof.json")" = "2.237.0"
test "$(jq -r '.xcodeVersion' "$WORK_DIR/release-ready-proof.json")" = "26.4"
test "$(jq -r '.xcodeBuild' "$WORK_DIR/release-ready-proof.json")" = "17E192"
test "$(jq -r '.imageOS' "$WORK_DIR/release-ready-proof.json")" = "macos15"
test "$(jq -r '.imageVersion' "$WORK_DIR/release-ready-proof.json")" = "20260817.1"
test "$(jq -r '.jqVersion' "$WORK_DIR/release-ready-proof.json")" = "jq-1.7.1"
test "$(jq -r '.ripgrepVersion' "$WORK_DIR/release-ready-proof.json")" = "15.0.0"
test "$(jq -r '.ghVersion' "$WORK_DIR/release-ready-proof.json")" = "2.78.0"
test "$(jq -r '.gitVersion' "$WORK_DIR/release-ready-proof.json")" = \
  "git version 2.50.1"
test "$(jq -r '.swiftVersion' "$WORK_DIR/release-ready-proof.json")" = \
  "Apple Swift version 6.2"
jq -e '.externalDependencies == {
  actionsCheckoutCommit:"fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
  actionsDownloadArtifactCommit:"634f93cb2916e3fdff6788551b99b062d0335ce0",
  actionsUploadArtifactCommit:"ea165f8d65b6e75b540449e92b4886f43607fa02",
  notarySecretsCommit:"5baaeaf56f6cd5fbd0fb0e08c9290077ba8b5b5d",
  matchCommit:"2e271768593821611c54f3d1b376f39e503f53be",
  sayAllAICommit:"01beeceac9c4091e7e8e122ad1e840ac5e5cee1c",
  sayAllMacroPlatformCommit:"b71482ccb3c5d3be319abe7cd61915ab90cbc3ba",
  sayAllMacRemoteCommit:"3f3c782180eef4024b53941c1f65d80e7cff4c66"
}' "$WORK_DIR/release-ready-proof.json" >/dev/null

for qualification_failure_mode in \
  artifact-digest-malformed \
  artifact-run-mismatch \
  run-attempt-mismatch \
  run-sha-mismatch \
  run-branch-mismatch \
  run-workflow-mismatch; do
  if (
    cd "$TEST_REPO"
    GH_BIN="$FAKE_QUALIFICATION_ARTIFACT_GH" \
    GITHUB_REPOSITORY=HD838A/remote-mic-app \
    RELEASE_QUALIFICATION_REMOTE_NAME="$QUALIFICATION_REMOTE" \
    FAKE_QUALIFICATION_ARTIFACT_MODE="$qualification_failure_mode" \
    FAKE_QUALIFICATION_ARTIFACT_ZIP="$WORK_DIR/qualification-artifact.zip" \
    FAKE_QUALIFICATION_ARTIFACT_DIGEST="$QUALIFICATION_ARTIFACT_DIGEST" \
    FAKE_QUALIFICATION_SOURCE_COMMIT="$HEAD_COMMIT" \
    FAKE_QUALIFICATION_SOURCE_BRANCH="$QUALIFICATION_BRANCH" \
    RELEASE_QUALIFICATION_WORK_DIR="$WORK_DIR/qualification-$qualification_failure_mode" \
      ./scripts/verify-release-pipeline-qualification.sh "$QUALIFICATION_DIGEST"
  ) > "$WORK_DIR/qualification-$qualification_failure_mode.txt" 2>&1; then
    print -u2 "release qualification unexpectedly accepted artifact/run mismatch: $qualification_failure_mode"
    exit 1
  fi
  /usr/bin/grep -Fq 'no successful protected qualification exists' \
    "$WORK_DIR/qualification-$qualification_failure_mode.txt"
done

{
  print '#!/bin/zsh'
  print 'set -euo pipefail'
  print 'if [[ "$*" == *"releases/tags/v9.9.9"* || "$*" == *"release view v9.9.9"* ]]; then'
  print '  case "${FAKE_ATTEST_RELEASE_MODE:-valid}" in'
  print '    missing) exit 1 ;;'
  print '    stable) print -r -- '\''{"tag_name":"v9.9.9","draft":false,"prerelease":false}'\'' ;;'
  print '    *) print -r -- '\''{"tag_name":"v9.9.9","draft":false,"prerelease":true}'\'' ;;'
  print '  esac'
  print 'elif [[ "$*" == *"actions/artifacts?name="* ]]; then'
  print '  artifact_query="${*#*name=}"'
  print '  requested_artifact_name="${artifact_query%%&*}"'
  print '  if [[ -n "${FAKE_ATTEST_ZIP:-}" && "$requested_artifact_name" == "${FAKE_ATTEST_ARTIFACT_NAME:-}" ]]; then print -r -- '\''{"artifacts":[{"id":91,"expired":false,"workflow_run":{"id":101}}]}'\''; else print -r -- '\''{"artifacts":[]}'\''; fi'
  print 'elif [[ "$*" == *"actions/artifacts/91/zip"* ]]; then'
  print '  /bin/cat "$FAKE_ATTEST_ZIP"'
  print 'elif [[ "$*" == *"actions/runs/101/attempts/1/jobs"* ]]; then'
  print '  print -r -- '\''{"jobs":[{"name":"Verify exact preview candidate CI and Draft recording PR","status":"completed","conclusion":"success","steps":[{"name":"Resolve immutable request attestation","conclusion":"success"},{"name":"Persist first request timestamps","conclusion":"success"}]}]}'\'''
  print 'elif [[ "$*" == *"actions/runs/101/attempts/1"* ]]; then'
  print -r -- '  print -r -- "{\"event\":\"workflow_dispatch\",\"head_branch\":\"release/pre-v9.9.9\",\"head_sha\":\"$FAKE_ATTEST_CANDIDATE_COMMIT\",\"run_attempt\":1,\"path\":\".github/workflows/mac-release-package.yml\"}"'
  print 'else exit 2; fi'
} > "$FAKE_ATTEST_GH"
/bin/chmod 755 "$FAKE_ATTEST_GH"

GH_BIN="$FAKE_ATTEST_GH" GITHUB_REPOSITORY=HD838A/remote-mic-app \
  GITHUB_RUN_ID=101 GITHUB_RUN_ATTEMPT=1 GITHUB_REF_NAME=release/pre-v9.9.9 \
  FAKE_ATTEST_CANDIDATE_COMMIT="$HEAD_COMMIT" \
  "$ROOT/scripts/resolve-release-request-attestation.sh" \
    req-12345 v9.9.9 1787219000 \
    "$HEAD_COMMIT" \
    "$WORK_DIR/release-ready-proof.json" "$WORK_DIR/release-request-attestation.json" \
    > "$WORK_DIR/attestation-first.txt"
/usr/bin/grep -Fq 'RELEASE REQUEST ATTESTATION PASS' "$WORK_DIR/attestation-first.txt"
test "$(jq -r '.schemaVersion' "$WORK_DIR/release-request-attestation.json")" = "4"
test "$(jq -r '.attemptId' "$WORK_DIR/release-request-attestation.json")" = "$HEAD_COMMIT"
test "$(jq -r '.releaseReadyAt' "$WORK_DIR/release-request-attestation.json")" = "1787220390"
test "$(jq -r '.candidateGateCompletedAt' "$WORK_DIR/release-request-attestation.json")" = "2026-08-20T10:05:00Z"
test "$(jq -r '.pipelineQualifiedAt' "$WORK_DIR/release-request-attestation.json")" = "2026-08-20T10:06:30Z"
test "$(jq -r '.pipelineQualificationRunId' "$WORK_DIR/release-request-attestation.json")" = "$QUALIFICATION_RUN_ID"
test "$(jq -r '.pipelineDigest' "$WORK_DIR/release-request-attestation.json")" = "$QUALIFICATION_DIGEST"
test "$(jq -r '.pipelineQualificationArtifactId' "$WORK_DIR/release-request-attestation.json")" = "91"
test "$(jq -r '.pipelineQualificationArtifactDigest' "$WORK_DIR/release-request-attestation.json")" = "$QUALIFICATION_ARTIFACT_DIGEST"
jq -e --slurpfile proof "$WORK_DIR/release-ready-proof.json" '
  .ageVersion == $proof[0].ageVersion and
  .fastlaneVersion == $proof[0].fastlaneVersion and
  .xcodeVersion == $proof[0].xcodeVersion and
  .xcodeBuild == $proof[0].xcodeBuild and
  .imageOS == $proof[0].imageOS and
  .imageVersion == $proof[0].imageVersion and
  .jqVersion == $proof[0].jqVersion and
  .ripgrepVersion == $proof[0].ripgrepVersion and
  .ghVersion == $proof[0].ghVersion and
  .gitVersion == $proof[0].gitVersion and
  .swiftVersion == $proof[0].swiftVersion and
  .externalDependencies == $proof[0].externalDependencies
' "$WORK_DIR/release-request-attestation.json" >/dev/null
/bin/mkdir -p "$WORK_DIR/attestation-artifact"
/bin/cp "$WORK_DIR/release-request-attestation.json" \
  "$WORK_DIR/attestation-artifact/release-request-attestation.json"
(cd "$WORK_DIR/attestation-artifact" && /usr/bin/zip -q "$WORK_DIR/attestation.zip" release-request-attestation.json)
if GH_BIN="$FAKE_ATTEST_GH" FAKE_ATTEST_ZIP="$WORK_DIR/attestation.zip" \
   FAKE_ATTEST_ARTIFACT_NAME="release-request-attestation-v9.9.9-$HEAD_COMMIT" \
   GITHUB_REPOSITORY=HD838A/remote-mic-app \
   GITHUB_RUN_ID=102 GITHUB_RUN_ATTEMPT=1 GITHUB_REF_NAME=release/pre-v9.9.9 \
   FAKE_ATTEST_CANDIDATE_COMMIT="$HEAD_COMMIT" \
    "$ROOT/scripts/resolve-release-request-attestation.sh" \
      req-12345 v9.9.9 1787219060 \
      "$HEAD_COMMIT" \
      "$WORK_DIR/release-ready-proof.json" "$WORK_DIR/release-request-attestation-late.json" \
      > "$WORK_DIR/attestation-late.txt" 2>&1; then
  print -u2 "release request attestation allowed a later retry timestamp"
  exit 1
fi
/usr/bin/grep -Fq 'timestamps/identity are immutable' "$WORK_DIR/attestation-late.txt"

if GH_BIN="$FAKE_ATTEST_GH" FAKE_ATTEST_ZIP="$WORK_DIR/attestation.zip" \
   FAKE_ATTEST_ARTIFACT_NAME="release-request-attestation-v9.9.9-$HEAD_COMMIT" \
   GITHUB_REPOSITORY=HD838A/remote-mic-app \
   GITHUB_RUN_ID=102 GITHUB_RUN_ATTEMPT=1 GITHUB_REF_NAME=release/pre-v9.9.9 \
   FAKE_ATTEST_CANDIDATE_COMMIT="$HEAD_COMMIT" \
    "$ROOT/scripts/resolve-release-request-attestation.sh" \
      req-replaced v9.9.9 1787219000 \
      "$HEAD_COMMIT" \
      "$WORK_DIR/release-ready-proof.json" "$WORK_DIR/release-request-attestation-replaced.json" \
      > "$WORK_DIR/attestation-replaced.txt" 2>&1; then
  print -u2 "release request attestation allowed a second identity for one candidate"
  exit 1
fi
/usr/bin/grep -Fq 'immutable for candidate' "$WORK_DIR/attestation-replaced.txt"

jq '.candidateGateCompletedAt = "2026-08-20T10:10:00Z"' \
  "$WORK_DIR/release-ready-proof.json" > "$WORK_DIR/retried-release-ready-proof.json"
GH_BIN="$FAKE_ATTEST_GH" FAKE_ATTEST_ZIP="$WORK_DIR/attestation.zip" \
  FAKE_ATTEST_ARTIFACT_NAME="release-request-attestation-v9.9.9-$HEAD_COMMIT" \
  GITHUB_REPOSITORY=HD838A/remote-mic-app \
  GITHUB_RUN_ID=102 GITHUB_RUN_ATTEMPT=1 GITHUB_REF_NAME=release/pre-v9.9.9 \
  FAKE_ATTEST_CANDIDATE_COMMIT="$HEAD_COMMIT" \
  "$ROOT/scripts/resolve-release-request-attestation.sh" \
    req-12345 v9.9.9 1787219000 "$HEAD_COMMIT" \
    "$WORK_DIR/retried-release-ready-proof.json" "$WORK_DIR/release-request-attestation-retry.json" \
    > "$WORK_DIR/attestation-retry.txt"
test "$(jq -r '.releaseReadyAt' "$WORK_DIR/release-request-attestation-retry.json")" = "1787220390"

if GH_BIN="$FAKE_ATTEST_GH" GITHUB_REPOSITORY=HD838A/remote-mic-app \
  GITHUB_RUN_ID=103 GITHUB_RUN_ATTEMPT=1 GITHUB_REF_NAME=release/pre-v9.9.8 \
  FAKE_ATTEST_CANDIDATE_COMMIT="$HEAD_COMMIT" \
  "$ROOT/scripts/resolve-release-request-attestation.sh" \
    req-12345 v9.9.8 1787219000 "$HEAD_COMMIT" \
    "$WORK_DIR/main-proof.json" "$WORK_DIR/release-request-attestation-missing-gate.json" \
    > "$WORK_DIR/attestation-missing-gate.txt" 2>&1; then
  print -u2 "release request attestation accepted a missing candidate gate timestamp"
  exit 1
fi
/usr/bin/grep -Fq 'lacks a trusted main/candidate/pipeline qualification timestamp or identity' \
  "$WORK_DIR/attestation-missing-gate.txt"

GH_BIN="$FAKE_ATTEST_GH" GITHUB_REPOSITORY=HD838A/remote-mic-app \
  "$ROOT/scripts/resolve-stable-request-attestation.sh" \
    stable-req-12345 v9.9.9 1787221000 "$WORK_DIR/stable-request-attestation.json" \
    > "$WORK_DIR/stable-attestation-first.txt"
/usr/bin/grep -Fq 'STABLE REQUEST ATTESTATION PASS' "$WORK_DIR/stable-attestation-first.txt"
if GH_BIN="$FAKE_ATTEST_GH" FAKE_ATTEST_RELEASE_MODE=stable \
  GITHUB_REPOSITORY=HD838A/remote-mic-app \
  "$ROOT/scripts/resolve-stable-request-attestation.sh" \
    stable-req-invalid v9.9.9 1787221000 "$WORK_DIR/stable-request-attestation-invalid.json" \
    > "$WORK_DIR/stable-attestation-invalid.txt" 2>&1; then
  print -u2 "stable request attestation accepted a stable release as its promotion source"
  exit 1
fi
/usr/bin/grep -Fq 'stable promotion source must be an existing published pre-release' \
  "$WORK_DIR/stable-attestation-invalid.txt"
/bin/mkdir -p "$WORK_DIR/stable-attestation-artifact"
/bin/cp "$WORK_DIR/stable-request-attestation.json" \
  "$WORK_DIR/stable-attestation-artifact/stable-request-attestation.json"
(cd "$WORK_DIR/stable-attestation-artifact" && /usr/bin/zip -q "$WORK_DIR/stable-attestation.zip" stable-request-attestation.json)
if GH_BIN="$FAKE_ATTEST_GH" FAKE_ATTEST_ZIP="$WORK_DIR/stable-attestation.zip" \
  FAKE_ATTEST_ARTIFACT_NAME="stable-request-attestation-v9.9.9" \
  GITHUB_REPOSITORY=HD838A/remote-mic-app \
  "$ROOT/scripts/resolve-stable-request-attestation.sh" \
    stable-req-12345 v9.9.9 1787221060 "$WORK_DIR/stable-request-attestation-late.json" \
    > "$WORK_DIR/stable-attestation-late.txt" 2>&1; then
  print -u2 "stable request attestation allowed a retry to reset its timestamp"
  exit 1
fi
/usr/bin/grep -Fq 'stable request timestamp/identity is immutable' \
  "$WORK_DIR/stable-attestation-late.txt"

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
if (
  cd "$METADATA_REPO"
  "$ROOT/scripts/verify-release-metadata-diff.sh" \
    "$METADATA_BASE" "$METADATA_HEAD" release/pre-v9.9.9-rerun2
) > "$WORK_DIR/metadata-rerun-rejected.txt" 2>&1; then
  print -u2 "numbered rerun branch unexpectedly passed release metadata verification"
  exit 1
fi
/usr/bin/grep -Fq 'single candidate branch release/pre-vX.Y.Z' \
  "$WORK_DIR/metadata-rerun-rejected.txt"
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

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" \
    FAKE_GH_MODE=preview-wrong-workflow-path \
    ./scripts/verify-preview-candidate-ci.sh 42
) > "$WORK_DIR/candidate-wrong-workflow-path.txt" 2>&1; then
  print -u2 "candidate verification accepted a Run from the wrong workflow path"
  exit 1
fi
/usr/bin/grep -Fq 'unexpected workflow provenance' \
  "$WORK_DIR/candidate-wrong-workflow-path.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9-rerun2 \
    FAKE_HEAD_BRANCH=release/pre-v9.9.9-rerun2 \
    RELEASE_TAG=v9.9.9 GH_BIN="$FAKE_GH" \
    ./scripts/verify-preview-candidate-ci.sh 42
) > "$WORK_DIR/candidate-rerun-rejected.txt" 2>&1; then
  print -u2 "numbered rerun branch unexpectedly passed candidate CI verification"
  exit 1
fi
/usr/bin/grep -Fq 'single candidate branch release/pre-vX.Y.Z' \
  "$WORK_DIR/candidate-rerun-rejected.txt"

(
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" FAKE_GH_MODE=draft \
    REQUIRE_PREVIEW_RECORDING_PR=1 RELEASE_TAG=v9.9.9 \
    ./scripts/verify-preview-candidate-ci.sh 42
) > "$WORK_DIR/candidate-draft-pass.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" \
    FAKE_GH_MODE=pr-wrong-workflow-path \
    REQUIRE_PREVIEW_RECORDING_PR=1 RELEASE_TAG=v9.9.9 \
    ./scripts/verify-preview-candidate-ci.sh 42
) > "$WORK_DIR/candidate-pr-wrong-workflow-path.txt" 2>&1; then
  print -u2 "candidate verification accepted PR checks from the wrong workflow path"
  exit 1
fi
/usr/bin/grep -Fq 'unexpected workflow path or run identity' \
  "$WORK_DIR/candidate-pr-wrong-workflow-path.txt"

(
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" \
    FAKE_GH_MODE=checks-old-failure-new-success \
    REQUIRE_PREVIEW_RECORDING_PR=1 RELEASE_TAG=v9.9.9 \
    ./scripts/verify-preview-candidate-ci.sh 42
) > "$WORK_DIR/candidate-latest-check-success.txt"
/usr/bin/grep -Fq 'PREVIEW CANDIDATE CI PASS' \
  "$WORK_DIR/candidate-latest-check-success.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" \
    FAKE_GH_MODE=checks-old-success-new-failure \
    REQUIRE_PREVIEW_RECORDING_PR=1 RELEASE_TAG=v9.9.9 \
    ./scripts/verify-preview-candidate-ci.sh 42
) > "$WORK_DIR/candidate-latest-check-failure.txt" 2>&1; then
  print -u2 "candidate verification accepted a latest failed check because an older run passed"
  exit 1
fi
/usr/bin/grep -Fq 'requires successful exact-SHA Draft PR' \
  "$WORK_DIR/candidate-latest-check-failure.txt"

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

print -r -- "{\"mode\":\"preview\",\"requestId\":\"req-12345\",\"target\":\"release/pre-v9.9.9-rerun2\",\"requestStartedAt\":$watchdog_now,\"releaseReadyAt\":$watchdog_now,\"status\":\"published-and-verified\"}" > "$WORK_DIR/watchdog-recovery-complete"
if GH_BIN="$FAKE_WATCHDOG_GH" FAKE_WATCHDOG_LOG="$WORK_DIR/watchdog-rerun-rejected.log" \
  "$TEST_REPO/scripts/release-user-wall-watchdog.sh" preview \
    "$watchdog_now" "$watchdog_now" req-12345 release/pre-v9.9.9-rerun2 "$WORK_DIR/watchdog-recovery-complete" "$WORK_DIR/watchdog-empty-runs" \
    > "$WORK_DIR/watchdog-rerun-rejected.txt" 2>&1; then
  print -u2 "preview watchdog unexpectedly accepted a numbered rerun target"
  exit 1
fi
/usr/bin/grep -Fq 'single candidate branch release/pre-vX.Y.Z' \
  "$WORK_DIR/watchdog-rerun-rejected.txt"

print -r -- "{\"mode\":\"preview\",\"requestId\":\"wrong-request\",\"target\":\"release/pre-v9.9.9\",\"requestStartedAt\":$watchdog_now,\"releaseReadyAt\":$watchdog_now,\"status\":\"published-and-verified\"}" > "$WORK_DIR/watchdog-wrong-complete"
set +e
GH_BIN="$FAKE_WATCHDOG_GH" FAKE_WATCHDOG_LOG="$WORK_DIR/watchdog-wrong.log" \
RELEASE_WATCHDOG_POLL_SECONDS=1 \
  "$TEST_REPO/scripts/release-user-wall-watchdog.sh" preview \
    "$(( watchdog_now - 1900 ))" "$(( watchdog_now - 1800 ))" req-12345 release/pre-v9.9.9 "$WORK_DIR/watchdog-wrong-complete" "$WORK_DIR/watchdog-empty-runs" \
    > "$WORK_DIR/watchdog-wrong.txt" 2>&1
wrong_completion_status="$?"
set -e
test "$wrong_completion_status" = "124"
/usr/bin/grep -Fq 'Ignoring completion file with mismatched release identity' "$WORK_DIR/watchdog-wrong.txt"

set +e
GH_BIN="$FAKE_WATCHDOG_GH" FAKE_WATCHDOG_LOG="$WORK_DIR/watchdog-expired.log" \
RELEASE_WATCHDOG_POLL_SECONDS=1 \
  "$TEST_REPO/scripts/release-user-wall-watchdog.sh" preview \
    "$(( $(date +%s) - 1900 ))" "$(( $(date +%s) - 1800 ))" req-12345 release/pre-v9.9.9 "$WORK_DIR/watchdog-never-completes" "$WORK_DIR/watchdog-empty-runs" \
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

(
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" FAKE_GH_MODE=draft \
    ./scripts/prepare-preview-recording-pr.sh
) > "$WORK_DIR/existing-draft-pr.txt"
/usr/bin/grep -Fq 'PREVIEW RECORDING DRAFT PR READY' \
  "$WORK_DIR/existing-draft-pr.txt"
/usr/bin/grep -Fq \
  'PREVIEW RECORDING DRAFT PR READY: https://example.invalid/pr/9' \
  "$WORK_DIR/existing-draft-pr.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" FAKE_GH_MODE=non-draft \
    ./scripts/prepare-preview-recording-pr.sh
) > "$WORK_DIR/non-draft-pr.txt" 2>&1; then
  print -u2 "prepare script unexpectedly accepted a non-Draft PR"
  exit 1
fi

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" FAKE_GH_MODE=duplicate-pr \
    ./scripts/prepare-preview-recording-pr.sh
) > "$WORK_DIR/duplicate-pr.txt" 2>&1; then
  print -u2 "prepare script unexpectedly accepted duplicate recording PRs"
  exit 1
fi
/usr/bin/grep -Fq 'multiple open main recording PRs' "$WORK_DIR/duplicate-pr.txt"

if (
  cd "$TEST_REPO"
  GITHUB_REF_NAME=release/pre-v9.9.9 GH_BIN="$FAKE_GH" FAKE_GH_MODE=duplicate-pr \
    REQUIRE_PREVIEW_RECORDING_PR=1 RELEASE_TAG=v9.9.9 \
    ./scripts/verify-preview-candidate-ci.sh 42
) > "$WORK_DIR/candidate-duplicate-pr.txt" 2>&1; then
  print -u2 "candidate verification unexpectedly accepted duplicate recording PRs"
  exit 1
fi
/usr/bin/grep -Fq 'exact-SHA Draft preview recording PR' "$WORK_DIR/candidate-duplicate-pr.txt"

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

"$ROOT/scripts/test-release-resume-workflow.sh"

print "RELEASE PIPELINE OPTIMIZATION TEST PASS"
print "HEAD: $HEAD_COMMIT"
