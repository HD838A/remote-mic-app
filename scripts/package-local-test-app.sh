#!/bin/zsh
# 打本地测试包：名字固定 SayAll.app，优先替换 ~/Applications/SayAll.app，
# 失败落到 ~/Downloads/SayAll-test/。每次构建号自动 +1。
#
# 用法：
#   SAYALL_PRIVATE_SOURCE_ROOT=/path/to/sayall-private-platform \
#     scripts/package-local-test-app.sh
#
# 环境变量：
#   SAYALL_PRIVATE_SOURCE_ROOT  私有仓工作区根目录（必填，脚本会从这里取 4 个私有包）
#   SAYALL_LOCAL_APP_TARGET     替换目标，默认 ~/Applications/SayAll.app
#   SAYALL_LOCAL_APP_FALLBACK   兜底目录，默认 ~/Downloads/SayAll-test
#
# 约定（见 AGENTS.md「本地测试包」）：
#   - 包名固定 SayAll.app，构建号每次 +1，仓库 Resources/Info.plist 模板值不动
#   - 这是测试产物，不是分发包；不得冒用 Tag
set -euo pipefail

HOST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIVATE_ROOT="${SAYALL_PRIVATE_SOURCE_ROOT:-}"
TARGET="${SAYALL_LOCAL_APP_TARGET:-$HOME/Applications/SayAll.app}"
FALLBACK_DIR="${SAYALL_LOCAL_APP_FALLBACK:-$HOME/Downloads/SayAll-test}"
STATE="$HOME/.sayall-local-build"

if [[ -z "$PRIVATE_ROOT" || ! -d "$PRIVATE_ROOT/packages/macos-button-profiles" ]]; then
  echo "SAYALL_PRIVATE_SOURCE_ROOT 必须指向私有仓根目录（含 packages/macos-button-profiles）" >&2
  exit 2
fi

current_build() {
  local value=0 v app
  for app in "/Applications/SayAll.app" "$TARGET" "$FALLBACK_DIR/SayAll.app"; do
    [[ -d "$app" ]] || continue
    v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist" 2>/dev/null || echo 0)
    [[ "$v" =~ ^[0-9]+$ ]] && (( v > value )) && value=$v
  done
  if [[ -f "$STATE" ]]; then
    v=$(cat "$STATE" 2>/dev/null || echo 0)
    [[ "$v" =~ ^[0-9]+$ ]] && (( v > value )) && value=$v
  fi
  echo "$value"
}

NEXT_BUILD=$(( $(current_build) + 1 ))
P="$PRIVATE_ROOT/packages"
SOURCE_COMMIT="$(git -C "$HOST_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY="clean"
[[ -n "$(git -C "$HOST_ROOT" status --porcelain 2>/dev/null)" ]] && DIRTY="dirty"

echo "==> build $NEXT_BUILD from $SOURCE_COMMIT ($DIRTY)"
cd "$HOST_ROOT"
SAYALL_TEST_BUTTON_PROFILES_FREE=1 \
SAYALL_COMBINATION_ACTIONS_PATH="$P/macos-combination-actions" \
SAYALL_BUTTON_PROFILES_PACKAGE_PATH="$P/macos-button-profiles" \
SAYALL_SIRI_REMOTE_PACKAGE_PATH="$P/audio-input-kit/siri-remote" \
SAYALL_CHROMECAST_PACKAGE_PATH="$P/audio-input-kit/chromecast" \
  swift build -c release --disable-sandbox

APP=/tmp/SayAll.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RemoteMic "$APP/Contents/MacOS/"
cp -R .build/out/Products/Release/Sparkle.framework "$APP/Contents/MacOS/"
rsync -a --exclude Info.plist Resources/ "$APP/Contents/Resources/"
for bundle in .build/out/Products/Release/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

# 单实例锁与 bundle id 无关，替换前必须先退出正在运行的实例。
pkill -f "MacOS/RemoteMic" 2>/dev/null || true
sleep 1

if rm -rf "$TARGET" 2>/dev/null && cp -R "$APP" "$TARGET" 2>/dev/null; then
  FINAL="$TARGET"
else
  mkdir -p "$FALLBACK_DIR"
  rm -rf "$FALLBACK_DIR/SayAll.app"
  cp -R "$APP" "$FALLBACK_DIR/SayAll.app"
  FINAL="$FALLBACK_DIR/SayAll.app"
fi
codesign --force --deep --sign - "$FINAL" >/dev/null 2>&1
echo "$NEXT_BUILD" > "$STATE"
echo "==> $FINAL (build $NEXT_BUILD, source $SOURCE_COMMIT, $DIRTY)"
open "$FINAL"
