#!/bin/zsh
set -euo pipefail

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
SOURCE_REF="${1:-}"

if [[ "$#" -gt 1 ]]; then
  print -u2 "usage: $0 [git-ref]"
  exit 2
fi

PIPELINE_FILES=(
  Package.swift
  Package.resolved
  .github/workflows/mac-release-package.yml
  .github/workflows/mac-preview-candidate.yml
  .github/workflows/mac-ci.yml
  .github/workflows/mac-stable-promote.yml
  .github/workflows/release-guard.yml
  scripts/build-app.sh
  scripts/build-dmg.sh
  scripts/build-doubao-driver.sh
  scripts/build-doubao-driver-pkg.sh
  scripts/check-repository-boundaries.sh
  scripts/fast-release.sh
  scripts/notarize-release.sh
  scripts/package-macos-release-in-actions.sh
  scripts/package-macos-release-variants.sh
  scripts/prepare-preview-recording-pr.sh
  scripts/publish-release.sh
  scripts/reconcile-release-event.sh
  scripts/release-pipeline-digest.sh
  scripts/resume-preview-publication.sh
  scripts/run-release-stage.sh
  scripts/release-slo-ledger.sh
  scripts/release-user-wall-watchdog.sh
  scripts/release-variant.sh
  scripts/resolve-release-request-attestation.sh
  scripts/resolve-stable-request-attestation.sh
  scripts/run-trusted-release-validation.sh
  scripts/test.sh
  scripts/verify-app.sh
  scripts/verify-dmg.sh
  scripts/verify-doubao-driver.sh
  scripts/verify-doubao-driver-pkg.sh
  scripts/verify-release-dependency-pins.sh
  scripts/verify-release-metadata-diff.sh
  scripts/verify-release-ready-main-ci.sh
  scripts/verify-release-pipeline-qualification-source.sh
  scripts/verify-release-pipeline-qualification.sh
  scripts/verify-release-timeout-budgets.sh
  scripts/verify-release-workflow-gh-token.sh
  scripts/verify-preview-branch.sh
  scripts/verify-preview-candidate-ci.sh
)

CONTROL_PLANE_ONLY_SCRIPTS=(
  scripts/test-release-resume-workflow.sh
  scripts/verify-release-control-plane-diff.sh
)

PIPELINE_TREES=(
  packaging/release-variants
  packaging/doubao-driver
  third_party/blackhole
)

tree_paths=()
for tree_path in "${PIPELINE_TREES[@]}"; do
  if [[ -n "$SOURCE_REF" ]]; then
    entries="$(git -C "$ROOT" ls-tree -r --name-only "$SOURCE_REF" -- "$tree_path")"
  else
    entries="$(git -C "$ROOT" ls-files -- "$tree_path")"
  fi
  [[ -n "$entries" ]] || {
    print -u2 "release pipeline tree is empty or unavailable${SOURCE_REF:+ at $SOURCE_REF}: $tree_path"
    exit 1
  }
  tree_paths+=("${(@f)entries}")
done

PIPELINE_PATHS=("${PIPELINE_FILES[@]}" "${tree_paths[@]}")
PIPELINE_PATHS=("${(@f)$(print -l -- "${PIPELINE_PATHS[@]}" | LC_ALL=C /usr/bin/sort -u)}")

typeset -A PIPELINE_PATH_SET
for relative_path in "${PIPELINE_PATHS[@]}"; do
  PIPELINE_PATH_SET[$relative_path]=1
  if [[ -n "$SOURCE_REF" ]]; then
    git -C "$ROOT" cat-file -e "$SOURCE_REF:$relative_path" 2>/dev/null || {
      print -u2 "release pipeline file is unavailable at $SOURCE_REF: $relative_path"
      exit 1
    }
  else
    [[ -r "$ROOT/$relative_path" || -L "$ROOT/$relative_path" ]] || {
      print -u2 "release pipeline file is unreadable: $relative_path"
      exit 1
    }
  fi
done

read_pipeline_path() {
  local relative_path="$1"
  if [[ -n "$SOURCE_REF" ]]; then
    git -C "$ROOT" show "$SOURCE_REF:$relative_path"
  else
    /bin/cat "$ROOT/$relative_path"
  fi
}

# Keep the explicit manifest honest. Any repository shell helper referenced by
# a workflow or another release helper must itself be part of the digest.
for relative_path in "${PIPELINE_PATHS[@]}"; do
  case "$relative_path" in
    *.sh|*.yml|*.yaml) ;;
    *) continue ;;
  esac
  referenced_scripts="$(
    read_pipeline_path "$relative_path" |
      /usr/bin/awk '
        {
          line = $0
          pattern = "(^|[[:space:]\"=;(])((\\./)|(\\$ROOT/))?scripts/[A-Za-z0-9._/-]+\\.sh"
          while (match(line, pattern)) {
            token = substr(line, RSTART, RLENGTH)
            sub(/^.*scripts\//, "scripts/", token)
            print token
            line = substr(line, RSTART + RLENGTH)
          }
        }
      ' |
      LC_ALL=C /usr/bin/sort -u || true
  )"
  for referenced_path in "${(@f)referenced_scripts}"; do
    [[ -n "$referenced_path" ]] || continue
    if (( ${CONTROL_PLANE_ONLY_SCRIPTS[(Ie)$referenced_path]} )); then
      continue
    fi
    if (( ${+PIPELINE_PATH_SET[$referenced_path]} )); then
      continue
    fi
    if [[ -n "$SOURCE_REF" ]]; then
      git -C "$ROOT" cat-file -e "$SOURCE_REF:$referenced_path" 2>/dev/null || {
        print -u2 "release pipeline references an unavailable helper at $SOURCE_REF: $referenced_path"
        exit 1
      }
    else
      [[ -e "$ROOT/$referenced_path" || -L "$ROOT/$referenced_path" ]] || {
        print -u2 "release pipeline references an unavailable helper: $referenced_path"
        exit 1
      }
    fi
    print -u2 "release pipeline helper is outside the digest manifest: $referenced_path"
    exit 1
  done
done

(
  cd "$ROOT"
  for relative_path in "${PIPELINE_PATHS[@]}"; do
    if [[ -n "$SOURCE_REF" ]]; then
      tree_entry="$(git ls-tree "$SOURCE_REF" -- "$relative_path")"
      [[ -n "$tree_entry" ]] || {
        print -u2 "release pipeline file is unavailable at $SOURCE_REF: $relative_path"
        exit 1
      }
      print -r -- "$tree_entry"
    else
      [[ -r "$relative_path" || -L "$relative_path" ]] || {
        print -u2 "release pipeline file is unreadable: $relative_path"
        exit 1
      }
      if [[ -L "$relative_path" ]]; then
        git_mode=120000
        link_target="$(/usr/bin/readlink "$relative_path")"
        blob_id="$(print -rn -- "$link_target" | git hash-object --stdin)"
      elif [[ -x "$relative_path" ]]; then
        git_mode=100755
        blob_id="$(git hash-object --no-filters "$relative_path")"
      else
        git_mode=100644
        blob_id="$(git hash-object --no-filters "$relative_path")"
      fi
      print -r -- "$git_mode blob $blob_id"$'\t'"$relative_path"
    fi
  done
) | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
