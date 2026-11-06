#!/bin/zsh
set -euo pipefail
umask 022

# 构建来源读回：确认分发资产确实由指定提交构建。
#
# build-app.sh 会把实际 HEAD 写进 App 的 Info.plist（SayAllSourceCommit）。
# 发布前从这里读回来比对，能挡住两类事故：上传了上一次留在 dist/ 的旧包，
# 以及在另一个目录构建后回来发布（284 之后补的第二道闸）。
#
# 用法：
#   scripts/verify-release-asset-source.sh --asset dist/SayAll.app --expected-commit <sha>
#   scripts/verify-release-asset-source.sh --asset dist/SayAll-2.0.0-285.dmg --expected-commit <sha>
#   scripts/verify-release-asset-source.sh --asset dist/intel/SayAll-2.0.0-285-Intel.pkg --expected-commit <sha>

script_name="${0:t}"

usage() {
  print -u2 "usage: $script_name --asset PATH --expected-commit SHA"
}

asset=""
expected_commit=""

while (( $# > 0 )); do
  case "$1" in
    --asset)
      (( $# >= 2 )) || { usage; exit 2; }
      asset="$2"
      shift 2
      ;;
    --expected-commit)
      (( $# >= 2 )) || { usage; exit 2; }
      expected_commit="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 "unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

fail() {
  print -u2 "release asset source check failed: $1"
  exit 1
}

[[ -n "$asset" && -e "$asset" ]] || { print -u2 -- "--asset must exist: $asset"; exit 2; }
print -r -- "$expected_commit" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' || {
  print -u2 -- "--expected-commit must be a full 40-character lowercase SHA"
  exit 2
}
for command_name in plutil hdiutil pkgutil ditto find; do
  command -v "$command_name" >/dev/null 2>&1 || {
    print -u2 "required command is unavailable: $command_name"
    exit 1
  }
done

temporary_dirs=()
mounted_volumes=()

cleanup() {
  local mount_point temporary_dir
  for mount_point in "${mounted_volumes[@]}"; do
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  done
  for temporary_dir in "${temporary_dirs[@]}"; do
    [[ -n "$temporary_dir" && "$temporary_dir" == "${TMPDIR:-/private/tmp}"* ]] || continue
    /bin/rm -rf "$temporary_dir"
  done
}
trap cleanup EXIT INT TERM

verify_app() {
  local app="$1"
  local bundle_commit
  [[ -f "$app/Contents/Info.plist" ]] || fail "${app:t} has no Info.plist"
  bundle_commit="$(/usr/bin/plutil -extract SayAllSourceCommit raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ -n "$bundle_commit" ]] || \
    fail "${app:t} has no SayAllSourceCommit; rebuild it with scripts/build-app.sh (packages built before this field existed cannot be published)"
  [[ "$bundle_commit" == "$expected_commit" ]] || \
    fail "${app:t} reports source commit $bundle_commit, expected $expected_commit"
  print "ASSET_SOURCE_OK app=${app:t} commit=$bundle_commit"
}

verify_tree() {
  local root="$1"
  local depth="$2"
  local found_app=0
  local nested
  local app

  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    found_app=1
    verify_app "$app"
  done < <(/usr/bin/find "$root" -type d -name '*.app' -prune -print)
  if (( found_app == 1 )); then
    return 0
  fi

  (( depth > 0 )) || fail "no App bundle found under ${root:t}"
  while IFS= read -r nested; do
    [[ -n "$nested" ]] || continue
    verify_path "$nested" $(( depth - 1 ))
    found_app=1
  done < <(/usr/bin/find "$root" -type f \( -name '*.dmg' -o -name '*.pkg' \) -print)
  (( found_app == 1 )) || fail "no App bundle, disk image, or installer found under ${root:t}"
}

# 注意：参数不能叫 `path`——zsh 里 `path` 与 PATH 绑定，赋值会把 PATH 清空。
verify_path() {
  local candidate="$1"
  local depth="$2"
  local temporary_dir attach_output mount_point

  case "${candidate:e:l}" in
    app)
      verify_app "$candidate"
      ;;
    dmg)
      attach_output="$(hdiutil attach -readonly -nobrowse -noautoopen "$candidate")" || \
        fail "could not mount ${candidate:t}"
      mount_point="$(print -r -- "$attach_output" | /usr/bin/awk -F '\t' '$3 ~ /^\/Volumes\// { print $3; exit }')"
      [[ -n "$mount_point" && -d "$mount_point" ]] || fail "mounted volume not found for ${candidate:t}"
      mounted_volumes+=("$mount_point")
      verify_tree "$mount_point" "$depth"
      hdiutil detach "$mount_point" >/dev/null 2>&1 || true
      ;;
    pkg)
      temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/sayall-asset-source.XXXXXX")"
      temporary_dirs+=("$temporary_dir")
      pkgutil --expand-full "$candidate" "$temporary_dir/expanded" >/dev/null 2>&1 || \
        fail "could not expand ${candidate:t}"
      verify_tree "$temporary_dir/expanded" "$depth"
      ;;
    zip)
      temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/sayall-asset-source.XXXXXX")"
      temporary_dirs+=("$temporary_dir")
      ditto -x -k "$candidate" "$temporary_dir/expanded" >/dev/null 2>&1 || \
        fail "could not extract ${candidate:t}"
      verify_tree "$temporary_dir/expanded" "$depth"
      ;;
    *)
      fail "unsupported asset type: ${candidate:t}"
      ;;
  esac
}

verify_path "$asset" 1
print "RELEASE_ASSET_SOURCE_OK asset=${asset:t} commit=$expected_commit"
