#!/bin/zsh
set -euo pipefail
umask 022

# 发布说明的构建来源行：由脚本按实际构建树生成，不允许手写。
#
# 284 的说明里写着“公开 main 01606521”，而包其实来自 16c1fe2b——两者不是一棵树。
# 这个脚本把 `Commit：` 行改写成「构建树 + 基线」，保留第一个 `；` 之后的内容
# （例如私有平台 tag），没有该行时追加到末尾。
#
# 用法：
#   scripts/render-private-draft-notes.sh --notes in.md --out out.md \
#     --source-commit <sha> --baseline-ref origin/main --baseline-sha <sha>

script_name="${0:t}"

usage() {
  print -u2 "usage: $script_name --notes IN.md --out OUT.md --source-commit SHA --baseline-ref REF --baseline-sha SHA"
}

notes_file=""
out_file=""
source_commit=""
baseline_ref="origin/main"
baseline_sha=""

while (( $# > 0 )); do
  case "$1" in
    --notes)
      (( $# >= 2 )) || { usage; exit 2; }
      notes_file="$2"
      shift 2
      ;;
    --out)
      (( $# >= 2 )) || { usage; exit 2; }
      out_file="$2"
      shift 2
      ;;
    --source-commit)
      (( $# >= 2 )) || { usage; exit 2; }
      source_commit="$2"
      shift 2
      ;;
    --baseline-ref)
      (( $# >= 2 )) || { usage; exit 2; }
      baseline_ref="$2"
      shift 2
      ;;
    --baseline-sha)
      (( $# >= 2 )) || { usage; exit 2; }
      baseline_sha="$2"
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
  print -u2 "render release notes failed: $1"
  exit 1
}

[[ -n "$notes_file" && -s "$notes_file" ]] || { print -u2 -- "--notes must be a non-empty file"; exit 2; }
[[ -n "$out_file" ]] || { print -u2 -- "--out is required"; exit 2; }
print -r -- "$source_commit" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' || {
  print -u2 -- "--source-commit must be a full 40-character lowercase SHA"
  exit 2
}
print -r -- "$baseline_sha" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' || {
  print -u2 -- "--baseline-sha must be a full 40-character lowercase SHA"
  exit 2
}
[[ "${notes_file:A}" != "${out_file:A}" ]] || {
  print -u2 -- "--out must differ from --notes; the original notes stay untouched"
  exit 2
}

commit_line="Commit：构建树 \`${source_commit[1,7]}\` · 基线 \`${baseline_ref}\` \`${baseline_sha[1,7]}\`"

/usr/bin/awk -v line="$commit_line" '
  BEGIN { replaced = 0 }
  /^Commit：/ {
    suffix = ""
    separator = index($0, "；")
    if (separator > 0) suffix = substr($0, separator)
    print line suffix
    replaced = 1
    next
  }
  { print }
  END { if (replaced == 0) { print ""; print line } }
' "$notes_file" > "$out_file" || fail "could not write $out_file"

# 管道或编码出错会留下 U+FFFD，发出去就是乱码说明。
if /usr/bin/grep -q "$(/usr/bin/printf '\357\277\275')" "$out_file"; then
  fail "rendered notes contain an invalid replacement character"
fi

print "RELEASE_NOTES_OK out=$out_file"
print "RELEASE_NOTES_COMMIT_LINE=$commit_line"
