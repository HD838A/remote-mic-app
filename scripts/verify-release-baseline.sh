#!/bin/zsh
set -euo pipefail
umask 022

# 发布基线门禁：Draft / Pre-release 只能从最新 origin/main（外加允许的打包提交）构建。
#
# 2026-11-05 的 284 就是从一条旧功能分支打的：HEAD 的基点比当时的 origin/main 落后
# 11 个合并提交，发布说明里却手写了 origin/main 的 SHA，于是包和说明对不上。
# 这里把「基线」变成断言：origin/main 必须是 HEAD 的祖先，且两者之间只允许出现
# build 号递增与政策快照锁这两类打包提交。
#
# 用法：
#   scripts/verify-release-baseline.sh
#   scripts/verify-release-baseline.sh --require <合并提交>   # 断言目标改动在构建树里
#   scripts/verify-release-baseline.sh --base origin/hotfix/v2.0.0 --require <sha>
#   scripts/verify-release-baseline.sh --head <已构建的提交>   # 校验历史提交，而非当前 HEAD
#   scripts/verify-release-baseline.sh --self-test

script_dir="${0:A:h}"
ROOT="${REPOSITORY_ROOT:-${script_dir:h}}"

usage() {
  print -u2 "usage: ${0:t} [--base REF] [--head SHA] [--require SHA]... [--allow-dirty] [--no-fetch] [--self-test]"
}

base_ref="origin/main"
head_ref="HEAD"
require_shas=()
allow_dirty=0
should_fetch=1

while (( $# > 0 )); do
  case "$1" in
    --base)
      (( $# >= 2 )) || { usage; exit 2; }
      base_ref="$2"
      shift 2
      ;;
    --head)
      (( $# >= 2 )) || { usage; exit 2; }
      head_ref="$2"
      shift 2
      ;;
    --require)
      (( $# >= 2 )) || { usage; exit 2; }
      require_shas+=("$2")
      shift 2
      ;;
    --allow-dirty)
      allow_dirty=1
      shift
      ;;
    --no-fetch)
      should_fetch=0
      shift
      ;;
    --self-test)
      exec "$script_dir/test-verify-release-baseline.sh"
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
  print -u2 "release baseline check failed: $1"
  exit 1
}

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  fail "not a git work tree: $ROOT"

# 只对 origin/* 拉取；本地 ref（例如已经核对过的 SHA）按原样解析。
if (( should_fetch == 1 )) && [[ "$base_ref" == origin/* ]]; then
  git -C "$ROOT" fetch --quiet --tags origin "${base_ref#origin/}" 2>/dev/null || \
    fail "could not fetch $base_ref; rerun with --no-fetch only if that ref is already current"
fi

base_sha="$(git -C "$ROOT" rev-parse --verify "$base_ref^{commit}" 2>/dev/null)" || \
  fail "cannot resolve base ref: $base_ref"
head_sha="$(git -C "$ROOT" rev-parse --verify "$head_ref^{commit}" 2>/dev/null)" || \
  fail "cannot resolve head commit: $head_ref"
current_head_sha="$(git -C "$ROOT" rev-parse HEAD)"

# 方向很重要：必须是「基线是 HEAD 的祖先」。反过来（HEAD 落后于基线）会被三点 diff
# 掩盖成只有几个打包提交，284 就是这种情况。
git -C "$ROOT" merge-base --is-ancestor "$base_sha" "$head_sha" || \
  fail "HEAD $head_sha is not built on $base_ref $base_sha; the packaging branch is stale or diverged"

# 打包分支只允许这两类提交：build 号递增、政策快照锁。
unexpected_paths=()
while IFS= read -r changed_path; do
  [[ -n "$changed_path" ]] || continue
  case "$changed_path" in
    Resources/Info.plist|packaging/*) ;;
    *) unexpected_paths+=("$changed_path") ;;
  esac
done < <(git -C "$ROOT" diff --name-only "$base_sha...$head_sha")
(( ${#unexpected_paths[@]} == 0 )) || \
  fail "packaging branch may only change Resources/Info.plist or packaging/**: ${(j:, :)unexpected_paths}"

dirty=false
if [[ "$head_sha" == "$current_head_sha" && -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  (( allow_dirty == 1 )) || \
    fail "worktree is not clean; commit the packaging changes so the built tree is auditable"
  dirty=true
fi

for required in "${require_shas[@]}"; do
  required_sha="$(git -C "$ROOT" rev-parse --verify "$required^{commit}" 2>/dev/null)" || \
    fail "cannot resolve required commit: $required"
  git -C "$ROOT" merge-base --is-ancestor "$required_sha" "$head_sha" || \
    fail "required commit $required is not part of the built tree ($head_sha)"
done

ahead_count="$(git -C "$ROOT" rev-list --count "$base_sha..$head_sha")"
if (( ahead_count == 0 )); then
  print -u2 "note: HEAD 与 $base_ref 相同，这个构建还没有 build 号递增提交"
fi

print "RELEASE_BASELINE_OK"
print "RELEASE_BASELINE_REF=$base_ref"
print "RELEASE_BASELINE_SHA=$base_sha"
print "RELEASE_HEAD_SHA=$head_sha"
print "RELEASE_AHEAD_COUNT=$ahead_count"
print "RELEASE_DIRTY=$dirty"
