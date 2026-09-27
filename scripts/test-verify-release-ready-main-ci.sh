#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
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
