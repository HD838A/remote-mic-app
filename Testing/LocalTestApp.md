# 本地测试 App 构建

用于本地调试和截图，**不是分发产物**。产物无公证、ad-hoc 或开发证书签名。

## 一条命令

前置：私有组件有一个干净的可读 tag 检出（例如 `2.6.2`），路径记为 `$PRIVATE`。

```bash
git -C "$PRIVATE" status --porcelain --untracked-files=all   # 必须为空
git -C "$PRIVATE" rev-parse HEAD                              # 必须等于该 tag 的 commit

SAYALL_ENABLE_BUTTON_PROFILES=1 \
SAYALL_TEST_BUTTON_PROFILES_FREE=1 \
SAYALL_BUTTON_PROFILES_PACKAGE_PATH="$PRIVATE/packages/macos-button-profiles" \
SAYALL_COMBINATION_ACTIONS_PATH="$PRIVATE/packages/macos-combination-actions" \
CONFIGURATION=debug \
./scripts/build-app.sh
```

产物：`dist/SayAll.app`。

## 三道容易踩的门

1. **源码输入必须是 tag 的干净检出。** 只要传了任何 `SAYALL_*_PACKAGE_PATH`，脚本会用
   `git rev-parse --show-toplevel` 反查仓库根，再要求 `HEAD` 等于 manifest tag 的 commit
   且工作区干净（含未跟踪文件）。在功能分支上直接指向工作区会被拒：
   `Private packaging requires a clean checkout of the manifest tag`。
   做法：另开一个 `git worktree add --detach <path> <tag>` 的检出传给脚本。

2. **不要用 `SAYALL_PRIVATE_PLATFORM_PACKAGE_PATH` 或 `SAYALL_ENABLE_PRIVATE_SWIFTPM`。**
   这两个会命中「App packaging requires tag-pinned prepared artifacts」，因为整仓模式只提供给
   发布链路。只传子包路径即可走本地源码分支。

3. **`SAYALL_TEST_BUTTON_PROFILES_FREE=1` 与私有 artifact 互斥**
   （`free button profile test access excludes private membership artifacts`）。
   所以本地放行方案功能时，必须走源码子包、不能同时给 `SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH`。

## 需要签名身份时

`CODE_SIGN_IDENTITY` 不能是 `-`（Siri Remote 打包要求真实身份）。本机可用：

```
CODE_SIGN_IDENTITY='Developer ID Application: lei qian (L3QHLDRPAY)'
```

只传子包路径、不启用 Siri Remote 私有包时，通常不需要这一项。

## 截图

设置页可直接由 App 渲染成 PNG：

```bash
SAYALL_MACRO_STORAGE_ROOT=/tmp/shot-root \
REMOTE_MIC_SETTINGS_SCREENSHOT_DIR=/tmp/shot-out \
REMOTE_MIC_SETTINGS_SCREENSHOT_SIZE=1020x772 \
REMOTE_MIC_SETTINGS_SCREENSHOT_APPEARANCE=light \
REMOTE_MIC_SETTINGS_SCREENSHOT_LANGUAGE=zh-Hans \
dist/SayAll.app/Contents/MacOS/RemoteMic
```

支持的还有 `REMOTE_MIC_SETTINGS_SCREENSHOT_SECTION`（只渲染一页）、`..._OPEN_ACTION_EDITOR`、
`..._GESTURE_TIMING` 等，见 `Sources/RemoteMic/SettingsScreenshotRenderer.swift`。

⚠️ 已知限制：渲染进程里方案数据加载不完整，即使 `SAYALL_MACRO_STORAGE_ROOT` 指向一份合法方案文件，
按键页与键位方案页仍只显示默认方案。要截方案相关页面，目前需要在正常 GUI 里手动操作后截图。

## 方案数据

不要手写 `button-profiles.json`。用组件自己的写入路径生成（`saveShortcut` /
`createButtonProfile` / `bind`），或从真实快照复制结构。手写数据会被静默判定无效并重置成默认方案。
