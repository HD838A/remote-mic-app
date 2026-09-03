#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
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
  verify-preview-cdn-availability.sh \
  verify-staged-release-assets.sh recover-preview-stage.sh publish-staged-preview.sh \
  publish-preview-release.sh promote-preview-release.sh prepare-staged-preview-ui-test.sh \
  record-preview-ui-attestation.sh verify-preview-ui-attestation.sh; do
  [[ -x "$ROOT/scripts/$script" ]] || {
    print -u2 "release helper is not executable: $script"
    exit 1
  }
done

for script in \
  prepare-preview-release.sh stage-macos-preview.sh prepare-public-release-assets.sh \
  verify-preview-cdn-availability.sh \
  recover-preview-stage.sh publish-staged-preview.sh publish-preview-release.sh \
  promote-preview-release.sh prepare-staged-preview-ui-test.sh \
  record-preview-ui-attestation.sh verify-preview-ui-attestation.sh; do
  case "$script" in
    prepare-public-release-assets.sh|stage-macos-preview.sh|prepare-preview-release.sh)
      zsh -n "$ROOT/scripts/$script" ;;
    *)
      bash -n "$ROOT/scripts/$script" ;;
  esac
done

package_workflow="$ROOT/.github/workflows/mac-release-package.yml"
publication_workflow="$ROOT/.github/workflows/mac-preview-publication.yml"
stable_workflow="$ROOT/.github/workflows/mac-stable-promote.yml"
ci_workflow="$ROOT/.github/workflows/mac-ci.yml"

/usr/bin/grep -Fq 'mode:' "$package_workflow"
/usr/bin/grep -Fq 'expected_commit:' "$package_workflow"
/usr/bin/grep -Fq 'environment: mac-release' "$package_workflow"
/usr/bin/grep -Fq 'prepare-public-release-assets.sh' "$package_workflow"
/usr/bin/grep -Fq 'mac-preview-payload-v' "$package_workflow"
/usr/bin/grep -Fq 'mac-preview-stage-v' "$package_workflow"
/usr/bin/grep -Fq 'test "$TRIGGER_REF_NAME" = release-main' "$package_workflow"
/usr/bin/grep -Fq 'origin/release-main' "$package_workflow"
/usr/bin/grep -Fq 'branches: [main, release-main]' "$ci_workflow"
/usr/bin/grep -Fq 'swift test --filter BuildSigningTests' "$ci_workflow"
if /usr/bin/grep -Eq 'release_mode|expected_pipeline_digest|qualification|candidateBranch|requestId|gh release|git tag|contents:[[:space:]]*write' "$package_workflow"; then
  print -u2 "protected staging workflow still contains publication or legacy qualification state"
  exit 1
fi

/usr/bin/grep -Fq 'source_run_id:' "$publication_workflow"
/usr/bin/grep -Fq 'ui_attestation_b64:' "$publication_workflow"
/usr/bin/grep -Fq 'publish-preview-release.sh' "$publication_workflow"
/usr/bin/grep -Fq 'ref: ${{ github.sha }}' "$publication_workflow"
/usr/bin/grep -Fq 'TRIGGER_REPOSITORY' "$publication_workflow"
/usr/bin/grep -Fq "github.ref_name == 'release-main'" "$publication_workflow"
if /usr/bin/grep -Eq 'environment:[[:space:]]*mac-release|secrets[.]|RELEASE_AGE_IDENTITY|MATCH|NOTARY|draft:' "$publication_workflow"; then
  print -u2 "Preview publication workflow contains protected Apple inputs"
  exit 1
fi

/usr/bin/grep -Fq 'tag:' "$stable_workflow"
/usr/bin/grep -Fq 'promote-preview-release.sh' "$stable_workflow"
/usr/bin/grep -Fq 'group: mac-stable-promotion' "$stable_workflow"
/usr/bin/grep -Fq 'ref: ${{ github.sha }}' "$stable_workflow"
/usr/bin/grep -Fq 'TRIGGER_REPOSITORY' "$stable_workflow"
/usr/bin/grep -Fq "github.ref_name == 'release-main'" "$stable_workflow"
if /usr/bin/grep -Eq 'package-macos|codesign|notary|xcrun stapler|upload-artifact|workflow_run' "$stable_workflow"; then
  print -u2 "Stable promotion workflow still rebuilds or uploads assets"
  exit 1
fi

REPOSITORY_ROOT="$ROOT" "$ROOT/scripts/verify-release-workflow-gh-token.sh" >/dev/null

publication_source="$ROOT/scripts/publish-preview-release.sh"
recovery_source="$ROOT/scripts/recover-preview-stage.sh"
attestation_source="$ROOT/scripts/verify-preview-ui-attestation.sh"
ui_prep_source="$ROOT/scripts/prepare-staged-preview-ui-test.sh"
/usr/bin/grep -Fq -- '--ref release-main' "$ROOT/scripts/stage-macos-preview.sh"
/usr/bin/grep -Fq -- '--branch release-main' "$ROOT/scripts/stage-macos-preview.sh"
/usr/bin/grep -Fq -- '--ref release-main' "$ROOT/scripts/publish-staged-preview.sh"
/usr/bin/grep -Fq 'origin/release-main' "$ROOT/scripts/promote-preview-release.sh"
/usr/bin/grep -Fq '.head_branch == "release-main"' "$recovery_source"
/usr/bin/grep -Fq '.head_branch == "release-main"' "$ui_prep_source"
/usr/bin/grep -Fq 'verify-preview-ui-attestation.sh' "$publication_source"
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
  "Remote-Mic-$version-Intel-Uninstaller.pkg" \
  "Remote-Mic-$version-Intel.dmg" \
  "Remote-Mic-$version-Intel.zip" \
  "Remote-Mic-$version-Uninstaller.pkg" \
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
