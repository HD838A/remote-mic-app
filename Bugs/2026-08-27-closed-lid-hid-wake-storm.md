# 合盖后 RC001 每约 48 秒触发 HID FullWake

- 时间：2026-08-27
- GitHub：[#240](https://github.com/HD838A/remote-mic-app/issues/240)
- 状态：已在 `v1.9.16` 后续主线完成候选修复；自动化状态回放、项目自检、Debug/Release 构建与 App 自检通过，等待签名公证测试包、真实合盖电源日志及 RC001 / RC003 首按验收
- 基线：`v1.9.16` Tag `420767d6100de20e27f4d97f1e15beb20c1aa71e` 后的 upstream `main` `1333e2c75d5b88ffc51921cb1e1310426d5acdd4`
- 影响范围：macOS `1.9.8 (131)` 已确认；`v1.9.16` 增加真实唤醒后的主动 BLE 恢复，但仍未在系统睡眠时暂停 BLE / HID
- 功能点：系统休眠、CoreBluetooth、IOHID、合盖 DarkWake、遥控器重连

## 复现

1. 在 M2 MacBook Air、macOS 26.6.2 上安装 Apple Silicon `1.9.8 (131)`。
2. 只保留一个已绑定 RC001 profile，开启自定义按键映射并授予输入监控、辅助功能权限。
3. 语音输出选择“无”，确认没有虚拟音频引擎运行。
4. 保持 SayAll 运行、接通电源并合上屏幕，持续约一天。
5. 开盖后保存 `runtime.log`、`pmset -g log`、进程与内存状态。

正常边界：合盖后 Mac 应保持睡眠；SayAll 不应在 DarkWake 中主动恢复 BLE / HID。真实开盖或解锁后，遥控器和语音应恢复。

错误结果：28.5 小时内发生 1,420 次系统睡眠和 1,420 次系统唤醒，中位间隔 48 秒；每个周期都伴随 BLE 连接与 HID monitor 重建。

## 日志结论

同一现场会话内：

- `system_did_wake` / `system_will_sleep`：各 1,420 次。
- `BLE READY`：1,427 次；`BLE SCANNING`：1,423 次。
- `HID DISCONNECTED`：1,418 次；`HID START`：2,858 次。
- 音频始终 `engine_running=false`、`selected={none}`，排除虚拟音频为根因。
- 只有一个 RC001 profile，排除多个失效历史缓存约 11 秒重连问题。

相同时间点的 `pmset` 顺序为：

```text
Sleep     Entering Sleep state due to 'Clamshell Sleep'
DarkWake  ... wifibt SMC.OutboxNotEmpty
Assertions bluetoothd TurnedOn UserIsActive "Bluetooth LE HID Activity"
Wake      DarkWake to FullWake ... due to HID Activity
```

FullWake 维持约 10 秒，约 35 秒后再次睡眠，形成约 47～48 秒周期。

## 版本回溯

`v1.9.16` 合入的 PR #243 解决“真实唤醒后 BLE 可能不恢复”：`systemDidWake` 会调用 `recoverAfterSystemWake()` / `reconnectNow()`。它没有停止系统睡眠期间的 bridge 或 HID monitor，也没有 DarkWake、显示器或合盖状态门禁，因此不能替代本问题修复。

## 根因

实体遥控器缺少独立系统睡眠生命周期。系统睡眠通知只管理虚拟音频；BLE bridge、CoreBluetooth central、IOHID managers 和事件抑制器继续运行。合盖 DarkWake 因而仍允许系统回调和 App 重连进入 Ready，并重复重建 HID。

系统日志可以确认 App 在每轮 FullWake 中放大 BLE/HID 生命周期，但不能仅凭现有证据断言第一层硬件唤醒一定由 App 而不是 RC001 固件/macOS 发起。

## 修复

- 新增 `active / sleeping / wake_pending` 纯状态和 generation 门禁。
- `systemWillSleep` 立即停止 HID monitor、事件抑制器、实体遥控器 bridge、长录音和物理遥控器语音键会话。
- `XiaomiBluetoothBridge.suspendForSystemSleep()` 在请求断连后立即 detach peripheral/central delegate、取消扫描与 timer、释放当前 generation；不等待可能跨睡眠丢失的异步断连回调。
- `systemDidWake` 先等待 15 秒。若约 10 秒 DarkWake 后再次休眠，取消恢复；不会执行 v1.9.16 的主动 wake reconnect。
- 只有显示器 active、未休眠且 IOKit 明确报告合盖已打开时才立即恢复。合盖状态未知时 fail closed，等待 session active 或 15 秒稳定窗口。
- 真实恢复时重新应用 HID 设置并启动现有/缺失 BLE bridge。保留 v1.9.16 在每个 bridge 首次进入 Ready 后重新应用 HID 设置的行为；它只在真实恢复后发生，不会在暂停的 DarkWake 中运行。
- 睡眠期间拒绝手动 reconnect、discovery refresh、HID apply、迟到 Ready/音频 callback；不删除 profile、按键映射、重连退避或 Power→F20 安全映射。
- 若 App 未观察到对应 `systemWillSleep`，保留 v1.9.16 原有 `systemDidWake → recoverBluetoothAfterSystemWake()` 作为兼容回退。

## 验证

已执行：

- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：49 项通过；覆盖 DarkWake 回睡不恢复、稳定窗口只恢复一次、未知合盖状态 fail closed、可见唤醒立即恢复、生产接线立即 detach BLE 且抑制 upstream wake reconnect。
- `swift build`：通过；只有基线已有的 API 弃用警告。
- `./scripts/build-app.sh`：Apple Silicon Release App 构建通过；本地 ad-hoc 产物仅用于结构验证，不可分发。
- `./scripts/verify-app.sh dist/SayAll.app`：Bundle、资源、本地化、架构和签名结构自检通过。
- Swift Testing 新增同等状态与接线测试；当前本机 Command Line Tools 缺少 `Testing` module，`swift test` 无法在本机编译，必须由 upstream 正常 CI/Xcode 环境执行。

## 验证边界

自动化不能证明：

- 真实 RC001/macOS 在 App central 和 IOHID client 释放后是否仍产生 HID FullWake；
- CoreBluetooth 的真实断连与重新枚举时序；
- 开盖后的第一颗普通按键和第一次 `STREAM_START → AUDIO → STREAM_STOP`；
- RC003 Power→F20、Command 键语音模式和 Fn 点按模式在睡眠边界的完整用户旅程。

发布测试包前必须按 `Testing/MacClosedLidRemoteWakeStorm.md` 完成签名、公证和重新下载门禁。测试包仍需执行 App 停止对照、至少一小时 RC001 合盖、RC003 回归及 12～24 小时长期观察。若 App 停止时仍保持同样 48 秒 FullWake，需把 RC001/macOS 初始唤醒作为独立系统问题继续调查。
