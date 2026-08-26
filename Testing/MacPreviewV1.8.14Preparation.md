# Mac v1.8.14 预览候选准备

> 历史记录：本文件描述旧版候选准备，不是当前发布入口。当前流程见 RELEASING.md。

## 状态与范围

- 目标版本：`1.8.14 (106)`。
- 历史候选分支：`release/pre-v1.8.14`（仅作审计记录，当前流程不再创建）。
- Apple Silicon 最低版本：macOS 14；Intel 独立包最低版本：macOS 13。
- 本文件记录 v1.8.14 候选范围；实际构建、签名、公证和发布由发布管理会话单独授权并记录。

候选包含普通用户可感知的改动：

1. “基础按键”新增 `Command-Delete` 固定组合动作，只触发一次，不因长按遥控器而连续执行。
2. 首次设置卡点显示明确原因、单一主要修复动作、完成页定向回跳和可复制的脱敏诊断。
3. 普通 DMG 只保留一个安装入口，并在现有 MiRemoteV 2ch 健康兼容时原样保留。

## Release Notes 草案

### 中文

- “基础按键”新增 Command-Delete，可将删除到当前行行首的常用编辑操作直接映射到遥控器按键。
- 首次设置卡住时会直接说明当前原因，并只突出一个修复操作；完成页发现权限、遥控器或语音输出变化时，会返回对应设置继续修复。
- 新增可复制的脱敏设置诊断，帮助确认权限、连接、音频和语音检查进度；不会包含设备标识、用户文字或音频内容。
- Mac 安装镜像只保留一个普通安装入口；安装器会保留健康兼容的现有麦克风，只在缺失或不可用时安装或更新。

### English

- Added Command-Delete to Basic Keys, so deleting back to the start of the current line can be mapped directly to a remote button.
- First-run setup now explains the current blocker and highlights one recovery action. If permissions, the remote, or voice output changes on the final page, setup returns directly to the affected stage.
- Added a copyable redacted setup diagnostic for permission, connection, audio, and voice-check progress without device identifiers, user text, or audio content.
- The Mac disk image now has one ordinary installation entry. The installer keeps an existing healthy compatible microphone and installs or updates it only when missing or unusable.

## 自动化验证计划

- `swift test --filter 'RemoteButtonsTests|LocalizationTests'`
- `swift test --filter OnboardingFlowTests`
- `swift test --filter BuildSigningTests`
- `swift test`
- `scripts/test.sh`
- Apple Silicon 与 Intel Release 编译（只编译，不执行安装打包）
- `zsh -n` 校验全部受影响安装脚本
- 扫描安装脚本不含 `lipo`、`vtool`、`xcrun`、`xcode-select`、`xcodebuild`、`swift`、`swiftc` 或 `clang`
- `git diff --check` 与敏感信息扫描

## 自动化与真实环境边界

- 自动化只能确认 `Command-Delete` 的分类、键码、Command 修饰键、禁止重复和双语资源；真实遥控器与目标 App 行为仍需人工验收。
- 自动化不能替代系统权限历史、真实 RC003、豆包、Typeless、其他语音工具或真实转写。
- 本轮未生成安装产物，因此 DMG 单入口、健康驱动原样保留、异常驱动替换、管理员取消、安装后启动、签名、公证、Gatekeeper 和 Sparkle 跨版本更新尚未执行真实产物验收。
- 完整现场用例分别见 [FirstUseSuccess.md](./FirstUseSuccess.md)、[FirstRunOnboarding.md](./FirstRunOnboarding.md) 和 [`feature/common-mac-shortcuts/testing.md`](../feature/common-mac-shortcuts/testing.md)。
