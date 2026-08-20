#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
REPOSITORY="HD838A/remote-mic-app"
RELEASE_TAG="${1:-}"
EVENT_ACTOR="${2:-}"
RECORD_PREVIEW="${3:-0}"
ALLOWED_ACTORS="${STABLE_RELEASE_ACTORS:-HD838A}"

if [[ ( "$#" -ne 2 && "$#" -ne 3 ) || ! "$RELEASE_TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' || -z "$EVENT_ACTOR" ]]; then
  print -u2 "usage: $0 vX.Y.Z actor [record-preview]"
  exit 1
fi
case "$RECORD_PREVIEW" in
  0|1) ;;
  *) print -u2 "record-preview must be 0 or 1"; exit 1 ;;
esac
for command_name in gh git jq shasum stat; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command_name"
    exit 1
  }
done

WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-release-guard.XXXXXX)"
cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remotemic-release-guard.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected release guard path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

cd "$ROOT"
git fetch origin main --tags >/dev/null
RELEASE_STATE="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" --jq '[.draft, .prerelease] | @tsv')"
if [[ "$RELEASE_STATE" != $'false\ttrue' && "$RELEASE_STATE" != $'false\tfalse' ]]; then
  print -u2 "release guard only accepts a published release or pre-release"
  exit 1
fi
if [[ "$RELEASE_STATE" == $'false\ttrue' && "$RECORD_PREVIEW" != "1" ]]; then
  print "RELEASE GUARD PASS: candidate remains pre-release"
  exit 0
fi

gh release download "$RELEASE_TAG" --repo "$REPOSITORY" --dir "$WORK_DIR"
PROVENANCE="$WORK_DIR/candidate-provenance.json"
PROMOTION="$WORK_DIR/stable-promotion.json"
TAG_COMMIT="$(git rev-parse "$RELEASE_TAG^{commit}")"

verify_candidate_provenance() {
  test -f "$PROVENANCE"
  jq -e \
    --arg repository "$REPOSITORY" \
    --arg tag "$RELEASE_TAG" \
    --arg tagCommit "$TAG_COMMIT" \
    '(.schemaVersion == 1 or .schemaVersion == 2) and
     .repository == $repository and .tag == $tag and
     .tagCommit == $tagCommit and
     .version == ($tag | ltrimstr("v")) and
     (.build | test("^[0-9]+$")) and
     (.candidateBranch == ("release/pre-" + $tag) or
      ((.candidateBranch | startswith("release/pre-" + $tag + "-rerun")) and
       (.candidateBranch | ltrimstr("release/pre-" + $tag + "-rerun") | test("^([2-9][0-9]*)?$")))) and
     (if .schemaVersion == 2 then (.baseMainCommit | test("^[0-9a-f]{40}$")) else true end) and
     ((.payloadAssets | length) == 11 or
      (.payloadAssets | length) == 14 or
      (.payloadAssets | length) == 16)' "$PROVENANCE" >/dev/null

  if [[ "$(jq -r '.schemaVersion' "$PROVENANCE")" == "2" ]]; then
    local base_main_commit
    base_main_commit="$(jq -r '.baseMainCommit' "$PROVENANCE")"
    if [[ "$(git rev-parse "$TAG_COMMIT^")" != "$base_main_commit" ]]; then
      print -u2 "release guard baseMainCommit is not the tag commit's direct parent"
      exit 1
    fi
    if ! git merge-base --is-ancestor "$base_main_commit" origin/main; then
      print -u2 "release guard baseMainCommit is not contained in main history"
      exit 1
    fi
  fi

  local asset_name expected_size expected_sha file_path actual_size actual_sha
  while IFS=$'\t' read -r asset_name expected_size expected_sha; do
    file_path="$WORK_DIR/$asset_name"
    test -f "$file_path"
    actual_size="$(/usr/bin/stat -f '%z' "$file_path")"
    actual_sha="$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{ print $1 }')"
    if [[ "$actual_size" != "$expected_size" || "$actual_sha" != "$expected_sha" ]]; then
      print -u2 "release guard asset digest mismatch: $asset_name"
      exit 1
    fi
  done < <(jq -r '.payloadAssets[] | [.name, (.size | tostring), .sha256] | @tsv' "$PROVENANCE")
}

ensure_preview_candidate_pr() {
  local candidate_branch remote_branch_commit pr_number pr_url pr_json pr_is_draft
  candidate_branch="$(jq -r '.candidateBranch' "$PROVENANCE")"
  remote_branch_commit="$(git ls-remote origin "refs/heads/$candidate_branch" | /usr/bin/awk 'NR == 1 { print $1 }')"
  if [[ "$remote_branch_commit" != "$TAG_COMMIT" ]]; then
    print -u2 "candidate branch is missing or no longer points to the tagged commit"
    exit 1
  fi
  if git merge-base --is-ancestor "$TAG_COMMIT" origin/main; then
    print "RELEASE GUARD: $RELEASE_TAG candidate is already recorded in main"
    return
  fi

  pr_json="$(
    gh pr list \
      --repo "$REPOSITORY" \
      --head "$candidate_branch" \
      --base main \
      --state open \
      --json number,isDraft \
  )"
  pr_number="$(print -r -- "$pr_json" | jq -r '.[0].number // empty')"
  if [[ -z "$pr_number" ]]; then
    pr_url="$(
      gh pr create \
        --repo "$REPOSITORY" \
        --head "$candidate_branch" \
        --base main \
        --title "Record $RELEASE_TAG preview candidate in main" \
        --body "Records the already published $RELEASE_TAG pre-release candidate in main after the required Apple Silicon and Intel checks pass. This PR does not promote the GitHub Release to stable and does not rebuild its signed or notarized assets."
    )"
    pr_number="${pr_url:t}"
  else
    pr_is_draft="$(print -r -- "$pr_json" | jq -r '.[0].isDraft')"
    if [[ "$pr_is_draft" == "true" ]]; then
      gh pr ready "$pr_number" --repo "$REPOSITORY"
      print "RELEASE GUARD: marked preview candidate PR #$pr_number ready after public verification"
    fi
  fi
  gh pr merge "$pr_number" --repo "$REPOSITORY" --auto --merge
  print "RELEASE GUARD: enabled preview candidate auto-merge for PR #$pr_number"
}

verify_candidate_provenance
if [[ "$RELEASE_STATE" == $'false\ttrue' ]]; then
  if [[ "$(jq -r '.schemaVersion' "$PROVENANCE")" == "1" ]]; then
    print "RELEASE GUARD PASS: legacy candidate remains pre-release without automatic main recording"
    exit 0
  fi
  ensure_preview_candidate_pr
  print "RELEASE GUARD PASS: candidate remains pre-release while its commit is recorded in main"
  exit 0
fi

if [[ -f "$PROVENANCE" && -f "$PROMOTION" ]]; then
  jq -e \
    --arg tag "$RELEASE_TAG" \
    --arg tagCommit "$TAG_COMMIT" \
    '.schemaVersion == 1 and .tag == $tag and .tagCommit == $tagCommit and
     (.mainCommit | test("^[0-9a-f]{40}$")) and
     ((.payloadAssets | length) == 11 or
      (.payloadAssets | length) == 14 or
      (.payloadAssets | length) == 16)' "$PROMOTION" >/dev/null
  if ! git merge-base --is-ancestor "$TAG_COMMIT" origin/main; then
    print -u2 "stable promotion manifest exists but the tag is not contained in origin/main"
    exit 1
  fi
  if ! /usr/bin/cmp -s \
    <(jq -S '.payloadAssets' "$PROVENANCE") \
    <(jq -S '.payloadAssets' "$PROMOTION"); then
    print -u2 "stable promotion payload digests do not match the candidate"
    exit 1
  fi
  print "RELEASE GUARD PASS: stable promotion is attested"
  exit 0
fi

gh release edit "$RELEASE_TAG" --repo "$REPOSITORY" --prerelease --latest=false
print "RELEASE GUARD: restored $RELEASE_TAG to pre-release"

actor_allowed=0
for allowed_actor in "${(@s:,:)ALLOWED_ACTORS}"; do
  if [[ "$EVENT_ACTOR" == "$allowed_actor" ]]; then
    actor_allowed=1
    break
  fi
done
if (( actor_allowed == 0 )); then
  print -u2 "release actor is not allowed to request stable promotion: $EVENT_ACTOR"
  exit 1
fi

CANDIDATE_BRANCH="$(jq -r '.candidateBranch' "$PROVENANCE")"
REMOTE_BRANCH_COMMIT="$(git ls-remote origin "refs/heads/$CANDIDATE_BRANCH" | /usr/bin/awk 'NR == 1 { print $1 }')"
if [[ "$REMOTE_BRANCH_COMMIT" != "$TAG_COMMIT" ]]; then
  print -u2 "candidate branch is missing or no longer points to the tagged commit"
  exit 1
fi

if git merge-base --is-ancestor "$TAG_COMMIT" origin/main; then
  gh workflow run mac-stable-promote.yml \
    --repo "$REPOSITORY" \
    --ref main \
    -f "tag=$RELEASE_TAG"
  print "RELEASE GUARD: dispatched protected promotion for $RELEASE_TAG"
  exit 0
fi

PR_NUMBER="$(
  gh pr list \
    --repo "$REPOSITORY" \
    --head "$CANDIDATE_BRANCH" \
    --base main \
    --state open \
    --json number \
    --jq '.[0].number // empty'
)"
if [[ -z "$PR_NUMBER" ]]; then
  PR_URL="$(
    gh pr create \
      --repo "$REPOSITORY" \
      --head "$CANDIDATE_BRANCH" \
      --base main \
      --title "Promote $RELEASE_TAG candidate to main" \
      --body "Automated reconciliation for the existing $RELEASE_TAG candidate. This PR preserves the tagged commit so the same tested assets can be promoted after required checks pass."
  )"
  PR_NUMBER="${PR_URL:t}"
fi
gh label create "stable-promotion-approved" \
  --repo "$REPOSITORY" \
  --color "0E8A16" \
  --description "Exact-version stable promotion requested through the Release guard" \
  --force
gh pr edit "$PR_NUMBER" --repo "$REPOSITORY" --add-label "stable-promotion-approved"
gh pr merge "$PR_NUMBER" --repo "$REPOSITORY" --auto --merge
gh workflow run mac-ci.yml \
  --repo "$REPOSITORY" \
  --ref "$CANDIDATE_BRANCH"
print "RELEASE GUARD: dispatched required CI for $CANDIDATE_BRANCH"
print "RELEASE GUARD: enabled auto-merge for PR #$PR_NUMBER"
