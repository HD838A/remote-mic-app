# Mac v1.8.14 预览候选准备

## 状态与范围

- 目标版本：`1.8.14 (106)`。
- 候选分支：`release/pre-v1.8.14`。
- Apple Silicon 最低版本：macOS 14；Intel 独立包最低版本：macOS 13。
- 本轮只整理候选源码并 Push，不构建 App、签名、公证、生成 DMG/PKG 或创建 Release。
- 通用 CoreAudio 桥接的私有组件与 GPL 宿主组合分发边界尚未解决，因此当前分支不具备打包或对外发布资格。

候选包含普通用户可感知的改动：

1. “基础按键”新增 `Command-Delete` 固定组合动作，只触发一次，不因长按遥控器而连续执行。
2. 首次设置卡点显示明确原因、单一主要修复动作、完成页定向回跳和可复制的脱敏诊断。
3. 普通 DMG 只保留一个安装入口，并在现有 MiRemoteV 2ch 健康兼容时原样保留。
4. 支持 DJI Mic Mini 等标准 CoreAudio 麦克风持续桥接到所选兼容麦克风；功能默认关闭，并与遥控器、手机和 Fn 语音互斥恢复。

## Release Notes 草案

### 中文

- “基础按键”新增 Command-Delete，可将删除到当前行行首的常用编辑操作直接映射到遥控器按键。
- 首次设置卡住时会直接说明当前原因，并只突出一个修复操作；完成页发现权限、遥控器或语音输出变化时，会返回对应设置继续修复。
- 新增可复制的脱敏设置诊断，帮助确认权限、连接、音频和语音检查进度；不会包含设备标识、用户文字或音频内容。
- Mac 安装镜像只保留一个普通安装入口；安装器会保留健康兼容的现有麦克风，只在缺失或不可用时安装或更新。
- 支持将 DJI Mic Mini 等标准 Mac 麦克风持续桥接到所选兼容麦克风，并在遥控器、手机或 Fn 语音开始时自动让路，结束后恢复。

### English

- Added Command-Delete to Basic Keys, so deleting back to the start of the current line can be mapped directly to a remote button.
- First-run setup now explains the current blocker and highlights one recovery action. If permissions, the remote, or voice output changes on the final page, setup returns directly to the affected stage.
- Added a copyable redacted setup diagnostic for permission, connection, audio, and voice-check progress without device identifiers, user text, or audio content.
- The Mac disk image now has one ordinary installation entry. The installer keeps an existing healthy compatible microphone and installs or updates it only when missing or unusable.
- Added continuous bridging from standard Mac microphones such as DJI Mic Mini to the selected compatible microphone, with automatic handoff to remote, phone, and Fn voice sessions and recovery afterward.

## 自动化验证计划

- `swift test --filter 'RemoteButtonsTests|LocalizationTests'`
- `swift test --filter OnboardingFlowTests`
- `swift test --filter 'CoreAudioInputSourceTests|VirtualAudioConnectionLifecycleTests|VoiceFnTapSessionControllerTests'`
- `swift test --filter BuildSigningTests`
- `swift test --filter LocalizationTests`
- `swift test`
- `scripts/test.sh`
- `zsh -n` 校验全部受影响安装脚本
- 扫描安装脚本不含 `lipo`、`vtool`、`xcrun`、`xcode-select`、`xcodebuild`、`swift`、`swiftc` 或 `clang`
- `git diff --check` 与敏感信息扫描

## 自动化与真实环境边界

- 自动化只能确认 `Command-Delete` 的基础按键分类、键码、Command 修饰键、禁止重复和双语资源；真实遥控器在 TextEdit 或第三方 App 中的删除行为仍需按 [`feature/common-mac-shortcuts/testing.md`](../feature/common-mac-shortcuts/testing.md) 人工验收。
- 自动化不能替代系统权限历史、真实 RC003、豆包、Typeless、其他语音工具、DJI Mic Mini 长时间运行或真实转写。
- 本轮只验证 Swift 源码与测试目标，不执行 Apple Silicon/Intel App Bundle、Release App、驱动或安装产物构建。
- 本轮未生成安装产物，因此 DMG 单入口、健康驱动原样保留、异常驱动替换、管理员取消、安装后启动、签名、公证、Gatekeeper 和 Sparkle 跨版本更新尚未执行真实产物验收。
- 完整现场用例分别见 [FirstUseSuccess.md](./FirstUseSuccess.md)、[FirstRunOnboarding.md](./FirstRunOnboarding.md) 和 [CoreAudioMicrophoneBridge.md](./CoreAudioMicrophoneBridge.md)。

## 本轮源码验证记录（2026-08-13）

- `RemoteButtonsTests` 与 `LocalizationTests` 共 89 项、2 个 suite 通过；覆盖 `Command-Delete` 基础分类、一次触发策略、键码 `51`、Command 修饰键和中英文资源。
- 完整公开配置 `swift test`：225 项、21 个 suite 通过。
- 未注入私有音频组件的定向测试：52 项、6 个 suite 通过；直接验证组件不可用、权限受限和启动失败关闭。
- 注入 `SAYALL_AUDIO_INPUT_KIT_PATH` 的适配层定向测试：20 项、3 个 suite 通过。
- 本轮未执行真实遥控器、TextEdit 或第三方 App 的 `Command-Delete` 人工验收。
- 私有硬件模拟集成：22 项、1 个 suite 通过，覆盖 DJI 标准输入、断线新代次、旧 buffer 拒绝和 RC001/RC003 基线。
- `scripts/test.sh`：42 项通过。
- 安装与验证脚本 `zsh -n`、本地化/entitlement plist lint、开发者工具依赖扫描、AI 邀请入口扫描和 `git diff --check` 均通过。
- 未构建 `.app`、MiRemoteV 2ch、PKG 或 DMG；未签名、公证、访问 Keychain、创建 Tag/Release 或对外发布。
