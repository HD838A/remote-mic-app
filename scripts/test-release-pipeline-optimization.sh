#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-release-pipeline-test.XXXXXX)"
TEST_REPO="$WORK_DIR/repo"
FAKE_GH="$WORK_DIR/fake-gh"
FAKE_RUNNER="$WORK_DIR/fake-release-variant-runner"
FAKE_STAGE_COMMAND="$WORK_DIR/fake-stage-command"

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
print '#!/bin/zsh' > "$TEST_REPO/scripts/verify-preview-branch.sh"
print 'exit 0' >> "$TEST_REPO/scripts/verify-preview-branch.sh"
/bin/chmod 755 "$TEST_REPO/scripts/"*.sh

/usr/bin/grep -Fq 'timeout-minutes: 10' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq 'SIGNED_RELEASE_TIMEOUT_SECONDS: 590' \
  "$TEST_REPO/.github/workflows/mac-release-package.yml"
/usr/bin/grep -Fq -- '--cache-path "$BUILD_CACHE_PATH"' "$ROOT/scripts/build-app.sh"
/usr/bin/grep -Fq 'REMOTE_MIC_BUILD_CACHE_PATH' "$ROOT/scripts/notarize-release.sh"

git -C "$TEST_REPO" init -b release/pre-v9.9.9 >/dev/null
git -C "$TEST_REPO" config user.name "Release Pipeline Test"
git -C "$TEST_REPO" config user.email "release-pipeline@example.invalid"
git -C "$TEST_REPO" add .
git -C "$TEST_REPO" commit -m "release candidate" >/dev/null
HEAD_COMMIT="$(git -C "$TEST_REPO" rev-parse HEAD)"

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
