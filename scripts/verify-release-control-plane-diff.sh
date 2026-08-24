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
  scripts/test-release-resume-workflow.sh
  scripts/verify-release-control-plane-diff.sh
)

normalize_workflow() {
  /usr/bin/awk '
    $0 == "  resume-preview-publication:" { skipping = 1; next }
    skipping && $0 ~ /^  [A-Za-z0-9_-]+:/ { skipping = 0 }
    !skipping { print }
  '
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
