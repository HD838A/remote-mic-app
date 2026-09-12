# 社区版与私有版 Siri Remote 构建边界

适用版本：`codex/community-siri-optional` 及合入后的 `main`。

## 目标

`remote-mic-app` 在没有私有仓库访问权限时必须可以直接构建。社区构建默认不启用 Siri Remote，不显示 Siri Remote 专属设置，不启动 Apple Remote 适配器，也不要求 Siri Remote resource bundle、helper 或 Opus 动态库。

只有显式提供 `SAYALL_SIRI_REMOTE_PACKAGE_PATH`（或同时设置 `SAYALL_ENABLE_SIRI_REMOTE=1`）时，才定义 `SAYALL_SIRI_REMOTE_ENABLED` 并编译专属 UI/功能。

## 社区构建验收

在公开仓库根目录执行：

```bash
env -u SAYALL_SIRI_REMOTE_PACKAGE_PATH \
  -u SAYALL_ENABLE_SIRI_REMOTE \
  swift test --disable-sandbox

env -u SAYALL_SIRI_REMOTE_PACKAGE_PATH \
  -u SAYALL_ENABLE_SIRI_REMOTE \
  CONFIGURATION=release SIGNING_IDENTITY=- \
  ./scripts/build-app.sh

env -u SAYALL_SIRI_REMOTE_PACKAGE_PATH \
  -u SAYALL_ENABLE_SIRI_REMOTE \
  ./scripts/verify-app.sh dist/SayAll.app
```

预期结果：测试和构建成功；`dist/SayAll.app/Contents/Info.plist` 中 `SayAllSiriRemoteIncluded` 为 `false`；App bundle 不包含 `SayAllSiriRemote_SayAllSiriRemote.bundle`、`SayAllAppleRemoteAudioCapture` 或 `SayAllAppleRemoteHCIService`。

失败判定：缺少私有包导致 manifest 错误、构建脚本要求 Siri Remote helper/Opus、启动时出现 Siri Remote 缺失错误，或设置页面出现 Siri Remote 专属入口。

## 私有构建验收

在具备私有包的环境中执行：

```bash
export SAYALL_SIRI_REMOTE_PACKAGE_PATH=/absolute/path/to/sayall-private-platform/packages/audio-input-kit/siri-remote
export SAYALL_SIRI_REMOTE_UI_ONLY=1
swift test --disable-sandbox

CONFIGURATION=release SIGNING_IDENTITY=- ./scripts/build-app.sh
./scripts/verify-app.sh dist/SayAll.app
```

使用完整 Siri Remote 发布包时还需提供对应的 helper 构建依赖和 `SAYALL_OPUS_LIBRARY`，并分别验证实体遥控器、HCI helper、触摸和语音链路。UI-only 构建只能证明私有设置页接入，不能替代真机验收。

`scripts/build-app.sh` 会自动设置 `SAYALL_SIRI_REMOTE_UI_ONLY=1`。这是有意的边界：宿主仓库自身提供受 `SAYALL_SIRI_REMOTE_ENABLED` 控制的 Siri Remote 运行时目标，私有 Package 在宿主构建中只提供私有 UI 和资源，避免两个包重复声明 `AppleRemote*` SwiftPM target。直接运行 SwiftPM 测试时仍需显式保留该变量。

## 边界

- 社区测试会跳过依赖私有 Siri Remote 能力的测试套件，但仍保留公共 RC001/RC003 回归。
- 私有构建的成功不代表社区构建包含 Siri Remote；两种构建必须分别验证。
- 本手册不替代 [`AppleRemoteHardwareInterface.md`](AppleRemoteHardwareInterface.md) 中的真实 A2854 实机矩阵。

## 日志收集

构建或测试失败时保留完整终端输出，并记录是否设置了 `SAYALL_SIRI_REMOTE_PACKAGE_PATH`、`SAYALL_ENABLE_SIRI_REMOTE` 和 `SAYALL_SIRI_REMOTE_UI_ONLY`；不得记录私有仓库凭据。运行时若社区版出现 Siri Remote 入口、状态或错误，按 `LOGGING.md` 收集无线麦日志，并同时保存 `plutil -extract SayAllSiriRemoteIncluded raw -o - dist/SayAll.app/Contents/Info.plist` 的结果。

自动化只能证明编译、测试、资源显隐和包结构边界；真实 A2854、系统权限、HCI helper、触摸和语音输入仍必须按实机手册验收。
