#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
APP="$SCRIPT_DIR/SayAll-RC003-VoiceExtension-Test.app"
if [[ ! -d "$APP" ]]; then
  print -u2 "找不到测试应用：$APP"
  exit 1
fi
/usr/bin/open -n "$APP"
