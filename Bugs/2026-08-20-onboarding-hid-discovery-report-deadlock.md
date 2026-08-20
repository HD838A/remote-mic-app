# Onboarding 已发现遥控器但永远等不到首个 HID 按键

- 时间：2026-08-20
- 状态：根因已确认并完成候选修复，等待 RC001 / RC003 真机验收
- 影响范围：无线麦SayAll.app `1.9.3 (125)`；macOS 26；尚未建立 HID 指纹绑定的实体遥控器
- 功能点：Onboarding 遥控器页、HID 自动发现、多遥控器隔离
- 简单描述：蓝牙语音连接已经 Ready，macOS 会响应遥控器按键，但 App 的 HID discovery 一直停在等待首份报告，导致 Onboarding 无法继续。

## 复现与真实日志

用户现场诊断为：

- `control_connected=true`；
- `permission_input_monitoring=true`；
- `permission_accessibility=true`；
- `control_button_observed=false`；
- `button_status=button_mapping.status.waiting_for_device`；
- 最终失败 `remote.button_not_ready`。

用户提供的完整 `runtime.log` SHA-256 为：

```text
00e9abe0c673848c69e4dc8a1a549a9264100d64716e20d83648ca9f262a08fe
```

日志从 `2026-08-20T07:02:40Z` 到 `07:56:20Z` 共出现 157 次：

```text
HID DEVICE deferred reason=discovery_waiting_for_report
```

同一时段反复确认：

```text
BLE READY name=小米蓝牙语音遥控器
VOICE FN MAPPING applied=true ... power_suppressed=true suppression_scope=locations=1
HID PERMISSIONS input=true accessibility=true
HID START mode=adaptive
```

但完整日志没有一次 `HID REPORT`、`HID CONNECTED` 或 `HID EDGE`。多次点击“重新检测按键”、前后台切换和 App 重启只会重新进入同一等待状态。

## 根因

为避免两只未绑定遥控器同时存在时，单个 discovery monitor 被系统首先枚举的设备抢占，旧实现从 `deviceDidMatch` 返回，不打开也不绑定候选设备，计划等第一份真实输入报告到达后再按报告来源选择遥控器。

该实现隐含假设仅依赖 manager 级打开即可稳定收到候选设备的首份 input report，不需要像旧路径一样为匹配到的 `IOHIDDevice` 建立显式的非独占监听链接。用户的 macOS 26 现场否定了这个假设：设备匹配回调稳定到达，但 input report 永远不到达。代码等待报告后才显式打开设备，因此形成等待闭环。

这不是 Onboarding 页面状态未刷新，也不是权限或 BLE 失败。页面正确反映了生产 HID 链路没有收到按键；直接放宽门禁会让用户进入主界面后仍无法使用普通按键。

## 修复

1. discovery monitor 匹配到安全且尚未绑定的 HID 设备时，以非独占监听模式显式打开候选设备，但不立即绑定 Profile。
2. 可以同时探测多个未绑定候选；第一份真实报告到达后，只提升实际发出报告的设备为当前 active device，并关闭其他候选。
3. 继续使用报告来源 fingerprint 完成 Profile 注册，首个按键不被消耗；随后创建新的 discovery monitor 处理剩余未绑定遥控器。
4. 已绑定 monitor 仍直接激活自己的 target fingerprint；已被其他 monitor 占用的 fingerprint、非安全 Location 和不匹配设备继续拒绝。
5. 候选设备被移除、监听器重建或停止时显式关闭，避免遗留 IOHID 打开状态。

## 自动化验证

- 失败优先测试：旧实现缺少 `deviceMatchDecision`，定向测试先编译失败。
- 修复后定向测试 `discoveryProbesMatchedDevicesWithoutBindingTheEnumerationWinner` 通过。
- `swift test --filter RemoteButtonsTests`：86 项通过，覆盖发现探测、空闲报告不抢占、报告来源路由、已绑定隔离、首按不丢失、权限与电源键安全门。
- `swift test --filter OnboardingFlowTests`：28 项通过。
- `swift test`：314 项、31 个 suite 通过。
- 私有硬件事件回放：21 项通过，覆盖 RC001 / RC003 语音、12 个按键、36 个手势、双设备隔离和 monitored 模式抑制释放。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：42/42 通过。
- Apple Silicon 与 `x86_64-apple-macosx13.0` Release 构建通过。

## 真机验证边界

自动化可以证明 discovery 不再绑定系统枚举赢家，并保留多遥控器路由策略；Swift 测试不能真实驱动 macOS IOHIDManager 的设备匹配和 input report 回调。交付预览版前仍需在真实 RC001 / RC003 上确认日志顺序变为：

```text
HID DEVICE probing mode=monitored
HID CONNECTED mode=probed
HID REPORT accepted ...
HID EDGE pressed=...
```

同时必须复验双遥控器、普通按键、语音、断连重连和电源键不锁屏。未经该真机用例，不表述为已经完成真实硬件验收。
