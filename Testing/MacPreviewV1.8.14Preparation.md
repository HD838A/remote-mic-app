# Mac v1.8.14 预览候选准备

## 状态与范围

- 目标版本：`1.8.14 (106)`。
- 候选分支：`release/pre-v1.8.14`。
- Apple Silicon 最低版本：macOS 14；Intel 独立包最低版本：macOS 13。
- 本轮只整理候选代码并 Push，不构建、签名、公证、生成 DMG/PKG 或创建 Release。

候选包含普通用户可感知的改动：

1. 首次设置卡点显示明确原因、单一主要修复动作、完成页定向回跳和可复制的脱敏诊断。
2. 普通 DMG 只保留一个安装入口，并在现有 MiRemoteV 2ch 健康兼容时原样保留。
3. 支持 DJI Mic Mini 等标准 CoreAudio 麦克风持续桥接到所选兼容麦克风；功能默认关闭，并与遥控器、手机和 Fn 语音互斥恢复。

## Release Notes 草案

### 中文

- 首次设置卡住时会直接说明当前原因，并只突出一个修复操作；完成页发现权限、遥控器或语音输出变化时，会返回对应设置继续修复。
- 新增可复制的脱敏设置诊断，帮助确认权限、连接、音频和语音检查进度；不会包含设备标识、用户文字或音频内容。
- Mac 安装镜像只保留一个普通安装入口；安装器会保留健康兼容的现有麦克风，只在缺失或不可用时安装或更新。
- 支持将 DJI Mic Mini 等标准 Mac 麦克风持续桥接到所选兼容麦克风，并在遥控器、手机或 Fn 语音开始时自动让路，结束后恢复。

### English

- First-run setup now explains the current blocker and highlights one recovery action. If permissions, the remote, or voice output changes on the final page, setup returns directly to the affected stage.
- Added a copyable redacted setup diagnostic for permission, connection, audio, and voice-check progress without device identifiers, user text, or audio content.
- The Mac disk image now has one ordinary installation entry. The installer keeps an existing healthy compatible microphone and installs or updates it only when missing or unusable.
- Added continuous bridging from standard Mac microphones such as DJI Mic Mini to the selected compatible microphone, with automatic handoff to remote, phone, and Fn voice sessions and recovery afterward.

## 自动化验证计划

- `swift test --filter OnboardingFlowTests`
- `swift test --filter 'CoreAudioInputSourceTests|VirtualAudioConnectionLifecycleTests|VoiceFnTapSessionControllerTests'`
- `swift test --filter BuildSigningTests`
- `swift test --filter LocalizationTests`
- `swift test`
- `scripts/test.sh`
- Apple Silicon 与 Intel Release 编译（只编译，不执行安装打包）
- `zsh -n` 校验全部受影响安装脚本
- 扫描安装脚本不含 `lipo`、`vtool`、`xcrun`、`xcode-select`、`xcodebuild`、`swift`、`swiftc` 或 `clang`
- `git diff --check` 与敏感信息扫描

## 自动化与真实环境边界

- 自动化不能替代系统权限历史、真实 RC003、豆包、Typeless、其他语音工具、DJI Mic Mini 长时间运行或真实转写。
- 本轮未生成安装产物，因此 DMG 单入口、健康驱动原样保留、异常驱动替换、管理员取消、安装后启动、签名、公证、Gatekeeper 和 Sparkle 跨版本更新尚未执行真实产物验收。
- 完整现场用例分别见 [FirstUseSuccess.md](./FirstUseSuccess.md)、[FirstRunOnboarding.md](./FirstRunOnboarding.md) 和 [CoreAudioMicrophoneBridge.md](./CoreAudioMicrophoneBridge.md)。
