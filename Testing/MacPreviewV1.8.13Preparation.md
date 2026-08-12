# Mac v1.8.13 预览候选准备

## 状态与范围

- 目标版本：`1.8.13 (105)`。
- 当前分支：`codex/integrate-mac-v1.8.13`。
- 本阶段只准备产品代码、版本说明和验证记录，不修改 `Resources/Info.plist`，不创建 `release/pre-v1.8.13`，不打包或发布。
- 产品代码进入 `main` 后，才能从 `main` 创建正式的预览发布分支并写入版本号。

本候选计划包含：

1. Intel Mac 独立发行线；Intel 安装包支持 macOS Ventura 13 或更高版本，Apple Silicon 安装包继续要求 macOS 14 或更高版本。
2. 修复遥控器按键释放或设备断开后，Mac 实体键盘方向键、音量键等可能仍被拦截的问题。
3. 等待 iPhone 连接时可以取消，之后可以重新开启并切换其他设备，无需重启 App。

## Release Notes 草案

### 中文

- 新增 Intel Mac 独立安装包，支持 macOS Ventura 13 或更高版本；Apple Silicon 安装包继续要求 macOS 14 或更高版本。
- 修复遥控器按键松开或设备断开后，Mac 实体键盘方向键、音量键等可能仍无法使用的问题。
- 连接 iPhone 时现在可以随时取消等待，随后重新开启并切换其他设备，无需重启无线麦。

### English

- Added a separate Intel Mac package for macOS Ventura 13 or later. The Apple Silicon package continues to require macOS 14 or later.
- Fixed physical keyboard arrow, volume, and other keys sometimes remaining blocked after a remote button was released or the remote disconnected.
- Waiting for an iPhone connection can now be cancelled and restarted to switch devices without relaunching Remote Mic.

## 自动化验证

发布分支创建前需完成：

- `git diff --check`
- `swift test --filter HardwareSimulationIntegrationTests`
- `swift test --filter SettingsPageRegressionTests`
- Apple Silicon 与 Intel 配置变体的完整 Swift 测试和 `scripts/test.sh`
- Apple Silicon `arm64-apple-macosx14.0` 与 Intel `x86_64-apple-macosx13.0` 的非打包 Release 编译
- 确认 `scripts/verify-preview-branch.sh` 的产品代码先进入 `main` 门禁仍然成立

## 人工与真实环境边界

- 实体遥控器释放、断连及 Mac 实体键盘恢复仍需真机复验。
- 两台不同 iPhone 之间取消等待并切换连接仍需真机验收。
- Intel 真实机器的既有验收记录见 [IntelVenturaCompatibility.md](./IntelVenturaCompatibility.md)；本轮编译验证不能替代新的真机安装与运行验收。
- 当前阶段没有生成可安装包，因此不执行签名、公证、Sparkle 更新或跨版本安装验证。

## 验证过程说明

- 首次把全部测试与硬件模拟套件放在同一进程并发运行时，测试进程在 AppKit 事件转换中中止。崩溃报告显示新增加的双遥控器模拟用例漏注入固定的前台 App，意外访问了真实 `NSWorkspace`；这不是产品代码断言失败。
- 已为相关新用例补齐固定前台 App 注入，确保硬件模拟不读取当前桌面状态。后续完整矩阵必须从独立构建目录运行，避免切换可选 Swift Package 环境变量后复用旧对象文件。
- Apple Silicon 与 Intel 配置变体的完整 Swift Testing 均通过，各包含 234 项测试；两种配置的 Self Test 均为 42 项通过。
- `arm64-apple-macosx14.0` Release 可执行文件已确认为纯 `arm64`、最低 macOS 14.0；`x86_64-apple-macosx13.0` Release 可执行文件已确认为纯 `x86_64`、最低 macOS 13.0。
- `x86_64` 测试 bundle 可以完成交叉编译，但本机 Xcode 26.4 的 Swift 与 `swiftpm-testing-helper` 只有 `arm64` slice，无法通过 Rosetta 加载 Intel 测试 bundle；因此 Intel 配置逻辑测试与 Intel 指令集编译均已验证，但本轮没有新增真实 Intel 运行验收。
