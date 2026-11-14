# macOS 27 写入 native key mapping 后 HID 报告停止投递

- 时间：2026-11-14
- 状态：根因已确认，修复已通过 build 360 干净源码构建及 RC001 / RC003 真机复测；macOS 26、Intel 等边界待补
- 影响范围：macOS 27 上的小米 RC001 / RC003；SayAll 2.0.0 开发线
- 功能点：普通按键 HID 报告接收、Onboarding 遥控器页、`RemoteNativeKeyMapper`

## 现象与证据

macOS 27.0.1（26A434）连接 RC003 时：

- 语音键正常，ATVV 音频会话有真实 PCM；
- 方向键、OK、音量键在系统层没有反应；
- `HID PERMISSIONS input=true accessibility=true`；
- `HID NATIVE MAPPING phase=prepare result=verified`；
- `HID START mode=adaptive`、`HID CONNECTED mode=monitored`；
- 但 `HID REPORT accepted = 0`、`HID EDGE = 0`。

A/B/C 对照：

| 状态 | 遥控器普通键 | HID 报告 |
| --- | --- | --- |
| A：SayAll 关闭 | 正常 | 不适用 |
| B：SayAll 运行 | 无反应 | 0 |
| C：退出 SayAll | 恢复 | 不适用 |

退出后日志出现：

```text
HID NATIVE MAPPING phase=restore result=verified
```

说明不是遥控器 HID 链路损坏，也不是权限或设备打开失败。

## 诊断实验

### 实验一：跳过 native key mapping

临时跳过 `RemoteNativeKeyMapper.prepare()` 写入：

- `HID REPORT accepted = 52`；
- `HID EDGE = 52`；
- 方向键、OK 同时触发原生动作和 SayAll 动作，表现为 2 次；
- 音量键只触发 1 次，`HID FILTER` 成功抑制原生音量事件。

结论：HID 报告路径本身可用；是 `UserKeyMapping` 写入导致 macOS 27 停止向 App 投递报告。

### 实验二：保留完整 mapping，改用 device 级回调

保留完整 native key mapping，改为 `IOHIDDeviceRegisterInputReportWithTimeStampCallback`：

- `HID REPORT accepted = 46`；
- `HID EDGE = 46`；
- `HID BUTTON = 18`；
- 方向键、OK、音量各触发 1 次；
- 语音正常。

随后在正式候选中同时保留 manager 回调作为无法单独打开设备时的兜底，并按设备去重：

```text
HID REPORT path=device+manager
HID REPORT device_callback registered path=device
HID REPORT accepted = 84
HID EDGE = 84
HID BUTTON = 50
```

真机复测：RC003 和 RC001 的方向键、OK、音量、TV、电源和语音均正常；TV 无额外系统动作；Power 不锁屏/睡眠；快速连按和长按正常。最终结果来自 build 360 干净源码构建。

## 根因

`RemoteNativeKeyMapper` 通过 `IOHIDServiceClientSetProperty(UserKeyMapping)` 把小米遥控器普通键映射成 `0`，用于在事件产生前阻止系统原生动作。macOS 27 在写入该映射后，不再向同一进程的 **manager 级**输入报告回调投递报告，但 **device 级**回调仍然投递。

因此：

1. native mapping 保护仍然必要，不能简单删除；
2. 旧的事件 tap 兜底不能替代它，否则会重新打开 TV/音量/Power 的原生事件竞态；
3. 修复必须保留 native mapping，只切换报告获取路径。

## 修复

- macOS 27+：为每个成功打开的 `IOHIDDevice` 注册
  `IOHIDDeviceRegisterInputReportWithTimeStampCallback`；
- 每个设备保留预分配报告缓冲区和 run loop 调度；
- 保留 manager 级回调，用于无法单独打开设备的 fallback；
- 同一设备同时存在 device 回调时，丢弃 manager 回调，避免重复执行；
- 设备注册、去重和回调生命周期使用锁保护；
- 报告 run loop 停止后才释放退役缓冲区，避免报告线程仍在回调时释放内存；
- macOS 26 及更早版本继续只使用 manager 回调，保持现有行为。

## 自动化验证

```text
xcrun swift test --disable-keychain --filter \
  'RemoteButtonsTests|RemoteNativeKeyMapperTests|KeyboardEventSuppressorTests'
234 tests in 3 suites passed
```

完整测试：1422 tests / 104 suites 通过。新增 `managerReportIsDroppedOnlyWhenDeviceCallbackExists` 覆盖 manager/device 去重判据。`scripts/test.sh` 自测 48/48 通过。

## 真机边界

已完成：

- macOS 27.0.1 + RC003 / RC001，build 360 干净源码构建（`source_commit=57367e024a63b141594b3b48da22883dd293d1d6`，`dirty=false`）；
- 两种型号的方向键、OK、音量、TV、电源和语音均正常；
- TV 无额外动作；
- Power 不锁屏/睡眠；
- 快速连按、长按方向键正常；
- build 359 候选验证 Onboarding 遥控器页可接收控制键。

尚未完成：

- macOS 26 / Intel 回归（代码路径保留 manager 回调，仍需实机确认）；
- 睡眠/唤醒、断连重连、第三方语音工具文字上屏；
- 双设备隔离和其他 HID 工具占用场景。

build 360 可作为本 Bug 的候选修复，但 macOS 26、Intel 等边界未验证前，不得表述为完整兼容矩阵通过。

## 变更文件

- `Sources/RemoteMic/HIDRemoteMonitor.swift`
- `Tests/RemoteMicTests/RemoteButtonsTests.swift`
- `Bugs/README.md`
- 本记录
