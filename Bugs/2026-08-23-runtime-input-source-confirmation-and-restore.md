# 运行时切换输入法反复触发系统确认且不会恢复原输入法

- 时间：2026-08-23
- 状态：候选修复完成，等待真实微信/豆包输入法与遥控器验收
- 影响范围：完成 Onboarding 后使用豆包或微信输入法的 macOS 运行时语音路径
- 功能点：Fn 语音触发、macOS Text Input Sources、输入法会话生命周期
- 简单描述：用户手动切到英文输入法后再次使用无线麦语音输入，系统可能反复弹出“允许 SayAll 启用微信输入法/豆包输入法”；语音结束后当前输入法也不会恢复为语音开始前的输入法。

## 复现证据

用户现场截图显示 macOS 系统弹窗：

> Allow “SayAll” to enable “微信输入法”?

用户描述的稳定触发顺序为：

1. Onboarding 已选择微信输入法或豆包输入法；
2. 用户手动切换到英文输入法；
3. 使用无线麦开始语音；
4. macOS 弹出允许 SayAll 启用目标输入法的确认框。

本问题的代码级复现路径已确认；当前代理环境无法稳定驱动真实第三方输入法和系统安全弹窗，因此弹窗是否在真实签名候选中完全消失仍需真机验收。

## 日志结论

当前 `runtime.log` 原有事件只记录：

```text
VOICE INPUT source_prepare tool=<tool> result=<result>
```

修复后新增同一前缀下的 `managed`、`source_restore` 和跳过原因，可区分：

- 已经是目标输入法，未执行切换；
- 运行时只选择已启用输入法；
- 本次会话由无线麦接管了输入法；
- 用户主动改选后跳过恢复；
- 语音结束或监听停止后的恢复结果。

日志不记录用户输入文字、前台 App、完整输入源列表或快捷键内容。

## 根因

`Sources/RemoteMic/PreferredInputSourceMonitor.swift` 在 Fn 按下边沿调用输入法准备逻辑。此前默认使用 `OnboardingInputSourceSwitcher.selectIfNeeded`，而 `Sources/RemoteMic/OnboardingInputSourceSwitcher.swift` 在当前输入源不一致时始终执行：

```swift
TISEnableInputSource(source)
TISSelectInputSource(source)
```

这把日常“选择一个已经启用的输入法”误做成了“重新启用输入法”。macOS 将启用第三方输入法视为敏感操作，因而可能显示系统确认框。

原实现同时没有保存语音开始前的输入源，所以语音结束后只能保持目标输入法，无法恢复用户原来的英文或其他输入法。

## 修复

- 保留 Onboarding 的显式输入法设置路径，允许在设置阶段处理目标输入法启用；
- 为运行时增加只针对已启用输入源的准备路径，日常语音不再无条件执行 `TISEnableInputSource`；
- Fn 按下时保存当前输入源 ID，并记录本次会话是否由无线麦拥有切换；
- Fn 松开、监听停止或 App 停止时，仅当当前仍是无线麦切入的目标输入法时恢复原输入源；
- 如果用户在语音期间手动切换到其他输入法，结束时跳过恢复，不覆盖用户选择；
- 目标输入法已经选中时不执行准备调用；
- 不拦截、不模拟、不假设 `Control + Space` 或任何用户自定义输入法快捷键；
- 切换失败不阻断原有语音链路，也不循环重试。

## 修改文件

- `Sources/RemoteMic/OnboardingInputSourceSwitcher.swift`：区分 Onboarding 显式启用与运行时已启用输入源选择，提供当前输入源读取和安全恢复选择。
- `Sources/RemoteMic/PreferredInputSourceMonitor.swift`：增加输入法会话保存、恢复、用户主动改选保护和停止清理。
- `Tests/RemoteMicTests/PreferredInputSourceMonitorTests.swift`：覆盖恢复、手动改选不覆盖、监听停止恢复、已选目标旁路和既有 Fn 去重。
- `Testing/FirstRunOnboarding.md`：更新用例 2A 的输入法恢复、弹窗和快捷键边界。
- `feature/preferred-input-source-switching/README.md`、`feature/README.md`：同步公开行为与验证边界。
- `TODO.md`：同步候选功能的状态和新行为说明。

本次未修改蓝牙协议、HID 报告解析、虚拟音频格式或输入法快捷键配置。

## 验证

- `swift test --filter PreferredInputSourceMonitorTests`：8 项通过。
- `swift test`：326 项测试、31 个 suite 全部通过。
- `./scripts/test.sh`：42/42 项通过。
- Release 构建与启动：`./script/build_and_run.sh --verify` 通过；Apple Silicon Release 构建成功，App 启动成功。
- 代码签名校验：`codesign --verify --deep --strict dist/SayAll.app` 通过。
- `git diff --check`：通过。
- 真实 macOS 系统安全弹窗、微信/豆包输入法、遥控器 Fn 事件和最终文字上屏：待真机验收。

## 验证边界

单元测试通过只能证明会话状态机和依赖接线；它不能证明真实 macOS 在所有权限历史下不再弹窗，也不能替代真实签名 App、第三方输入法、遥控器和目标 App 的完整语音输入流程。真机验收完成前，状态只能保持“候选修复完成，等待真实验收”。
