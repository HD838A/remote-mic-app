#!/bin/zsh
set -euo pipefail
umask 077
SCRIPT_ROOT="${0:A:h:h}"

# Subshells preserve each fixture's variables, traps and recoverable cleanup.
test_ready_ci() (
ROOT="$SCRIPT_ROOT"
export RELEASE_CONTROL_PLANE_DIFF_BIN="$ROOT/scripts/verify-release-control-plane-diff.sh"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/sayall-release-ready-gate-test.XXXXXX)"

cleanup() {
  local trash_root="$HOME/.Trash"
  local trash_target="$trash_root/sayall-release-ready-gate-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$trash_root"
  [[ -d "$WORK_DIR" ]] && /bin/mv "$WORK_DIR" "$trash_target"
}
trap cleanup EXIT

source_remote="$WORK_DIR/source-remote.git"
source_repo="$WORK_DIR/source-repo"
fixture_root="$WORK_DIR/gh-fixtures"
/usr/bin/git init -q --bare "$source_remote"
/usr/bin/git init -q "$source_repo"
/usr/bin/git -C "$source_repo" config user.name "Release Gate Fixture"
/usr/bin/git -C "$source_repo" config user.email "release-gate-fixture@example.invalid"
/bin/mkdir -p "$source_repo/Sources" "$source_repo/Screenshots" "$fixture_root"
print -r -- 'product baseline' > "$source_repo/Sources/Product.swift"
/usr/bin/git -C "$source_repo" add Sources/Product.swift
/usr/bin/git -C "$source_repo" commit -q -m 'full product baseline'
/usr/bin/git -C "$source_repo" branch -M main
/usr/bin/git -C "$source_repo" remote add origin "$source_remote"
/usr/bin/git -C "$source_repo" push -q origin main
product_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"

print -r -- 'screenshot-only change' > "$source_repo/Screenshots/fixture.jpg"
/usr/bin/git -C "$source_repo" add Screenshots/fixture.jpg
/usr/bin/git -C "$source_repo" commit -q -m 'docs-only screenshot change'
/usr/bin/git -C "$source_repo" push -q origin main
docs_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"

write_run_json() {
  local run_id="$1"
  local commit="$2"
  local mode="$3"
  jq -n \
    --arg sha "$commit" \
    --arg url "https://github.example.invalid/runs/$run_id" \
    --arg mode "$mode" \
    '{
      workflowName: "macOS CI",
      event: "push",
      status: "completed",
      conclusion: "success",
      headBranch: "main",
      headSha: $sha,
      url: $url,
      updatedAt: "2026-09-27T00:00:00Z",
      jobs: [
        {
          name: "Swift tests and build (Apple Silicon)",
          status: "completed",
          conclusion: "success",
          steps: (
            if $mode == "full" then [
              {name: "Run documentation checks", conclusion: "skipped"},
              {name: "Run release control-plane fixture", conclusion: "skipped"},
              {name: "Run Swift tests", conclusion: "success"},
              {name: "Run project self-test", conclusion: "success"},
              {name: "Build release configuration", conclusion: "success"}
            ] else [
              {name: "Run documentation checks", conclusion: "success"},
              {name: "Run release control-plane fixture", conclusion: "skipped"},
              {name: "Run Swift tests", conclusion: "skipped"},
              {name: "Run project self-test", conclusion: "skipped"},
              {name: "Build release configuration", conclusion: "skipped"}
            ] end
          )
        },
        {
          name: "Swift tests and build (Intel Ventura)",
          status: "completed",
          conclusion: "success",
          steps: (
            if $mode == "full" then [
              {name: "Run documentation checks", conclusion: "skipped"},
              {name: "Run release control-plane fixture", conclusion: "skipped"},
              {name: "Run Swift tests", conclusion: "success"},
              {name: "Run project self-test", conclusion: "success"},
              {name: "Build release configuration", conclusion: "success"}
            ] else [
              {name: "Run documentation checks", conclusion: "success"},
              {name: "Run release control-plane fixture", conclusion: "skipped"},
              {name: "Run Swift tests", conclusion: "skipped"},
              {name: "Run project self-test", conclusion: "skipped"},
              {name: "Build release configuration", conclusion: "skipped"}
            ] end
          )
        }
      ]
    }' > "$fixture_root/run-$run_id.json"
}

write_run_json 100 "$product_commit" full
write_run_json 101 "$docs_commit" docs
print -r -- 100 > "$fixture_root/commit-$product_commit.id"
print -r -- 101 > "$fixture_root/commit-$docs_commit.id"

fake_gh="$WORK_DIR/fake-gh"
print -r -- '#!/bin/zsh
set -euo pipefail
fixture_root="${FIXTURE_ROOT:?}"
if [[ "$1" == run && "$2" == list ]]; then
  commit=""
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == "--commit" ]]; then commit="$argument"; fi
    previous="$argument"
  done
  [[ -r "$fixture_root/commit-$commit.id" ]] || exit 1
  /bin/cat "$fixture_root/commit-$commit.id"
  exit 0
fi
if [[ "$1" == run && "$2" == view ]]; then
  cat "$fixture_root/run-$3.json"
  exit 0
fi
exit 1
' > "$fake_gh"
/bin/chmod 755 "$fake_gh"

docs_output="$WORK_DIR/docs-output.json"
docs_result="$(REPOSITORY_ROOT="$source_repo" GITHUB_REPOSITORY=HD838A/remote-mic-app GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" RELEASE_READY_PROOF_OUTPUT="$docs_output" \
  "$ROOT/scripts/verify-release-ready-main-ci.sh" "$docs_commit" main)"
print -r -- "$docs_result" | /usr/bin/grep -Fq 'PRODUCT_PROOF_COMMIT: '
/usr/bin/jq -e --arg candidate "$docs_commit" --arg commit "$product_commit" \
  '.candidateCommit == $candidate and .productProofCommit == $commit' "$docs_output" >/dev/null

print -r -- 'product change after docs' > "$source_repo/Sources/Product.swift"
/usr/bin/git -C "$source_repo" add Sources/Product.swift
/usr/bin/git -C "$source_repo" commit -q -m 'product change without product CI'
/usr/bin/git -C "$source_repo" push -q origin main
bad_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
write_run_json 102 "$bad_commit" docs
print -r -- 102 > "$fixture_root/commit-$bad_commit.id"

if REPOSITORY_ROOT="$source_repo" GITHUB_REPOSITORY=HD838A/remote-mic-app GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
    "$ROOT/scripts/verify-release-ready-main-ci.sh" "$bad_commit" main > "$WORK_DIR/bad-output.log" 2>&1; then
  print -u2 -- 'release gate accepted a product change without a full product CI run'
  exit 1
fi
/usr/bin/grep -Fq 'source changes after the inherited product proof are not docs-only' "$WORK_DIR/bad-output.log"
print -r -- 'docs-only release gate fixture passed'

# Product steps live on public jobs; summary jobs must not substitute for them.
write_run_json 103 "$bad_commit" full
jq '.jobs |= map(.name = ("Public " + .name))' "$fixture_root/run-103.json" > "$WORK_DIR/modern-run.json"
/bin/mv "$WORK_DIR/modern-run.json" "$fixture_root/run-103.json"
print -r -- 103 > "$fixture_root/commit-$bad_commit.id"
REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
  "$ROOT/scripts/verify-release-ready-main-ci.sh" "$bad_commit" main > "$WORK_DIR/modern-pass.log"
jq '.jobs[1].steps |= map(select(.name != "Build release configuration"))' \
  "$fixture_root/run-103.json" > "$WORK_DIR/incomplete-run.json"
/bin/mv "$WORK_DIR/incomplete-run.json" "$fixture_root/run-103.json"
if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
    "$ROOT/scripts/verify-release-ready-main-ci.sh" "$bad_commit" main > "$WORK_DIR/incomplete.log" 2>&1; then
  print -u2 "release gate accepted an incomplete public product lane"
  exit 1
fi
print "MODERN PRODUCT PROOF FIXTURE PASS"

# A control-plane run reuses the latest complete public product proof.
write_run_json 103 "$bad_commit" full
jq '.jobs |= map(.name = ("Public " + .name))' "$fixture_root/run-103.json" > "$WORK_DIR/modern-run.json"
/bin/mv "$WORK_DIR/modern-run.json" "$fixture_root/run-103.json"
/bin/mkdir -p "$source_repo/scripts"
print -r -- fixture > "$source_repo/scripts/stage-macos-preview.sh"
/usr/bin/git -C "$source_repo" add scripts/stage-macos-preview.sh
/usr/bin/git -C "$source_repo" commit -q -m 'control-plane change'
/usr/bin/git -C "$source_repo" push -q origin main
control_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
write_run_json 104 "$control_commit" full
jq '.jobs |= map(
  .name |= sub("^Swift tests and build"; "Release script checks") |
  .steps = [{name:"Run release control-plane fixture",conclusion:"success"}]
)' "$fixture_root/run-104.json" > "$WORK_DIR/control-run.json"
/bin/mv "$WORK_DIR/control-run.json" "$fixture_root/run-104.json"
print -r -- 104 > "$fixture_root/commit-$control_commit.id"
REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
  RELEASE_READY_PROOF_OUTPUT="$WORK_DIR/control-proof.json" \
  "$ROOT/scripts/verify-release-ready-main-ci.sh" "$control_commit" main > "$WORK_DIR/control-pass.log"
jq -e --arg commit "$bad_commit" '.productProofCommit == $commit' "$WORK_DIR/control-proof.json" >/dev/null

# Subsequent manual tooling cannot be mistaken for a fresh product proof.
/bin/mkdir -p "$source_repo/script"
print -r -- fixture > "$source_repo/script/build_and_run.sh"
/usr/bin/git -C "$source_repo" add .
/usr/bin/git -C "$source_repo" commit -q -m 'manual tooling change'
/usr/bin/git -C "$source_repo" push -q origin main
tooling_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
write_run_json 105 "$tooling_commit" docs
jq '.jobs |= map(.name = ("Public " + .name) |
  .steps |= map(if .name == "Run documentation checks" then .name = "Run tooling checks" else . end)
)' "$fixture_root/run-105.json" > "$WORK_DIR/tooling-run.json"
/bin/mv "$WORK_DIR/tooling-run.json" "$fixture_root/run-105.json"
print -r -- 105 > "$fixture_root/commit-$tooling_commit.id"
REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
  RELEASE_READY_PROOF_OUTPUT="$WORK_DIR/tooling-proof.json" \
  "$ROOT/scripts/verify-release-ready-main-ci.sh" "$tooling_commit" main > "$WORK_DIR/tooling-pass.log"
jq -e --arg commit "$bad_commit" '.productProofCommit == $commit' "$WORK_DIR/tooling-proof.json" >/dev/null
print "CONTROL AND TOOLING PROOF FIXTURE PASS"

# A repository-only run must inherit a real product proof, not become one.
# Remove the fixture-only control/tooling paths recoverably to isolate the diff.
/bin/mv "$source_repo/scripts/stage-macos-preview.sh" "$WORK_DIR/stage-macos-preview.saved"
/bin/mv "$source_repo/script/build_and_run.sh" "$WORK_DIR/build-and-run.saved"
print -r -- fixture > "$source_repo/scripts/verify-repository-governance.sh"
print -r -- fixture > "$source_repo/AGENTS.md"
/usr/bin/git -C "$source_repo" add -A
/usr/bin/git -C "$source_repo" commit -q -m 'repository-only change'
/usr/bin/git -C "$source_repo" push -q origin main
repository_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
write_run_json 106 "$repository_commit" docs
jq '.jobs |= map(.name = ("Public " + .name) |
  .steps |= map(if .name == "Run documentation checks" then .name = "Run repository checks" else . end)
)' "$fixture_root/run-106.json" > "$WORK_DIR/repository-run.json"
/bin/mv "$WORK_DIR/repository-run.json" "$fixture_root/run-106.json"
print -r -- 106 > "$fixture_root/commit-$repository_commit.id"
REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
  RELEASE_READY_PROOF_OUTPUT="$WORK_DIR/repository-proof.json" \
  "$ROOT/scripts/verify-release-ready-main-ci.sh" "$repository_commit" main > "$WORK_DIR/repository-pass.log"
jq -e --arg commit "$bad_commit" \
  '.productProofCommit == $commit and .sourceCiRunId == 106 and .productCiRunId == 103' \
  "$WORK_DIR/repository-proof.json" >/dev/null

# Reject a failed check, wrong source identity or PR proof even if the run is green.
for mutation in \
  '.jobs[1].steps[0].conclusion = "failure"' \
  '.headSha = "0000000000000000000000000000000000000000"' \
  '.event = "pull_request"'; do
  /bin/cp "$fixture_root/run-106.json" "$WORK_DIR/repository-original.json"
  jq "$mutation" "$WORK_DIR/repository-original.json" > "$fixture_root/run-106.json"
  if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
      "$ROOT/scripts/verify-release-ready-main-ci.sh" "$repository_commit" main > "$WORK_DIR/rejected.log" 2>&1; then
    print -u2 "release gate accepted invalid repository CI evidence"
    exit 1
  fi
  /bin/mv "$WORK_DIR/repository-original.json" "$fixture_root/run-106.json"
done

print -r -- 'unverified product change' > "$source_repo/Sources/Product.swift"
/usr/bin/git -C "$source_repo" add .
/usr/bin/git -C "$source_repo" commit -q -m 'mixed repository and product change'
/usr/bin/git -C "$source_repo" push -q origin main
mixed_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
jq --arg sha "$mixed_commit" '.headSha = $sha' "$fixture_root/run-106.json" > "$fixture_root/run-107.json"
print -r -- 107 > "$fixture_root/commit-$mixed_commit.id"
if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
    "$ROOT/scripts/verify-release-ready-main-ci.sh" "$mixed_commit" main > "$WORK_DIR/mixed-rejected.log" 2>&1; then
  print -u2 "repository checks concealed an unverified product change"
  exit 1
fi
/usr/bin/grep -Fq 'source changes after the inherited product proof are not docs-only' "$WORK_DIR/mixed-rejected.log"
print "REPOSITORY PROOF INHERITANCE AND REJECTION FIXTURE PASS"

# Consolidated jobs must prove both builds and both available private configurations.
write_run_json 108 "$mixed_commit" full
jq '
  def passed($name): {name:$name, conclusion:"success"};
  def job($name; $steps): {name:$name, status:"completed", conclusion:"success", steps:$steps};
  [passed("Build release configuration (Apple Silicon)"),
   passed("Build release configuration (Intel Ventura)")] as $builds |
  .jobs = [
    job("Classify changed files"; [passed("Detect private dependency access")]),
    job("Public Swift tests and dual-architecture build";
      [passed("Run Swift tests"), passed("Run project self-test"),
       passed("Run core first-voice journey gate")] + $builds),
    job("Private free-combination-actions tests and dual-architecture build";
      [passed("Run private integration tests")] + $builds),
    job("Private paid-button-profiles tests and dual-architecture build";
      [passed("Run private integration tests")] + $builds),
    job("Swift tests and build (Apple Silicon)"; [passed("Require every applicable macOS CI lane")]),
    job("Swift tests and build (Intel Ventura)"; [passed("Require every applicable macOS CI lane")])
  ]' "$fixture_root/run-108.json" > "$WORK_DIR/consolidated.json"
/bin/cp "$WORK_DIR/consolidated.json" "$fixture_root/run-108.json"
print -r -- 108 > "$fixture_root/commit-$mixed_commit.id"
REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
  "$ROOT/scripts/verify-release-ready-main-ci.sh" "$mixed_commit" main > "$WORK_DIR/consolidated-pass.log"
for mutation in \
  '.jobs[1].steps |= map(select(.name != "Build release configuration (Intel Ventura)"))' \
  '.jobs[1].steps |= map(select(.name != "Build release configuration (Apple Silicon)"))' \
  '.jobs[2].steps |= map(select(.name != "Run private integration tests"))' \
  '.jobs[3].steps |= map(select(.name != "Build release configuration (Intel Ventura)"))' \
  '.jobs[3].conclusion = "failure"' \
  '.jobs[3].conclusion = "cancelled"' \
  '.jobs |= map(select(.name != "Private paid-button-profiles tests and dual-architecture build"))' \
  '.jobs[3].conclusion = "skipped"' \
  '.jobs[0].steps = []' \
  '.jobs[5].conclusion = "failure"' \
  '.event = "pull_request"' \
  '.headSha = "0000000000000000000000000000000000000000"'; do
  jq "$mutation" "$WORK_DIR/consolidated.json" > "$fixture_root/run-108.json"
  if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
      "$ROOT/scripts/verify-release-ready-main-ci.sh" "$mixed_commit" main > "$WORK_DIR/consolidated-rejected.log" 2>&1; then
    print -u2 "release gate accepted incomplete consolidated product evidence: $mutation"
    exit 1
  fi
done
# With no private access GitHub may expose one skipped, unexpanded matrix job.
jq '.jobs |= map(if (.name | startswith("Private ")) then
  .conclusion = "skipped" | .steps = [] else . end)' \
  "$WORK_DIR/consolidated.json" > "$fixture_root/run-108.json"
REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
  "$ROOT/scripts/verify-release-ready-main-ci.sh" "$mixed_commit" main > "$WORK_DIR/no-private-pass.log"
jq '.jobs |= map(select(.name != "Private paid-button-profiles tests and dual-architecture build"))' \
  "$fixture_root/run-108.json" > "$WORK_DIR/single-skipped.json"
/bin/mv "$WORK_DIR/single-skipped.json" "$fixture_root/run-108.json"
REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
  "$ROOT/scripts/verify-release-ready-main-ci.sh" "$mixed_commit" main > "$WORK_DIR/single-skipped-pass.log"
/bin/cp "$WORK_DIR/consolidated.json" "$fixture_root/run-108.json"

# Modern lightweight and control-only jobs inherit, never substitute for product proof.
for lightweight in docs tooling repository control; do
  print -r -- "$lightweight" > "$source_repo/README.md"
  if [[ "$lightweight" == control ]]; then
    print -r -- fixture > "$source_repo/scripts/stage-macos-preview.sh"
  fi
  /usr/bin/git -C "$source_repo" add .
  /usr/bin/git -C "$source_repo" commit -q -m "consolidated $lightweight fixture"
  /usr/bin/git -C "$source_repo" push -q origin main
  lightweight_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
  case "$lightweight" in
    docs) check_step='Run documentation checks' ;;
    tooling) check_step='Run tooling checks' ;;
    repository) check_step='Run repository checks' ;;
    control) check_step='Run release control-plane fixture' ;;
  esac
  jq --arg sha "$lightweight_commit" --arg step "$check_step" '
    .headSha = $sha | .jobs = [.jobs[1] |
      .steps = [{name:$step,conclusion:"success"}]]' \
    "$WORK_DIR/consolidated.json" > "$fixture_root/run-109.json"
  print -r -- 109 > "$fixture_root/commit-$lightweight_commit.id"
  REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" FIXTURE_ROOT="$fixture_root" \
    RELEASE_READY_PROOF_OUTPUT="$WORK_DIR/lightweight-proof.json" \
    "$ROOT/scripts/verify-release-ready-main-ci.sh" "$lightweight_commit" main > "$WORK_DIR/lightweight-pass.log"
  jq -e --arg commit "$mixed_commit" '.productProofCommit == $commit and .productCiRunId == 108' \
    "$WORK_DIR/lightweight-proof.json" >/dev/null
done
print "CONSOLIDATED CI PROOF AND REJECTION FIXTURE PASS"

)

test_metadata() (
ROOT="$SCRIPT_ROOT"
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

)

test_flow() (
ROOT="$SCRIPT_ROOT"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/sayall-macos-release-flow-test.XXXXXX)"

cleanup() {
  local trash_root="$HOME/.Trash"
  local trash_target="$trash_root/sayall-macos-release-flow-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$trash_root"
  [[ -d "$WORK_DIR" ]] && /bin/mv "$WORK_DIR" "$trash_target"
}
trap cleanup EXIT

for script in \
  prepare-preview-release.sh stage-macos-preview.sh prepare-public-release-assets.sh \
  verify-public-release-source.sh \
  verify-preview-cdn-availability.sh \
  verify-staged-release-assets.sh recover-preview-stage.sh publish-staged-preview.sh \
  publish-preview-release.sh promote-preview-release.sh prepare-staged-preview-ui-test.sh \
  record-preview-ui-attestation.sh; do
  [[ -x "$ROOT/scripts/$script" ]] || {
    print -u2 "release helper is not executable: $script"
    exit 1
  }
done

for script in \
  prepare-preview-release.sh stage-macos-preview.sh prepare-public-release-assets.sh \
  verify-public-release-source.sh \
  verify-preview-cdn-availability.sh \
  recover-preview-stage.sh publish-staged-preview.sh publish-preview-release.sh \
  promote-preview-release.sh prepare-staged-preview-ui-test.sh \
  record-preview-ui-attestation.sh; do
  case "$script" in
    prepare-public-release-assets.sh|stage-macos-preview.sh|prepare-preview-release.sh)
      zsh -n "$ROOT/scripts/$script" ;;
    *)
      bash -n "$ROOT/scripts/$script" ;;
  esac
done

test_ready_ci

package_workflow="$ROOT/.github/workflows/mac-release-package.yml"
publication_workflow="$ROOT/.github/workflows/mac-preview-publication.yml"
stable_workflow="$ROOT/.github/workflows/mac-stable-promote.yml"
ci_workflow="$ROOT/.github/workflows/mac-ci.yml"
notarize_release="$ROOT/scripts/notarize-release.sh"
opus_build="$ROOT/scripts/build-apple-remote-opus.sh"

/usr/bin/grep -Fq -- '--disable-keychain' "$ROOT/scripts/build-app.sh"
/usr/bin/grep -Fq 'xcrun swift build --disable-keychain' "$ROOT/scripts/test.sh"
if [[ "$(/usr/bin/grep -c -- '--disable-keychain' "$ROOT/scripts/build-app.sh")" -lt 2 ]]; then
  print -u2 "local SwiftPM entry points must disable macOS Keychain credential lookup"
  exit 1
fi

/usr/bin/grep -Fq 'mode:' "$package_workflow"
/usr/bin/grep -Fq 'expected_commit:' "$package_workflow"
/usr/bin/grep -Fq 'source_branch:' "$package_workflow"
/usr/bin/grep -Fq 'if: ${{ inputs.include_ai }}' "$package_workflow"
/usr/bin/grep -Fq 'INCLUDE_SAYALL_AI: ${{ inputs.include_ai && '\''1'\'' || '\''0'\'' }}' "$package_workflow"
/usr/bin/grep -Fq 'INCLUDE_SAYALL_AI="${INCLUDE_SAYALL_AI:-0}"' "$ROOT/scripts/stage-macos-preview.sh"
/usr/bin/grep -Fq -- 'include_ai=$include_ai' "$ROOT/scripts/stage-macos-preview.sh"
# Execute the actual workflow configuration body without checkout or credentials.
ai_input="$(/usr/bin/awk '/^      include_ai:/ { capture=1; next } capture && /^concurrency:/ { exit } capture { print }' "$package_workflow")"
print -r -- "$ai_input" | /usr/bin/grep -Fq 'default: false'
print -r -- "$ai_input" | /usr/bin/grep -Fq 'type: boolean'
configure_features="$(/usr/bin/awk '
  /- name: Configure private feature package/ { found=1; next }
  found && /run: \|/ { capture=1; next }
  capture && /^      - name:/ { exit }
  capture { print }
' "$package_workflow")"
for ai_mode in 0 1; do
  ai_env="$WORK_DIR/ai-config-$ai_mode.env"
  INCLUDE_SAYALL_AI="$ai_mode" GITHUB_WORKSPACE="$WORK_DIR" GITHUB_ENV="$ai_env" \
    /bin/bash -e -c "$configure_features"
  /usr/bin/grep -Fxq "SAYALL_MAC_REMOTE_PACKAGE_PATH=$WORK_DIR/.private-dependencies/sayall-private-platform/packages/macos-remote" "$ai_env"
  /usr/bin/grep -Fxq "REQUIRE_SAYALL_AI_PACKAGE=$ai_mode" "$ai_env"
  if [[ "$ai_mode" == 0 ]]; then
    /usr/bin/grep -Fxq 'SAYALL_AI_PACKAGE_PATH=' "$ai_env"
  else
    /usr/bin/grep -Fxq "SAYALL_AI_PACKAGE_PATH=$WORK_DIR/.private-dependencies/sayall-ai" "$ai_env"
  fi
done
ai_requirement="$(/usr/bin/grep '^export REQUIRE_SAYALL_AI_PACKAGE=' "$notarize_release")"
[[ "$(env -u REQUIRE_SAYALL_AI_PACKAGE /bin/zsh -c "$ai_requirement; print -- \$REQUIRE_SAYALL_AI_PACKAGE")" == 0 ]]
[[ "$(REQUIRE_SAYALL_AI_PACKAGE=1 /bin/zsh -c "$ai_requirement; print -- \$REQUIRE_SAYALL_AI_PACKAGE")" == 1 ]]
/usr/bin/grep -Fq 'environment: mac-release' "$package_workflow"
/usr/bin/grep -Fq 'prepare-public-release-assets.sh' "$package_workflow"
/usr/bin/grep -Fq 'mac-preview-payload-v' "$package_workflow"
/usr/bin/grep -Fq 'mac-preview-stage-v' "$package_workflow"
/usr/bin/grep -Fq 'Exclude ephemeral release inputs from source status' "$package_workflow"
/usr/bin/grep -Fq '/.private-dependencies/' "$package_workflow"
/usr/bin/grep -Fq '/.private-release/' "$package_workflow"
/usr/bin/grep -Fq 'test "$TRIGGER_REF_NAME" = main' "$package_workflow"
/usr/bin/grep -Fq 'verify-public-release-source.sh' "$package_workflow"
/usr/bin/grep -Fq 'RELEASE_SWIFT_BUILD_TIMEOUT_SECONDS="${RELEASE_SWIFT_BUILD_TIMEOUT_SECONDS:-420}"' "$notarize_release"
/usr/bin/grep -Fq 'RELEASE_APP_BUILD_TIMEOUT_SECONDS="${RELEASE_APP_BUILD_TIMEOUT_SECONDS:-450}"' "$notarize_release"
/usr/bin/grep -Fq 'export RELEASE_SWIFT_BUILD_TIMEOUT_SECONDS' "$notarize_release"
if [[ "$(/usr/bin/grep -c -- 'REPOSITORY_ROOT: \${{ github.workspace }}' "$package_workflow")" -lt 1 ]]; then
  print -u2 "protected package verification must point the verifier at the checked-out repository"
  exit 1
fi
/usr/bin/grep -Fq "branches: [main, 'hotfix/**']" "$ci_workflow"
/usr/bin/grep -Fq 'swift test --disable-keychain --filter BuildSigningTests' "$ci_workflow"
/usr/bin/grep -Fq 'Detect private dependency access' "$ci_workflow"
/usr/bin/grep -Fq 'Private dependency access is unavailable' "$ci_workflow"
/usr/bin/grep -Fq 'SAYALL_PRIVATE_PLATFORM_DEPLOY_KEY' "$ci_workflow"
/usr/bin/grep -Fq 'SAYALL_PRIVATE_PLATFORM_DEPLOY_KEY' "$package_workflow"
/usr/bin/grep -Fq 'test -f .private-dependencies/sayall-private-platform/packages/audio-input-kit/siri-remote/Package.swift' "$package_workflow"
/usr/bin/grep -Fq 'SAYALL_SIRI_REMOTE_PACKAGE_PATH=$GITHUB_WORKSPACE/.private-dependencies/sayall-private-platform/packages/audio-input-kit/siri-remote' "$package_workflow"
/usr/bin/grep -Fq 'RELEASE_VARIANT=apple-silicon ./scripts/build-apple-remote-opus.sh' "$package_workflow"
/usr/bin/grep -Fq 'RELEASE_VARIANT=intel ./scripts/build-apple-remote-opus.sh' "$package_workflow"
/usr/bin/grep -Fq 'CONFIGURE_HOST_ARGS=(--host "$CROSS_HOST")' "$opus_build"
/usr/bin/grep -Fq 'CC="$CLANG_PATH -target $RELEASE_TRIPLE -isysroot $SDK_PATH"' "$opus_build"
if /usr/bin/grep -Fq 'must be built on a $RELEASE_ARCH host' "$opus_build"; then
  print -u2 "Apple Remote Opus must support cross-compiling the Intel release on an Apple Silicon runner"
  exit 1
fi
/usr/bin/grep -Fq 'remoteMicTestSwiftSettings.append(.define("SAYALL_MAC_REMOTE_ENABLED"))' "$ROOT/Package.swift"
if /usr/bin/grep -Eq 'SAYALL_MACRO_PLATFORM_DEPLOY_KEY' "$ci_workflow" "$package_workflow"; then
  print -u2 "private platform checkout must not use the retired deploy secret name"
  exit 1
fi
/usr/bin/grep -Fq "GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new'" "$ci_workflow"
/usr/bin/grep -Fq 'Run private integration tests' "$ci_workflow"
/usr/bin/grep -Fq 'Build release configuration (Apple Silicon)' "$ci_workflow"
/usr/bin/grep -Fq 'Build release configuration (Intel Ventura)' "$ci_workflow"
/usr/bin/grep -Fq 'name: Public Swift tests and dual-architecture build' "$ci_workflow"
/usr/bin/grep -Fq 'name: Private ${{ matrix.configuration }} tests and dual-architecture build' "$ci_workflow"
/usr/bin/grep -Fq "if: needs.classify_changes.outputs.product_change == 'true' && needs.classify_changes.outputs.private_available == 'true'" "$ci_workflow"
/usr/bin/grep -Fq 'needs: [classify_changes, public_test, private_test]' "$ci_workflow"
/usr/bin/grep -Fq 'PRIVATE_TEST_RESULT: ${{ needs.private_test.result }}' "$ci_workflow"
public_job="$(/usr/bin/awk '/^  public_test:/ { capture=1 } /^  private_test:/ { exit } capture { print }' "$ci_workflow")"
for package_path in SAYALL_AI_PACKAGE_PATH SAYALL_COMBINATION_ACTIONS_PATH SAYALL_BUTTON_PROFILES_PACKAGE_PATH SAYALL_MAC_REMOTE_PACKAGE_PATH; do
  print -r -- "$public_job" | /usr/bin/grep -Fq "$package_path: \"\""
done
if ! /usr/bin/grep -Fq 'configuration: [free-combination-actions, paid-button-profiles]' "$ci_workflow" || \
   ! /usr/bin/grep -Fq "matrix.configuration == 'paid-button-profiles'" "$ci_workflow"; then
  print -u2 "public CI must clear private package paths and private checks must remain conditional"
  exit 1
fi
if [[ "$(/usr/bin/grep -c -- 'swift test --disable-keychain' "$ci_workflow")" -lt 4 ]] || \
   [[ "$(/usr/bin/grep -c -- 'swift build --disable-keychain' "$ci_workflow")" -lt 1 ]]; then
  print -u2 "public and private CI SwiftPM entry points must disable macOS Keychain lookup"
  exit 1
fi
release_gate_log="$WORK_DIR/release-private-package-gate.log"
if env \
   -u SAYALL_AI_PACKAGE_PATH \
   -u SAYALL_SIRI_REMOTE_PACKAGE_PATH \
   -u SAYALL_ENABLE_SIRI_REMOTE \
   -u SAYALL_SIRI_REMOTE_UI_ONLY \
   -u SAYALL_COMBINATION_ACTIONS_PATH \
   -u SAYALL_BUTTON_PROFILES_PACKAGE_PATH \
   -u SAYALL_TEST_BUTTON_PROFILES_FREE \
   -u SAYALL_MEMBERSHIP_ADAPTER_PACKAGE_PATH \
   -u SAYALL_MEMBERSHIP_PACKAGE_PATH \
   -u SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH \
   REQUIRE_SAYALL_MAC_REMOTE_PACKAGE=1 SAYALL_MAC_REMOTE_PACKAGE_PATH= \
   "$ROOT/scripts/build-app.sh" >"$release_gate_log" 2>&1; then
  print -u2 "release build must fail when the required Mac remote package is missing"
  exit 1
fi
/usr/bin/grep -Fq 'A SayAll Mac remote package is required for this build' "$release_gate_log"
if /usr/bin/grep -Eq 'release_mode|expected_pipeline_digest|qualification|candidateBranch|requestId|gh release|git tag|contents:[[:space:]]*write' "$package_workflow"; then
  print -u2 "protected staging workflow still contains publication or legacy qualification state"
  exit 1
fi

/usr/bin/grep -Fq 'source_run_id:' "$publication_workflow"
/usr/bin/grep -Fq 'ui_attestation_b64:' "$publication_workflow"
/usr/bin/grep -Fq 'publish-preview-release.sh' "$publication_workflow"
/usr/bin/grep -Fq 'ref: ${{ github.sha }}' "$publication_workflow"
/usr/bin/grep -Fq 'TRIGGER_REPOSITORY' "$publication_workflow"
/usr/bin/grep -Fq "github.ref_name == 'main'" "$publication_workflow"
if /usr/bin/grep -Eq 'environment:[[:space:]]*mac-release|secrets[.]|RELEASE_AGE_IDENTITY|MATCH|NOTARY|draft:' "$publication_workflow"; then
  print -u2 "Preview publication workflow contains protected Apple inputs"
  exit 1
fi

/usr/bin/grep -Fq 'tag:' "$stable_workflow"
/usr/bin/grep -Fq 'promote-preview-release.sh' "$stable_workflow"
/usr/bin/grep -Fq 'group: mac-stable-promotion' "$stable_workflow"
/usr/bin/grep -Fq 'ref: ${{ github.sha }}' "$stable_workflow"
/usr/bin/grep -Fq 'TRIGGER_REPOSITORY' "$stable_workflow"
/usr/bin/grep -Fq "github.ref_name == 'main'" "$stable_workflow"
if /usr/bin/grep -Eq 'package-macos|codesign|notary|xcrun stapler|upload-artifact|workflow_run' "$stable_workflow"; then
  print -u2 "Stable promotion workflow still rebuilds or uploads assets"
  exit 1
fi

REPOSITORY_ROOT="$ROOT" "$ROOT/scripts/verify-release-dependency-pins.sh" tokens >/dev/null

publication_source="$ROOT/scripts/publish-preview-release.sh"
recovery_source="$ROOT/scripts/recover-preview-stage.sh"
attestation_source="$ROOT/scripts/record-preview-ui-attestation.sh"
ui_prep_source="$ROOT/scripts/prepare-staged-preview-ui-test.sh"
/usr/bin/grep -Fq -- '--ref main' "$ROOT/scripts/stage-macos-preview.sh"
/usr/bin/grep -Fq -- 'source_branch=$source_branch' "$ROOT/scripts/stage-macos-preview.sh"
/usr/bin/grep -Fq -- '--ref main' "$ROOT/scripts/publish-staged-preview.sh"
/usr/bin/grep -Fq 'origin/main' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq 'provenance_schema' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq 'Unsupported candidate provenance schema' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq 'legacy-release-main' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq 'expected_asset_count' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq '.schemaVersion == 4' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq '.head_branch == "main"' "$recovery_source"
/usr/bin/grep -Fq '.head_branch == "main"' "$ui_prep_source"
/usr/bin/grep -Fq 'hotfix/vX.Y.Z' "$ROOT/scripts/verify-public-release-source.sh"
/usr/bin/grep -Fq 'SOURCE_BASE_COMMIT' "$ROOT/scripts/verify-public-release-source.sh"
/usr/bin/grep -Fq 'record-preview-ui-attestation.sh" verify' "$publication_source"
/usr/bin/grep -Fq 'Preview publication must run from exact origin/main' "$publication_source"
/usr/bin/grep -Fq 'stage-record/preview-stage-record.json' "$publication_source"
/usr/bin/grep -Fq 'staging record artifact' "$recovery_source"
/usr/bin/grep -Fq '.stagedAt | fromdateiso8601' "$recovery_source"
/usr/bin/grep -Fq '.stagedAt == $stage[0].stagedAt' "$attestation_source"
/usr/bin/grep -Fq 'verify-preview-cdn-availability.sh' "$ROOT/scripts/prepare-preview-release.sh"
/usr/bin/grep -Fq 'verify-preview-cdn-availability.sh' "$ROOT/scripts/stage-macos-preview.sh"
/usr/bin/grep -Fq 'verify-preview-cdn-availability.sh' "$publication_source"
/usr/bin/grep -Fq 'refusing to overwrite Release Notes' "$publication_source"
/usr/bin/grep -Fq 'actions/runs/$source_run_id/attempts/$source_run_attempt' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq 'actions/artifacts/$signed_artifact_id' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq -- '--arg commit "$source_commit"' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq '.id == $run' "$recovery_source"
/usr/bin/grep -Fq '.id == $artifact' "$recovery_source"
/usr/bin/grep -Fq 'zipinfo -l' "$recovery_source"
/usr/bin/grep -Fq 'zipinfo -l' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq 'browser_download_url' "$ui_prep_source"
if /usr/bin/grep -Fq 'application/octet-stream' "$ui_prep_source"; then
  print -u2 "Preview UI preparation still relies on an unsupported gh API media type"
  exit 1
fi
if /usr/bin/grep -Eq '\$\(\)/bin/date|date -u' "$publication_source"; then
  print -u2 "publication provenance must not use the current clock"
  exit 1
fi

# Exercise the shared main/Hotfix source gate against a local remote.
source_remote="$WORK_DIR/source-remote.git"
source_repo="$WORK_DIR/source-repo"
old_main_repo="$WORK_DIR/old-main-repo"
other_repo="$WORK_DIR/unrelated-source-repo"
/usr/bin/git init -q --bare "$source_remote"
/usr/bin/git init -q "$source_repo"
/usr/bin/git -C "$source_repo" config user.name "Release Source Fixture"
/usr/bin/git -C "$source_repo" config user.email "release-source-fixture@example.invalid"
/bin/mkdir -p "$source_repo/Resources"
/bin/cp "$ROOT/Resources/Info.plist" "$source_repo/Resources/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string 1.9.21 "$source_repo/Resources/Info.plist"
/usr/bin/git -C "$source_repo" add Resources/Info.plist
/usr/bin/git -C "$source_repo" commit -q -m "stable fixture"
/usr/bin/git -C "$source_repo" branch -M main
stable_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
/usr/bin/git -C "$source_repo" tag v1.9.21
/usr/bin/git -C "$source_repo" remote add origin "$source_remote"
/usr/bin/git -C "$source_repo" push -q origin main v1.9.21

fake_gh="$WORK_DIR/fake-gh"
print -r -- '#!/bin/zsh
set -euo pipefail
if [[ "$1" == api && "$2" == "repos/HD838A/remote-mic-app/releases/latest" ]]; then
  print -r -- '\''{"tag_name":"v1.9.21","draft":false,"prerelease":false}'\''
  exit 0
fi
exit 1' > "$fake_gh"
/bin/chmod 755 "$fake_gh"

source_guard="$ROOT/scripts/verify-public-release-source.sh"
REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
  "$source_guard" main "$stable_commit" 1.9.21 >/dev/null

print -r -- main-advanced > "$source_repo/main-change.txt"
/usr/bin/git -C "$source_repo" add main-change.txt
/usr/bin/git -C "$source_repo" commit -q -m "advance main fixture"
main_head="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
/usr/bin/git -C "$source_repo" push -q origin main
REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
  "$source_guard" main "$main_head" 1.9.21 >/dev/null

/usr/bin/git clone -q "$source_remote" "$old_main_repo"
/usr/bin/git -C "$old_main_repo" switch -q --detach "$stable_commit"
/usr/bin/git -C "$old_main_repo" branch -f main "$stable_commit"
/usr/bin/git -C "$old_main_repo" switch -q main
if REPOSITORY_ROOT="$old_main_repo" GH_BIN="$fake_gh" \
    "$source_guard" main "$stable_commit" 1.9.21 >/dev/null 2>&1; then
  print -u2 "release source gate accepted an old main SHA"
  exit 1
fi
RELEASE_SOURCE_CHECKOUT_MODE=none RELEASE_SOURCE_REMOTE_MODE=published \
  REPOSITORY_ROOT="$old_main_repo" GH_BIN="$fake_gh" \
  "$source_guard" main "$stable_commit" 1.9.21 >/dev/null

/usr/bin/git -C "$source_repo" switch -q -c release-main "$main_head"
if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
    "$source_guard" release-main "$main_head" 1.9.21 >/dev/null 2>&1; then
  print -u2 "release source gate accepted frozen release-main"
  exit 1
fi
/usr/bin/git -C "$source_repo" switch -q -c feature/release-fixture "$main_head"
if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
    "$source_guard" feature/release-fixture "$main_head" 1.9.21 >/dev/null 2>&1; then
  print -u2 "release source gate accepted a feature branch"
  exit 1
fi

/usr/bin/git -C "$source_repo" switch -q -c hotfix/v1.9.22 "$stable_commit"
/usr/bin/plutil -replace CFBundleShortVersionString -string 1.9.22 "$source_repo/Resources/Info.plist"
/usr/bin/git -C "$source_repo" add Resources/Info.plist
/usr/bin/git -C "$source_repo" commit -q -m "valid hotfix fixture"
hotfix_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
/usr/bin/git -C "$source_repo" push -q origin hotfix/v1.9.22
REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
  "$source_guard" hotfix/v1.9.22 "$hotfix_commit" 1.9.22 >/dev/null

/usr/bin/git -C "$source_repo" switch -q --detach "$hotfix_commit"
RELEASE_SOURCE_CHECKOUT_MODE=detached REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
  "$source_guard" hotfix/v1.9.22 "$hotfix_commit" 1.9.22 >/dev/null
if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
    "$source_guard" hotfix/v1.9.22 "$hotfix_commit" 1.9.22 >/dev/null 2>&1; then
  print -u2 "release source gate accepted a detached local checkout"
  exit 1
fi
/usr/bin/git -C "$source_repo" switch -q hotfix/v1.9.22
if RELEASE_SOURCE_EXPECTED_BASE_TAG=v1.9.20 \
    REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
    "$source_guard" hotfix/v1.9.22 "$hotfix_commit" 1.9.22 >/dev/null 2>&1; then
  print -u2 "release source gate accepted a changed Hotfix stable baseline"
  exit 1
fi

/usr/bin/git -C "$source_repo" switch -q -c hotfix/1.9.23 "$stable_commit"
if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
    "$source_guard" hotfix/1.9.23 "$stable_commit" 1.9.23 >/dev/null 2>&1; then
  print -u2 "release source gate accepted a noncanonical Hotfix branch name"
  exit 1
fi
/usr/bin/git -C "$source_repo" switch -q -c hotfix/v1.9.23 "$hotfix_commit"
if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
    "$source_guard" hotfix/v1.9.23 "$hotfix_commit" 1.9.22 >/dev/null 2>&1; then
  print -u2 "release source gate accepted a Hotfix version mismatch"
  exit 1
fi

/usr/bin/git init -q "$other_repo"
/usr/bin/git -C "$other_repo" config user.name "Unrelated Release Fixture"
/usr/bin/git -C "$other_repo" config user.email "unrelated-release-fixture@example.invalid"
/bin/mkdir -p "$other_repo/Resources"
/bin/cp "$ROOT/Resources/Info.plist" "$other_repo/Resources/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string 1.9.24 "$other_repo/Resources/Info.plist"
/usr/bin/git -C "$other_repo" add Resources/Info.plist
/usr/bin/git -C "$other_repo" commit -q -m "unrelated hotfix fixture"
/usr/bin/git -C "$other_repo" remote add origin "$source_remote"
/usr/bin/git -C "$other_repo" push -q origin HEAD:hotfix/v1.9.24
/usr/bin/git -C "$source_repo" fetch -q origin hotfix/v1.9.24
/usr/bin/git -C "$source_repo" switch -q -C hotfix/v1.9.24 --track origin/hotfix/v1.9.24
unrelated_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
    "$source_guard" hotfix/v1.9.24 "$unrelated_commit" 1.9.24 >/dev/null 2>&1; then
  print -u2 "release source gate accepted a Hotfix from the wrong baseline"
  exit 1
fi

/usr/bin/git -C "$source_repo" switch -q -c hotfix/v1.9.25 "$stable_commit"
/usr/bin/plutil -replace CFBundleShortVersionString -string 1.9.25 "$source_repo/Resources/Info.plist"
/usr/bin/git -C "$source_repo" add Resources/Info.plist
/usr/bin/git -C "$source_repo" commit -q -m "merge hotfix fixture"
/usr/bin/git -C "$source_repo" switch -q -c side-fixture "$stable_commit"
print -r -- side > "$source_repo/side.txt"
/usr/bin/git -C "$source_repo" add side.txt
/usr/bin/git -C "$source_repo" commit -q -m "side fixture"
/usr/bin/git -C "$source_repo" switch -q hotfix/v1.9.25
/usr/bin/git -C "$source_repo" merge -q --no-ff side-fixture -m "merge fixture"
merge_hotfix_commit="$(/usr/bin/git -C "$source_repo" rev-parse HEAD)"
/usr/bin/git -C "$source_repo" push -q origin hotfix/v1.9.25
if REPOSITORY_ROOT="$source_repo" GH_BIN="$fake_gh" \
    "$source_guard" hotfix/v1.9.25 "$merge_hotfix_commit" 1.9.25 >/dev/null 2>&1; then
  print -u2 "release source gate accepted a merged Hotfix history"
  exit 1
fi

# Exercise the immutable CDN occupancy gate without touching the network.
fake_bin="$WORK_DIR/bin"
/bin/mkdir -p "$fake_bin"
print -r -- '#!/bin/zsh
set -euo pipefail
mode="${CDN_FIXTURE_MODE:-404}"
is_head=false
for arg in "$@"; do
  [[ "$arg" == --head ]] && is_head=true
done
if [[ "$mode" == fallback && "$is_head" == true ]]; then
  print -rn -- 405
  exit 0
fi
case "$mode" in
  404|200|302|503) print -rn -- "$mode" ;;
  fallback) print -rn -- 404 ;;
  *) print -rn -- 000; exit 1 ;;
esac' > "$fake_bin/curl"
/bin/chmod 755 "$fake_bin/curl"
PATH="$fake_bin:$PATH" CDN_FIXTURE_MODE=404 \
  "$ROOT/scripts/verify-preview-cdn-availability.sh" v9.9.9 >/dev/null
if PATH="$fake_bin:$PATH" CDN_FIXTURE_MODE=200 \
  "$ROOT/scripts/verify-preview-cdn-availability.sh" v9.9.9 >/dev/null 2>&1; then
  print -u2 "CDN occupancy gate accepted an existing 200 path"
  exit 1
else
  test "$?" -eq 42
fi
if PATH="$fake_bin:$PATH" CDN_FIXTURE_MODE=503 \
  "$ROOT/scripts/verify-preview-cdn-availability.sh" v9.9.9 >/dev/null 2>&1; then
  print -u2 "CDN occupancy gate accepted an indeterminate 503 path"
  exit 1
fi
if PATH="$fake_bin:$PATH" CDN_FIXTURE_MODE=fallback \
  "$ROOT/scripts/verify-preview-cdn-availability.sh" v9.9.9 >/dev/null 2>&1; then
  :
else
  print -u2 "CDN occupancy gate did not use the GET fallback after HEAD 405"
  exit 1
fi

# Build a deterministic canonical payload fixture and exercise the manifest gate.
public_dir="$WORK_DIR/public"
/bin/mkdir -p "$public_dir"
version=9.9.9
for name in \
  "SayAll-$version-Intel-Uninstaller.pkg" \
  "SayAll-$version-Intel-Installer.pkg" \
  "Remote-Mic-$version-Intel.dmg" \
  "Remote-Mic-$version-Intel.zip" \
  "SayAll-$version-Uninstaller.pkg" \
  "SayAll-$version-Installer.pkg" \
  "Remote-Mic-$version.dmg" \
  "Remote-Mic-$version.en.txt" \
  "Remote-Mic-$version.zh.txt" \
  "Remote-Mic-$version.zip" \
  appcast-intel.xml appcast.xml; do
  print -rn -- "fixture:$name" > "$public_dir/$name"
done
( cd "$public_dir" && /usr/bin/shasum -a 256 "Remote-Mic-$version.dmg" "Remote-Mic-$version-Intel.dmg" > "Remote-Mic-$version.dmg.sha256" )

manifest="$WORK_DIR/staged-assets.json"
{
  print -r -- '{"schemaVersion":1,"repository":"HD838A/remote-mic-app","tag":"v9.9.9","sourceCommit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"9.9.9","build":"999","assets":['
  first=true
  for file_path in "$public_dir"/*; do
    [[ "$first" == true ]] || print -rn -- ','
    first=false
    size="$(/usr/bin/stat -f '%z' "$file_path")"
    sha="$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{print $1}')"
    jq -cn --arg name "${file_path:t}" --argjson size "$size" --arg sha256 "$sha" \
      '{name:$name,size:$size,sha256:$sha256}'
  done
  print -r -- ']}'
} | jq -S . > "$manifest"

"$ROOT/scripts/verify-staged-release-assets.sh" "$manifest" "$public_dir" >/dev/null
print -rn -- tampered >> "$public_dir/Remote-Mic-$version.zip"
if "$ROOT/scripts/verify-staged-release-assets.sh" "$manifest" "$public_dir" >/dev/null 2>&1; then
  print -u2 "manifest accepted tampered payload"
  exit 1
fi
print -rn -- fixture > "$public_dir/Remote-Mic-$version.zip"
if [[ ! -e "$public_dir/extra.txt" ]]; then
  print -rn -- extra > "$public_dir/extra.txt"
fi
if "$ROOT/scripts/verify-staged-release-assets.sh" "$manifest" "$public_dir" >/dev/null 2>&1; then
  print -u2 "manifest accepted an extra payload"
  exit 1
fi

print "MACOS RELEASE FLOW FIXTURE PASS"

)

test_ci_classification() (
ROOT="$SCRIPT_ROOT"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/sayall-ci-classification-test.XXXXXX)"
cleanup() {
  local trash_target="$HOME/.Trash/sayall-ci-classification-test.$(/bin/date +%s).$$.$RANDOM"
  /bin/mkdir -p "$HOME/.Trash"
  /bin/mv "$WORK_DIR" "$trash_target"
}
trap cleanup EXIT

case_number=0
for test_case in \
  '.github/workflows/mac-ci.yml:true:true' \
  'scripts/notarize-release.sh:true:true' \
  'scripts/install-doubao-driver.sh:true:true' \
  'scripts/verify-release-dependency-pins.sh:false:true' \
  'scripts/test-macos-release-flow.sh:false:true' \
  'scripts/verify-release-control-plane-diff.sh:true:true' \
  'scripts/verify-repository-governance.sh:false:false:true' \
  '.github/workflows/repository-governance.yml:false:false:true' \
  'script/build_and_run.sh:false:false' \
  'Testing/LocalExperiment.command:true:false' \
  'Testing/LocalProbe.swift:true:false' \
  'scripts/local-log-collector.sh:true:true' \
  'Sources/RemoteMic/BridgeAppModel.swift:true:true' \
  'Sources/RemoteMic/FutureFeature.swift:true:false' \
  'scripts/unknown-future-tool.sh:true:true' \
  'Testing/Manual.md:false:false'; do
  IFS=: read -r changed_path expected_product expected_release expected_repository <<< "$test_case"
  expected_repository="${expected_repository:-false}"
  (( case_number += 1 ))
  fixture_repo="$WORK_DIR/case-$case_number"
  /usr/bin/git init -q "$fixture_repo"
  /usr/bin/git -C "$fixture_repo" config user.name Fixture
  /usr/bin/git -C "$fixture_repo" config user.email fixture@example.invalid
  /usr/bin/git -C "$fixture_repo" commit -q --allow-empty -m baseline
  base_commit="$(/usr/bin/git -C "$fixture_repo" rev-parse HEAD)"
  /bin/mkdir -p "$fixture_repo/${changed_path:h}"
  print -r -- fixture > "$fixture_repo/$changed_path"
  /usr/bin/git -C "$fixture_repo" add .
  /usr/bin/git -C "$fixture_repo" commit -q -m change
  result="$(REPOSITORY_ROOT="$fixture_repo" \
    "$ROOT/scripts/verify-release-control-plane-diff.sh" --classify "$base_commit" HEAD)"
  print -r -- "$result" | /usr/bin/grep -Fxq "product_change=$expected_product"
  print -r -- "$result" | /usr/bin/grep -Fxq "release_checks=$expected_release"
  print -r -- "$result" | /usr/bin/grep -Fxq "repository_only=$expected_repository"
  if [[ "$expected_product" == false && "$expected_release" == true ]]; then
    REPOSITORY_ROOT="$fixture_repo" "$ROOT/scripts/verify-release-control-plane-diff.sh" "$base_commit" HEAD
  fi
  if [[ "$expected_repository" == true ]]; then
    print -r -- documentation > "$fixture_repo/AGENTS.md"
    /usr/bin/git -C "$fixture_repo" add .
    /usr/bin/git -C "$fixture_repo" commit -q -m 'mixed governance and docs'
    REPOSITORY_ROOT="$fixture_repo" /bin/bash "$ROOT/scripts/verify-release-control-plane-diff.sh" --classify "$base_commit" HEAD | /usr/bin/grep -Fxq 'repository_only=true'
    /bin/mkdir -p "$fixture_repo/Sources"
    print -r -- product > "$fixture_repo/Sources/Product.swift"
    /usr/bin/git -C "$fixture_repo" add .
    /usr/bin/git -C "$fixture_repo" commit -q -m 'mixed governance and product'
    REPOSITORY_ROOT="$fixture_repo" "$ROOT/scripts/verify-release-control-plane-diff.sh" --classify "$base_commit" HEAD | /usr/bin/grep -Fxq 'product_change=true'
  fi
  if REPOSITORY_ROOT="$fixture_repo" "$ROOT/scripts/verify-release-control-plane-diff.sh" --classify 0000000000000000000000000000000000000000 HEAD > "$WORK_DIR/invalid-diff.log" 2>&1; then
    print -u2 "classifier accepted an invalid Git diff"
    exit 1
  fi
done

# Pin scheduling boundaries and execute the actual required-context shell gate.
ci_workflow="$ROOT/.github/workflows/mac-ci.yml"
classifier_job="$(/usr/bin/awk '/^  classify_changes:/ { capture=1 } /^  public_test:/ { exit } capture { print }' "$ci_workflow")"
print -r -- "$classifier_job" | /usr/bin/grep -Fq 'runs-on: ubuntu-latest'
/usr/bin/grep -Fq 'runs-on: ${{ (needs.classify_changes.outputs.product_change == '\''true'\'' || needs.classify_changes.outputs.release_checks == '\''true'\'') && '\''macos-15'\'' || '\''ubuntu-latest'\'' }}' "$ci_workflow"
print -r -- "$classifier_job" | /usr/bin/grep -Fq 'Detect private dependency access'
print -r -- "$classifier_job" | /usr/bin/grep -Fq 'command -v zsh'
[[ "$(/usr/bin/awk '/^jobs:/ { capture=1; next } capture && /^  [a-z_]+:$/ { count++ } END { print count }' "$ci_workflow")" == 4 ]]
/usr/bin/grep -Fq 'group: mac-ci-${{ github.workflow }}-${{ github.ref }}-${{ github.event_name == '\''pull_request'\'' && '\''pr'\'' || github.sha }}' "$ci_workflow"
/usr/bin/grep -Fq 'cancel-in-progress: ${{ github.event_name == '\''pull_request'\'' }}' "$ci_workflow"
summary_gate="$(/usr/bin/awk '
  /- name: Require every applicable macOS CI lane/ { found=1 }
  found && /run: \|/ { capture=1; next }
  capture { print }
' "$ci_workflow")"
[[ -n "$summary_gate" ]]
for gate_case in \
  'true:true:success:success:true:success:0' \
  'true:false:success:skipped:false:success:0' \
  'false:false:success:skipped::success:0' \
  'false:true:success:skipped::success:0' \
  'true:true:failure:success:true:success:1' \
  'true:true:success:skipped:true:success:1' \
  'true:true:success:cancelled:true:success:1' \
  'true:false:success:success:false:success:1' \
  'false:false:success:skipped:true:success:1' \
  'false:false:success:skipped::failure:1' \
  'false:true:success:skipped::failure:1' \
  'true:true:success:skipped::success:1' \
  'true:unknown:success:success:true:success:1' \
  'unknown:false:success:skipped::success:1'; do
  IFS=: read -r product release classify private available public expected_status <<< "$gate_case"
  gate_status=0
  CLASSIFY_RESULT="$classify" PRODUCT_CHANGE="$product" RELEASE_CHECKS_REQUIRED="$release" \
    PRIVATE_TEST_RESULT="$private" PRIVATE_AVAILABLE="$available" PUBLIC_RESULT="$public" \
    /bin/bash -e -c "$summary_gate" || gate_status=1
  [[ "$gate_status" == "$expected_status" ]]
done

# Exercise the consolidated architecture entry without signatures or Apple services.
fake_runner="$WORK_DIR/fake-variant-runner"
print -r -- '#!/bin/zsh
set -euo pipefail
print -r -- "$RELEASE_VARIANT" >> "$VARIANT_LOG"
' > "$fake_runner"
/bin/chmod 755 "$fake_runner"
for parallel_mode in 0 1; do
  variant_log="$WORK_DIR/variants-$parallel_mode.log"
  PARALLEL_RELEASE_VARIANTS="$parallel_mode" GENERATE_SPARKLE_UPDATE=0 \
    RELEASE_VARIANT_RUNNER="$fake_runner" VARIANT_LOG="$variant_log" \
    "$ROOT/scripts/notarize-release.sh" --all > "$WORK_DIR/variants-$parallel_mode.output"
  [[ "$(LC_ALL=C sort "$variant_log")" == $'apple-silicon\nintel' ]]
done
print "CI CLASSIFICATION AND VARIANT ENTRY FIXTURE PASS"
)

case "${1:-all}" in
  all) test_ci_classification; test_flow; test_metadata ;;
  flow) test_ci_classification; test_flow ;;
  metadata) test_metadata ;;
  ready-ci) test_ready_ci ;;
  *) print -u2 "usage: $0 [all|flow|metadata|ready-ci]"; exit 2 ;;
esac
