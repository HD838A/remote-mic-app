# 重新授权后组合快捷键监听未恢复

- 时间：2026-08-20
- 状态：候选修复完成，等待真实权限与遥控器验证
- 影响范围：macOS 1.9.3 (125)，Developer ID 签名身份变化或输入监控、辅助功能重新授权场景
- 功能点：实体遥控器自定义按键映射与组合快捷键执行
- 简单描述：组合键配置已经正确保存，但权限恢复后 HID 监听器没有自动重建，遥控器动作无法进入快捷键发送阶段。

## 复现与正常边界

可重复触发条件：保持 `customMappingEnabled=true`，以新的 Developer ID 身份替换原 App，使输入监控或辅助功能授权失效；启动 App 后在系统设置中重新授权并返回 App，不重新切换映射开关。

错误行为：设置页可以保存并重新显示 `Control + Left/Right`、`Control + L`、`Command + Control + Q` 等组合键，但真实遥控器操作没有产生 `HID BUTTON`，目标系统快捷键也不执行。

正常行为边界：原 Developer ID 身份且两项权限在启动前已经有效时，历史日志存在 `HID BUTTON ... action=customShortcut`；普通蓝牙连接和电量事件在本次失败现场也保持正常。

## 日志与配置证据

- 2026-08-20 15:38:19，当前 `/Applications/SayAll.app` 启动后记录 `HID PERMISSIONS input=true accessibility=false`。
- 15:39 测试期间仍有 BLE 电量事件，但没有 `HID BUTTON` 或 `HID ACTION`，说明失败发生在按键执行之前。
- 当前 RC003 配置档正确保存：右键双击为 keyCode 124、Control flags 262144；左键双击为 keyCode 123、Control flags 262144；返回键双击为 keyCode 37、Control flags 262144；电源键为 keyCode 12、Command + Control flags 1310720。
- `/Applications/SayAll.app` 的 Developer ID Team ID 为 `FH5RUQGB5U`，Hardened Runtime 与深度签名校验通过，因此本次根因不是配置损坏或 ad-hoc 签名残留。

## 根因

`SettingsView` 在 App 重新激活时会刷新权限显示，但只有 `isWaitingForMappingPermissions=true` 才调用 `applyHIDSettings()`。这个临时状态只在用户从映射开关警告进入权限页时设置；升级签名后映射本来就是开启状态，用户从权限页重新授权不会设置它。`RemoteMicAppDelegate.applicationDidBecomeActive` 也没有恢复 HID 的逻辑。因此权限从拒绝变为允许后，启动时失败关闭的监听器一直保持停止。

## 修复

- `BridgeAppModel` 保存最后一次应用 HID 设置时的输入监控与辅助功能快照。
- App 每次重新激活时比较当前权限；仅当运行中、映射已开启且权限确实变化时重新应用 HID 设置，避免每次激活都无条件打断监听。
- 新增 `HID PERMISSIONS changed ... recovery=apply_settings` 日志，证明权限变化触发了恢复。
- 自定义快捷键提交 `CGEvent` 后记录 `SHORTCUT ACTION submitted`、keyCode 和修饰标志，区分“配置正确”“已收到遥控器动作”和“已提交系统事件”三个阶段。

## 验证

自动化应覆盖权限从 `input=true/accessibility=false` 变为两项都允许时触发恢复，以及权限未变化、App 未运行、映射关闭和没有历史快照时不误恢复。完整验证命令：

```bash
scripts/test.sh
CODE_SIGN_IDENTITY='Developer ID Application: LI XING HUA (FH5RUQGB5U)' REQUIRE_DEVELOPER_ID_SIGNING=1 scripts/build-app.sh
codesign --verify --deep --strict --verbose=4 dist/SayAll.app
```

2026-08-20 本机验证结果：`swift test` 共 315 项通过，`scripts/test.sh` 共 42 项自检通过；Team `FH5RUQGB5U` 的 Developer ID 构建、Hardened Runtime、嵌套组件和深度签名校验通过。修复版安装到 `/Applications/SayAll.app` 后，启动日志从原现场的 `input=true accessibility=false` 变为 `input=true accessibility=true`，并出现 `HID FILTER ready=true` 与 `HID START mode=adaptive`，证明权限门和监听启动已经恢复。

真机验收仍必须使用真实 RC003 双击右键执行 `Control + Right`，并核对日志出现 `HID BUTTON` 与 `SHORTCUT ACTION submitted` 以及屏幕上的最终系统动作。当前代理实时监听期间没有观察到新的实体按键操作，因此尚未宣称真实遥控器端到端通过。自动化、模拟 HID、编译和签名不能替代 WindowServer、真实遥控器、系统全局快捷键与最终屏幕结果。
