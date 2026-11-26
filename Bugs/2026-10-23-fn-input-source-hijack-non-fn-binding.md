# 语音键绑定非 Fn 时，Mac 键盘 Fn 仍劫持切换输入法

日期：2026-10-23

## 现象

用户把语音键绑定为右 Command、语音工具选择豆包后，在 Mac 笔记本键盘上按住 Fn/地球键，当前输入法立即切换为豆包输入法；松开后恢复原输入法。设置界面没有任何开关可以关闭该行为。撤销「输入监控」权限可以让切换消失，但遥控器的播放/暂停、显示桌面等按键映射同时全部失效，不可作为解决方案。

## 证据

- `PreferredInputSourceMonitor`（`Sources/RemoteMic/PreferredInputSourceMonitor.swift`）通过 `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` 全局监听 `.function` 修饰键，不区分事件来自 Mac 键盘还是遥控器。
- Fn 按下触发 `beginVoiceSession(reason: "function_key_down", owner: .functionKey)`；语音工具为豆包时 `preferredInputSourceID == "com.bytedance.inputmethod.doubaoime.pinyin"`，经 `TISSelectInputSource` 切换输入法；松开经 `finishManagedInputSourceSession` 恢复原输入源。与现场「按住切换、松开还原」逐字吻合。
- 原启动条件 `if started, permissionSnapshot.inputMonitoringGranted`（`Sources/RemoteMic/BridgeAppModel.swift` `applyHIDSettings()`）只检查运行状态和输入监控权限，不检查 `settings.voiceKeyMode`，因此绑定右 Command 时 legacy Fn 监听仍然运行。
- 同文件 `beginVoiceSession()` 的注释明确写了 Command/Option 绑定的输入源生命周期应由语音会话显式驱动（`beginVoiceSession()`/`endVoiceSession()`，`BridgeAppModel.swift` 语音会话路径已接入），不应由 legacy Fn 监听处理普通 Command/Fn 按键——代码与该注释不一致。
- 遥控器按键映射依赖输入监控权限：`AppleSiriRemoteAdapter` 以 `inputMonitoringGranted` 守门 HID event tap，与用户撤销权限后按键失效的报告一致。
- 日志验证路径：按住 Fn 应出现 `VOICE INPUT function_key edge=down tool=doubao` 与 `source_prepare ... result=selected`，松开出现 `source_restore`。本次修复前未采集现场日志，根因依据源码静态证据；置信度高（行为链路与现象逐项吻合）。

根因：`applyHIDSettings()` 无条件启动 `PreferredInputSourceMonitor` 的全局 Fn 监听，导致绑定非 Fn 时 Mac 键盘普通 Fn 按键被误当作语音键代理，触发输入法切换/恢复。

## 修复

`Sources/RemoteMic/BridgeAppModel.swift` `applyHIDSettings()`：

- 启停块从函数开头移动到所有语音键模式回退逻辑之后、`startHIDMonitors` 之前，确保使用最终生效的 `settings.voiceKeyMode`（覆盖映射失败回退 Fn 的路径）。
- 启动条件增加 `settings.voiceKeyMode == .function`：仅 Fn 绑定保留 legacy 全局 Fn 监听（该模式下遥控器语音键经硬件 Fn 注入，输入源准备依赖 flagsChanged）；非 Fn 绑定一律 `stop()`。
- Command/Option 绑定路径不受影响：其输入源切换由语音会话显式调用 `preferredInputSourceMonitor.beginVoiceSession()`/`endVoiceSession()`，不依赖全局监听。
- 显式会话保留逻辑（`preservingExplicitVoiceSession`）不变。

同步更新：

- `Tests/RemoteMicTests/PreferredInputSourceMonitorTests.swift`：源码断言改为锁定新门禁条件（输入监控权限 + Fn 绑定）。
- `Testing/VoiceKeyModes.md`：Issue #307 回归中「等待期间触发 Fn」子句改为移动端语音（Fn 在非 Fn 绑定下不再参与 owner 共存）；新增「非 Fn 绑定下 Mac 键盘 Fn 不切换输入源」回归用例。

## 验证

- `swift test --disable-keychain --filter PreferredInputSourceMonitorTests`：通过。
- `swift test --disable-keychain --filter VoiceKeyModeTests`：通过。
- `swift build --disable-keychain`：通过。

边界：自动化只能证明门禁接线与 monitor 自身状态机。2026-10-23 已完成用户本机验收（ad-hoc 构建安装后，语音键绑定右 Command、语音工具为豆包时，按住/松开 Mac 键盘 Fn 输入法不再切换到豆包，原始问题消失）。遥控器语音会话期间 `source_prepare`/`source_restore` 不受影响、以及 Fn 绑定模式下的原有行为，仍按 `Testing/VoiceKeyModes.md` 回归用例待完整真机验收。撤销输入监控权限的规避方案已确认不可行，不再作为建议。
