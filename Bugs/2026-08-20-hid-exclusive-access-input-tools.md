# HID 遥控器被其他输入工具占用时 Onboarding 无法继续

- 时间：2026-08-20
- 状态：候选修复完成，等待 Karabiner-Elements 与其他 HID 工具真机验收
- 影响范围：无线麦SayAll.app 实体遥控器按键发现、Onboarding 遥控器步骤
- 功能点：HID 设备打开、第三方键盘/鼠标/HID 映射工具兼容
- 简单描述：蓝牙和系统权限均正常，但其他输入工具占用遥控器 HID 设备时，SayAll 无法读取按键，只显示按键未就绪。

## 原始记录

- [Issue #95：Karabiner-Elements “Modify events” prevents SayAll from receiving remote HID events](https://github.com/HD838A/remote-mic-app/issues/95)
- [Issue #105：Karabiner-Elements 独占遥控器 HID 设备](https://github.com/HD838A/remote-mic-app/issues/105)
- 现场日志 `/Users/andy/Downloads/runtime.log` 的 SHA-256：

```text
00e9abe0c673848c69e4dc8a1a549a9264100d64716e20d83648ca9f262a08fe
```

## 观察

Issue #95 / #105 报告了 `-536870203`，对应 IOKit 的 `kIOReturnExclusiveAccess`。用户确认 Karabiner-Elements 开启遥控器 “Modify events” 后，系统仍能响应按键，但 SayAll 不能打开或读取同一个 HID 设备。

本次现场 `runtime.log` 没有出现 `-536870203` 或 `HID DEVICE OPEN FAILED`，而是重复出现 `HID DEVICE deferred reason=discovery_waiting_for_report`。这证明旧 discovery 在打开候选设备前就等待首份报告，不能单凭该日志确认 Karabiner 是现场占用者；它与 HID 首报告 discovery 死锁是两个可叠加的失败分支。

## 根因结论

IOKit 不提供可靠的公开接口告诉应用“具体哪个进程占用了 HID 设备”，但会返回 `kIOReturnExclusiveAccess`。因此：

1. 独占错误码是判断“设备被其他输入工具占用”的可信条件。
2. Karabiner-Elements 的安装检测只能作为辅助提示，不能当作根因证明；设备也可能被 BetterTouchTool、USB Overdrive、SteerMouse 或其他 HID 工具管理。
3. HID discovery 仍需保留非独占 probe，解决 macOS 26 下设备匹配后不主动产生首份报告的问题。

## 修复

- `HIDRemoteMonitor` 在 manager、probe 和普通设备打开失败时识别 `kIOReturnExclusiveAccess`；覆盖 Issue #95 中旧诊断使用的 `button_mapping.error.remote_read_failed` 路径。
- 未检测到 Karabiner-Elements 时显示通用提示，说明可能存在键盘、鼠标或 HID 映射工具占用。
- 检测到 Karabiner-Elements 已安装时，在同一提示中补充操作：打开“设备”，找到“小米蓝牙语音遥控器”，关闭 “Modify events” 或设为 “Ignore”，再重新检测。
- 日志记录 `HID MANAGER OPEN BLOCKED` / `HID DEVICE PROBE BLOCKED` / `HID DEVICE OPEN BLOCKED`、错误码以及 Karabiner 安装检测结果；不把软件安装状态写成设备占用的确定结论。
- 设备打开成功、但其他原因导致读取失败时继续显示原错误码；双遥控器隔离、首报告绑定、电源键保护不变。

## 自动化验证

- 失败优先：旧实现缺少独占错误分类和 Karabiner 安装检测，定向测试先编译失败。
- 修复后 `swift test --filter RemoteButtonsTests`：新增独占错误分类、安装检测和既有 HID 路由测试通过。
- 完整 Onboarding、Swift、硬件事件回放、自检和双架构构建结果记录在交付说明中。

## 真机验证边界

自动化不能证明 macOS 真实 HID 独占行为。必须分别在以下环境现场验证：

1. 未安装第三方 HID 工具：首报告 discovery、普通按键和双遥控器。
2. Karabiner-Elements 已安装且对遥控器开启 “Modify events”：显示独占提示，关闭设置后无需重启 App 即可重新检测成功。
3. Karabiner-Elements 已安装但未管理遥控器：不能误判为占用，正常按键仍可通过。
4. 其他 HID 工具占用设备：显示通用提示，不强行归因于 Karabiner。

未经上述真实设备验收，不表述为已经解决所有第三方 HID 工具兼容问题。
