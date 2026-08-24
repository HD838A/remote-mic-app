#!/bin/zsh
set -euo pipefail

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
BASE_COMMIT="${1:-}"
HEAD_COMMIT="${2:-HEAD}"

[[ "$BASE_COMMIT" =~ '^[0-9a-f]{40}$' ]] || {
  print -u2 "usage: $0 <base-commit> [head-commit]"
  exit 2
}

CONTROL_PLANE_SCRIPTS=(
  scripts/publish-release.sh
  scripts/resume-preview-publication.sh
  scripts/release-slo-ledger.sh
  scripts/release-user-wall-watchdog.sh
  scripts/reconcile-release-event.sh
  scripts/resolve-release-request-attestation.sh
  scripts/resolve-stable-request-attestation.sh
  scripts/release-pipeline-digest.sh
  scripts/test-release-pipeline-optimization.sh
  scripts/test-release-resume-workflow.sh
  scripts/verify-release-control-plane-diff.sh
)

normalize_workflow() {
  /usr/bin/awk '
    function replace_once(line, old, replacement, position) {
      position = index(line, old)
      if (position == 0) return line
      return substr(line, 1, position - 1) replacement substr(line, position + length(old))
    }
    BEGIN {
      qualification_open_only = "select(.state == \\\"open\\\" and"
      qualification_open_or_merged = "select((.state == \\\"open\\\" or .merged_at != null) and"
    }
    $0 == "  resume-preview-publication:" { skipping = 1; next }
    skipping && $0 ~ /^  [A-Za-z0-9_-]+:/ { skipping = 0 }
    !skipping {
      line = replace_once($0, qualification_open_only, "select(PR_STATE and")
      line = replace_once(line, qualification_open_or_merged, "select(PR_STATE and")
      print line
    }
  '
}

validate_mac_ci_diff() {
  local diff_line content release_job=false
  while IFS= read -r diff_line; do
    case "$diff_line" in
      +++*|---*|@@*) continue ;;
      +*|-*)
        content="${diff_line#?}"
        [[ -z "$content" ]] && continue
        if [[ "$diff_line" == +* && "$content" == *"name: Release control-plane tests"* ]]; then
          release_job=true
          continue
        fi
        [[ "$release_job" == true && "$diff_line" == +* ]] && continue
        case "$content" in
          *release_control_plane*|*release-control-plane*|*"Release control-plane"*|*verify-release-control-plane-diff.sh*|\
          *.github/workflows/mac-release-package.yml*|*.github/workflows/mac-ci.yml*|\
          *scripts/publish-release.sh*|*scripts/resume-preview-publication.sh*|\
          *scripts/release-slo-ledger.sh*|*scripts/release-user-wall-watchdog.sh*|\
          *scripts/reconcile-release-event.sh*|*scripts/resolve-release-request-attestation.sh*|\
          *scripts/resolve-stable-request-attestation.sh*|*scripts/release-pipeline-digest.sh*|\
          *scripts/test-release-pipeline-optimization.sh*|*scripts/test-release-resume-workflow.sh*|*docs_only=false*|*";;"*|*GITHUB_EVENT_NAME*|*GITHUB_WORKSPACE*|*needs.classify_changes.outputs.docs_only*|*needs.classify_changes.outputs.reuse_parent_main_ci*|*"needs: classify_changes"*) ;;
          *)
            print -u2 "macOS CI change is outside the release control-plane classifier: $content"
            return 1
            ;;
        esac
        ;;
    esac
  done < <(git -C "$ROOT" diff --unified=0 "$BASE_COMMIT...$HEAD_COMMIT" -- .github/workflows/mac-ci.yml)
}

control_changed=false
while IFS= read -r changed_path; do
  [[ -n "$changed_path" ]] || continue
  case "$changed_path" in
    *.md|Screenshots/*)
      continue
      ;;
    .github/workflows/mac-release-package.yml)
      base_workflow="$(git -C "$ROOT" show "$BASE_COMMIT:$changed_path")"
      head_workflow="$(git -C "$ROOT" show "$HEAD_COMMIT:$changed_path")"
      if ! diff -u \
        <(print -r -- "$base_workflow" | normalize_workflow) \
        <(print -r -- "$head_workflow" | normalize_workflow) \
        >/dev/null; then
        print -u2 "release workflow change is outside the recovery Job"
        exit 1
      fi
      control_changed=true
      ;;
    .github/workflows/mac-ci.yml)
      validate_mac_ci_diff || exit 1
      control_changed=true
      ;;
    *)
      allowed=false
      for control_path in "${CONTROL_PLANE_SCRIPTS[@]}"; do
        if [[ "$changed_path" == "$control_path" ]]; then
          allowed=true
          break
        fi
      done
      if [[ "$allowed" != true ]]; then
        print -u2 "non-control-plane path changed: $changed_path"
        exit 1
      fi
      control_changed=true
      ;;
  esac
done < <(git -C "$ROOT" diff --name-only "$BASE_COMMIT...$HEAD_COMMIT")

[[ "$control_changed" == true ]] || {
  print -u2 "no release control-plane change detected"
  exit 1
}
