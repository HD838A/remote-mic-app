# 本地测试 App 构建

用于本地调试和截图，**不是分发产物**。产物无公证，按模式使用 ad-hoc 或 Developer ID 签名。

## 统一入口

本地测试包统一使用 `scripts/package-local-test-app.sh`。不要直接调用 `build-app.sh` 作为日常入口；统一入口负责 native 打包、Build 号递增、替换、回退目录、锁和启动。

公开开发自用（默认，无私有输入）：

```bash
SAYALL_LOCAL_DEFER_LAUNCH=1 ./scripts/package-local-test-app.sh
```

完整集成测试（要求私有源码、固定 Tag 对应的预构件和本机 Developer ID）：

```bash
SAYALL_PRIVATE_PLATFORM_MODE=required \
SAYALL_PRIVATE_SOURCE_ROOT=/path/to/sayall-private-platform \
SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH=/path/to/prepared-private-artifact-package \
CODE_SIGN_IDENTITY='Developer ID Application: … (L3QHLDRPAY)' \
./scripts/package-local-test-app.sh
```

产物与行为：

- 优先安装到 `~/Applications/SayAll.app`；替换失败才使用 `~/Downloads/SayAll-test/SayAll.app`。
- 每次构建从 `/Applications/SayAll.app`、`~/Applications/SayAll.app`、目标/回退路径和 `~/.sayall-local-build` 的最大值递增 `CFBundleVersion`，并写入 `SayAllSourceDirty`。
- 同一时间只允许一个本地构建；已持有锁时直接失败。
- 公开模式记录 `SayAllBuildChannel=public`；完整集成模式记录 `local` 并强制 Developer ID Team `L3QHLDRPAY`。
- 默认构建完成后启动 App；设置 `SAYALL_LOCAL_DEFER_LAUNCH=1` 可只安装不启动。

公开模式不能同时提供任何私有路径或 `SAYALL_ENABLE_PRIVATE_SWIFTPM=1`。完整集成模式缺少私有源码、预构件或 Developer ID 时直接失败。

## 直接构建到 dist（高级）

仅在需要 `dist/SayAll.app` 做截图或结构检查时使用 `build-app.sh`。前置：私有组件有当前 `config/release-dependencies.json` 固定 Tag 的干净可读检出，路径记为 `$PRIVATE`；不要使用历史示例 Tag。

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

## 截图

设置页可直接由 App 渲染成 PNG：

截图目录必须使用仓库外的持久目录，不要使用 `/tmp`、`/private/tmp` 或 `$TMPDIR`。设置页生产最小窗口为 `1067 × 760`；`1020 × 772` 只适用于 Onboarding 或历史截图 harness。

```bash
SAYALL_MACRO_STORAGE_ROOT="$HOME/Pictures/SayAllEvidence/shot-root" \
REMOTE_MIC_SETTINGS_SCREENSHOT_DIR="$HOME/Pictures/SayAllEvidence/shot-out" \
REMOTE_MIC_SETTINGS_SCREENSHOT_SIZE=1067x760 \
REMOTE_MIC_SETTINGS_SCREENSHOT_APPEARANCE=light \
REMOTE_MIC_SETTINGS_SCREENSHOT_LANGUAGE=zh-Hans \
dist/SayAll.app/Contents/MacOS/RemoteMic
```

支持的还有 `REMOTE_MIC_SETTINGS_SCREENSHOT_SECTION`（只渲染一页）、`..._OPEN_ACTION_EDITOR`、
`..._GESTURE_TIMING`、`..._VOICE_OUTPUT=missing|compatible`（隔离兼容音频设备状态）等，见
`Sources/RemoteMic/SettingsScreenshotRenderer.swift`。

⚠️ 已知限制：渲染进程里方案数据加载不完整，即使 `SAYALL_MACRO_STORAGE_ROOT` 指向一份合法方案文件，
按键页与键位方案页仍只显示默认方案。要截方案相关页面，目前需要在正常 GUI 里手动操作后截图。

## 方案数据

不要手写 `button-profiles.json`。用组件自己的写入路径生成（`saveShortcut` /
`createButtonProfile` / `bind`），或从真实快照复制结构。手写数据会被静默判定无效并重置成默认方案。
