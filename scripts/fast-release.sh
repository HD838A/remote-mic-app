#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
PLIST="$ROOT/Resources/Info.plist"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
WORKFLOW_FILE="mac-release-package.yml"
GH_BIN="${GH_BIN:-gh}"
REQUEST_STARTED_AT="${RELEASE_REQUEST_STARTED_AT:-}"
REQUEST_ID="${RELEASE_REQUEST_ID:-}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: RELEASE_REQUEST_STARTED_AT=<unix-epoch> RELEASE_REQUEST_ID=<immutable-id> $0"
  exit 2
fi
if [[ ! "$REQUEST_STARTED_AT" =~ '^[0-9]+$' ]]; then
  print -u2 "fast release requires RELEASE_REQUEST_STARTED_AT as the original Unix epoch seconds"
  exit 2
fi
if [[ ! "$REQUEST_ID" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$' ]]; then
  print -u2 "fast release requires RELEASE_REQUEST_ID as an immutable 8-64 character identifier"
  exit 2
fi
if (( REQUEST_STARTED_AT > $(/bin/date +%s) )); then
  print -u2 "RELEASE_REQUEST_STARTED_AT cannot be in the future"
  exit 2
fi
for command_name in git jq plutil unzip "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

cd "$ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "fast release requires a clean committed worktree"
  exit 1
fi
BRANCH="$(git symbolic-ref --quiet --short HEAD)" || {
  print -u2 "fast release requires a branch, not detached HEAD"
  exit 1
}
if [[ ! "$BRANCH" =~ '^release/pre-v([0-9]+\.[0-9]+\.[0-9]+)$' ]]; then
  print -u2 "fast release requires the single candidate branch release/pre-vX.Y.Z"
  exit 1
fi
BRANCH_VERSION="${match[1]}"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PLIST")"
if [[ "$BRANCH_VERSION" != "$VERSION" ]]; then
  print -u2 "fast release branch version $BRANCH_VERSION does not match $VERSION"
  exit 1
fi
if [[ ! "$BUILD" =~ '^[0-9]+$' ]]; then
  print -u2 "fast release requires a numeric CFBundleVersion"
  exit 1
fi
RELEASE_TAG="v$VERSION"
HEAD_COMMIT="$(git rev-parse HEAD)"
EXPECTED_RUN_TITLE="mac-release preview $RELEASE_TAG $REQUEST_ID $HEAD_COMMIT"
if [[ ! "$HEAD_COMMIT" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "fast release requires an exact 40-character candidate commit"
  exit 1
fi

verify_remote_candidate_identity() {
  local remote_records remote_sha remote_ref candidate_record
  local -a matching_records

  remote_records="$(git ls-remote --heads origin 'refs/heads/release/pre-v*')"
  matching_records=()
  while IFS=$'\t' read -r remote_sha remote_ref; do
    [[ -n "$remote_sha" && -n "$remote_ref" ]] || continue
    case "$remote_ref" in
      "refs/heads/$BRANCH"|"refs/heads/$BRANCH"-*)
        matching_records+=("$remote_sha"$'\t'"$remote_ref")
        ;;
    esac
  done <<< "$remote_records"

  if (( ${#matching_records[@]} != 1 )); then
    print -u2 "fast release requires exactly one remote candidate branch for $RELEASE_TAG"
    exit 1
  fi
  candidate_record="${matching_records[1]}"
  IFS=$'\t' read -r remote_sha remote_ref <<< "$candidate_record"
  if [[ "$remote_ref" != "refs/heads/$BRANCH" || "$remote_sha" != "$HEAD_COMMIT" ]]; then
    print -u2 "fast release requires origin/$BRANCH to equal the exact local candidate commit"
    exit 1
  fi
}

GITHUB_REF_NAME="$BRANCH" ALLOW_FROZEN_BASE_MAIN=1 \
  "$ROOT/scripts/verify-preview-branch.sh"
verify_remote_candidate_identity

GITHUB_REPOSITORY="$REPOSITORY" \
GITHUB_REF_NAME="$BRANCH" \
GH_BIN="$GH_BIN" \
EXPECTED_COMMIT="$HEAD_COMMIT" \
RELEASE_TAG="$RELEASE_TAG" \
REQUIRE_PREVIEW_RECORDING_PR=1 \
  "$ROOT/scripts/verify-preview-candidate-ci.sh"

PIPELINE_DIGEST="$("$ROOT/scripts/release-pipeline-digest.sh")"
if [[ ! "$PIPELINE_DIGEST" =~ '^[0-9a-f]{64}$' ]]; then
  print -u2 "fast release requires an exact release pipeline SHA-256 digest"
  exit 1
fi
GITHUB_REPOSITORY="$REPOSITORY" GH_BIN="$GH_BIN" \
  "$ROOT/scripts/verify-release-pipeline-qualification.sh" "$PIPELINE_DIGEST"

# Close the local/remote identity race immediately before the only mutation.
git fetch --no-tags origin "refs/heads/$BRANCH" >/dev/null
if [[ -n "$(git status --porcelain)" ||
      "$(git rev-parse HEAD)" != "$HEAD_COMMIT" ||
      "$(git rev-parse FETCH_HEAD)" != "$HEAD_COMMIT" ]]; then
  print -u2 "fast release candidate changed during preflight"
  exit 1
fi
verify_remote_candidate_identity
if [[ "$("$ROOT/scripts/release-pipeline-digest.sh")" != "$PIPELINE_DIGEST" ]]; then
  print -u2 "fast release pipeline changed during preflight"
  exit 1
fi

print "FAST RELEASE PREFLIGHT PASS: $RELEASE_TAG ($BUILD) at $HEAD_COMMIT"
print "Dispatching the sole protected preview workflow for request $REQUEST_ID"
DISPATCH_STARTED_AT="$(/bin/date -u +'%Y-%m-%dT%H:%M:%SZ')"
"$GH_BIN" workflow run "$WORKFLOW_FILE" \
  --repo "$REPOSITORY" \
  --ref "$BRANCH" \
  --raw-field "tag=$RELEASE_TAG" \
  --raw-field "release_mode=preview" \
  --raw-field "expected_commit=$HEAD_COMMIT" \
  --raw-field "expected_pipeline_digest=$PIPELINE_DIGEST" \
  --raw-field "request_started_at=$REQUEST_STARTED_AT" \
  --raw-field "request_id=$REQUEST_ID"

RUN_ID=""
RUN_URL=""
for lookup_attempt in {1..6}; do
  runs_json=""
  if runs_json="$(
    "$GH_BIN" run list \
      --repo "$REPOSITORY" \
      --workflow "$WORKFLOW_FILE" \
      --branch "$BRANCH" \
      --commit "$HEAD_COMMIT" \
      --event workflow_dispatch \
      --limit 20 \
      --json databaseId,createdAt,displayTitle,event,headBranch,headSha,url
  )"; then
    matching_runs="$(
      print -r -- "$runs_json" | jq -c \
        --arg branch "$BRANCH" \
        --arg headSha "$HEAD_COMMIT" \
        --arg runTitle "$EXPECTED_RUN_TITLE" \
        --arg dispatchedAt "$DISPATCH_STARTED_AT" '
          [.[] | select(
            .event == "workflow_dispatch" and
            .headBranch == $branch and
            .headSha == $headSha and
            .displayTitle == $runTitle and
            .createdAt >= $dispatchedAt
          )]
        '
    )"
    matching_count="$(print -r -- "$matching_runs" | jq -r 'length')"
    if (( matching_count > 1 )); then
      print -u2 "Preview workflow dispatch succeeded, but multiple new exact-identity Runs were found."
      print -u2 "Do not redispatch automatically; reconcile the existing workflow_dispatch Runs for $BRANCH at $HEAD_COMMIT."
      exit 3
    fi
    if (( matching_count == 1 )); then
      candidate_run_id="$(print -r -- "$matching_runs" | jq -r '.[0].databaseId')"
      run_json=""
      if run_json="$(
        "$GH_BIN" api "repos/$REPOSITORY/actions/runs/$candidate_run_id"
      )" && print -r -- "$run_json" | jq -e \
        --arg workflowPath ".github/workflows/$WORKFLOW_FILE" \
        --arg branch "$BRANCH" \
        --arg headSha "$HEAD_COMMIT" \
        --arg runTitle "$EXPECTED_RUN_TITLE" \
        --arg dispatchedAt "$DISPATCH_STARTED_AT" \
        --argjson runId "$candidate_run_id" '
          .id == $runId and
          .path == $workflowPath and
          .event == "workflow_dispatch" and
          .head_branch == $branch and
          .head_sha == $headSha and
          .display_title == $runTitle and
          .created_at >= $dispatchedAt and
          (.html_url | type == "string" and length > 0)
        ' >/dev/null; then
        RUN_ID="$candidate_run_id"
        RUN_URL="$(print -r -- "$run_json" | jq -r '.html_url')"
        break
      fi
    fi
  fi
  if (( lookup_attempt < 6 )); then
    /bin/sleep 5
  fi
done

if [[ -z "$RUN_ID" || -z "$RUN_URL" ]]; then
  print -u2 "Preview workflow dispatch succeeded, but its Run identity was not resolved within 25 seconds."
  print -u2 "Do not redispatch automatically; reconcile the existing workflow_dispatch Run for $BRANCH at $HEAD_COMMIT."
  exit 3
fi

print "RUN_ID: $RUN_ID"
print "RUN_URL: $RUN_URL"
