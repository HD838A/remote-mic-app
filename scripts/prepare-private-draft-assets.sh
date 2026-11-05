#!/bin/zsh
set -euo pipefail
umask 077

# Stage the private Draft release assets under their final published names.
#
# `gh release upload` keeps the local file name and rewrites whitespace in it,
# so uploading a raw build artifact such as "Install SayAll.pkg" publishes
# "Install.SayAll.pkg": no build number, no architecture marker, and a name the
# publisher can no longer look up by path. Every macOS distribution asset is
# therefore staged as SayAll-<version>-<build>-<Variant>[-Installer].<ext>, and
# every variant must cover the same asset kinds so a missing architecture
# counterpart fails before anything is staged or uploaded.

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"

fail() {
  print -u2 "prepare-private-draft-assets: $1"
  exit 1
}

usage() {
  print -u2 "usage: $0 <staging-directory> <Variant=artifact-directory> [<Variant=artifact-directory> ...]"
  exit 2
}

staging=""
variants=()
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage ;;
    *)
      if [[ -z "$staging" ]]; then
        staging="$1"
      elif [[ "$1" == *=* ]]; then
        variants+=("$1")
      else
        usage
      fi
      shift
      ;;
  esac
done
[[ -n "$staging" && ${#variants[@]} -ge 1 ]] || usage

for command_name in git jq plutil shasum stat ditto; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "prepare-private-draft-assets: missing required command: $command_name"
    exit 1
  }
done

version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || \
  fail "release version/build is invalid: $version ($build)"
source_commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || print unknown)"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || source_commit="unknown"

[[ ! -e "$staging" ]] || fail "staging directory already exists: $staging"

plan_rows=()
kind_sets=()
for entry in "${variants[@]}"; do
  variant="${entry%%=*}"
  artifact_directory="${entry#*=}"
  [[ "$variant" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] || fail "variant name is invalid: $variant"
  [[ -d "$artifact_directory" ]] || fail "artifact directory is missing: $artifact_directory"
  kinds=""
  for artifact in "$artifact_directory"/*.dmg(N) "$artifact_directory"/*SayAll*.pkg(N); do
    [[ -f "$artifact" && ! -L "$artifact" ]] || continue
    base="${artifact:t}"
    case "$base" in
      *.sha256) continue ;;
      Uninstall*) continue ;;
    esac
    case "${artifact:e:l}" in
      dmg) kind=".dmg" ;;
      pkg) kind="-Installer.pkg" ;;
      *) continue ;;
    esac
    published_name="SayAll-$version-$build-$variant$kind"
    [[ "$published_name" != *[[:space:]]* ]] || fail "published asset name contains whitespace: $published_name"
    [[ "$published_name" == *"$version"* && "$published_name" == *"$build"* ]] || \
      fail "published asset name must carry the version and build: $published_name"
    plan_rows+=("$artifact"$'\t'"$published_name"$'\t'"$kind")
    kinds="${kinds}${kind} "
  done
  [[ -n "$kinds" ]] || fail "no macOS distribution asset was found for variant $variant in $artifact_directory"
  kinds="$(print -r -- "$kinds" | /usr/bin/tr ' ' '\n' | LC_ALL=C /usr/bin/sort -u | /usr/bin/tr '\n' ' ')"
  kind_sets+=("$variant=$kinds")
done

reference_variants=""
for line in "${kind_sets[@]}"; do
  kinds="${line#*=}"
  if [[ -z "$reference_variants" ]]; then
    reference_variants="$kinds"
    continue
  fi
  [[ "$kinds" == "$reference_variants" ]] || \
    fail "every variant must cover the same asset kinds: ${kind_sets[*]}"
done

/bin/mkdir -p "$staging"
asset_rows=""
typeset -A published_sources
for row in "${plan_rows[@]}"; do
  artifact="${row%%$'\t'*}"
  remainder="${row#*$'\t'}"
  published_name="${remainder%%$'\t'*}"
  if [[ -n "${published_sources[$published_name]-}" ]]; then
    fail "duplicate published asset name: $published_name from ${published_sources[$published_name]} and $artifact"
  fi
  published_sources[$published_name]="$artifact"
  /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$artifact" "$staging/$published_name"
  digest="$(/usr/bin/shasum -a 256 "$staging/$published_name" | /usr/bin/awk '{print $1}')"
  size="$(/usr/bin/stat -f '%z' "$staging/$published_name")"
  asset_rows="${asset_rows}${asset_rows:+,}$(printf '{"name":"%s","sha256":"%s","size":%s}' "$published_name" "$digest" "$size")"
done

jq -n --arg version "$version" --arg build "$build" --arg sourceCommit "$source_commit" \
  --argjson assets "[$asset_rows]" \
  '{schemaVersion: 1, version: $version, build: $build, sourceCommit: $sourceCommit, assets: $assets}' \
  > "$staging/staged-assets.json"

print -r -- "STAGED_PRIVATE_DRAFT_ASSETS=$staging"
for row in ${(f)"$(jq -r '.assets[].name' "$staging/staged-assets.json")"}; do
  print -r -- "$staging/$row"
done
