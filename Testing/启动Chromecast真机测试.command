#!/bin/zsh
# 监听 Chromecast 真机测试期间的运行日志，并在桌面留一份本次会话记录。
# 只读日志，不启动 App、不改配置、不要求 root。
set -euo pipefail

LOG="$HOME/Library/Logs/RemoteMic/runtime.log"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Desktop/chromecast-$STAMP.log"

if [[ ! -f "$LOG" ]]; then
  print -u2 "找不到运行日志：$LOG（先启动待测包并让它运行一次）"
  exit 1
fi

print "=============================================="
print "Chromecast 真机测试 · 日志监听"
print "源日志：$LOG"
print "本次记录：$OUT"
print "过滤：CHROMECAST / ATVV / VOICE INTENT"
print "结束：按 ⌃C"
print "=============================================="
print ""
print "关键顺序应为："
print "  CHROMECAST LINK state=searching"
print "  CHROMECAST CONNECTION state=connecting"
print "  CHROMECAST CONNECTION state=available      <-- 没有这一行就不要往下测"
print "  CHROMECAST VOICE phase=started"
print "  CHROMECAST VOICE phase=sustain result=no_visible_change"
print "  CHROMECAST AUDIO routed ... device=MiRemoteV_2ch"
print "  CHROMECAST VOICE playback_stop phase=waiting_for_drain"
print "  CHROMECAST AUDIO playback_stop phase=completed result=drained"
print ""

/usr/bin/tail -n 0 -F "$LOG" \
  | /usr/bin/grep --line-buffered -a -E "CHROMECAST|ATVV|VOICE INTENT" \
  | /usr/bin/tee -a "$OUT"
