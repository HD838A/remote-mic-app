# Unbound Multi-Remote Button Actions Are Ignored

- 时间：2026-08-10
- 状态：已修复，双遥控器真机复验通过
- 影响范围：macOS；同时连接两只尚未建立 HID 指纹绑定的遥控器
- 功能点：多遥控器 HID 自动发现、单击与双击动作
- 简单描述：发现监听器只接收系统首先枚举到的 HID 设备，按另一只未绑定遥控器时，单击和双击均不会进入动作层。
- 原始记录：用户截图、`~/Library/Logs/RemoteMic/runtime.log`、本机 UserDefaults

## Observations

- 截图所选 RC001 的菜单键单击为 `openCmux`，双击为 `openCustomApplication`，目标 Profile 为 Paseo。
- 2026-08-09 15:40Z 的历史日志记录了同一配置的菜单键单击、双击、APP 打开以及后续聚焦结果，说明动作解码和手势识别曾正常执行。
- Paseo 在部分历史操作中记录 `APP FOCUS failed ... reason=target_not_focused`，但这发生在 `HID BUTTON` 和 `APP ACTION opened` 之后，不等于按键事件丢失。
- 当前 16:38Z 启动后的日志包含两只遥控器 BLE Ready 和一个 HID discovery 连接，但用户反馈对应时段没有任何 `HID BUTTON button=menu` 记录。
- 当前两个 `RemoteDeviceProfile` 的 `hidFingerprint` 均为空。
- `startHIDDiscoveryIfNeeded()` 只创建一个 discovery `HIDRemoteMonitor`；该监听器的 `deviceDidMatch` 在选中第一个 `activeDevice` 后忽略其他设备。
- IOHIDManager 会把其他匹配设备的报告也送到回调，但 `handleReport` 要求报告设备指纹必须等于 discovery 监听器随机占用的 `deviceFingerprint`，因此另一只未绑定遥控器无法用第一次按键完成绑定。
- 自动化手势测试已经覆盖菜单键单击和双击，均通过；这与“报告在手势识别之前被过滤”的边界一致。

## Hypotheses

### H1: 单个 discovery 监听器过滤了未绑定的第二只遥控器（ROOT HYPOTHESIS）

- Supports：两个 Profile 均无 HID 指纹；只有一个 discovery 监听器；当前日志无菜单键动作；报告过滤要求与随机首个设备指纹一致。
- Conflicts：历史上同一动作曾成功，但当时可能已经监听到用户实际操作的那只设备，不能证明另一只未绑定设备也可用。
- Test：构造 discovery 已占用指纹 A、实际报告来自指纹 B 的最小用例；旧逻辑应拒绝 B，修复后 discovery 应采用 B 并继续处理。

### H2: 菜单键手势状态因遗漏 release 卡死

- Supports：单击和双击共用同一个按键状态机，遗漏 release 可能使两者一起异常。
- Conflicts：当前时段完全没有 `HID BUTTON` 记录；既有 36 组合硬件时序测试覆盖菜单键单击、双击和长按并通过。
- Test：回放 press、遗漏 release、下一轮 press/release，检查状态能否恢复以及是否产生动作。

### H3: APP 已打开但输入框聚焦失败，被感知为按键失效

- Supports：Paseo 历史日志出现 `target_not_focused`。
- Conflicts：只能解释双击 Paseo，不能解释菜单键单击 cmux；当前时段连 `HID BUTTON` 与 `APP ACTION opened` 都没有。
- Test：直接执行两个已保存动作并分别核对 APP 激活和最终聚焦日志。

## Experiments

- 先加入最小失败用例：模拟 discovery 已被系统首先枚举的遥控器 A 占用，而真实报告来自用户按下的遥控器 B。旧实现调用 `acceptsReport(reportingFingerprint: "pressed-remote", activeFingerprint: "first-enumerated-remote")`，测试稳定失败。
- 检查现有手势回归：菜单键单击、双击和自动分配后首个按键不被消耗的测试均通过，排除动作配置与双击状态机本身。
- 修复后改为验证报告路由决策：未绑定 discovery 接受第一份真实报告；已绑定 monitor 拒绝其他设备；已被其他 monitor 绑定的 fingerprint 仍被 discovery 排除。

## Root Cause

`deviceDidMatch` 在用户尚未按键时就把单个 discovery monitor 绑定到 IOHIDManager 首先枚举到的设备，并写入 `deviceFingerprint`。之后 `handleReport` 只接受与该 fingerprint 相同的报告。两只 Profile 都没有 HID fingerprint 时，用户操作另一只遥控器的报告会在解析按键和手势之前被丢弃，所以菜单键的单击与双击会同时无响应，且日志中没有 `HID BUTTON`。

## Fix

- 未绑定 discovery monitor 在 `deviceDidMatch` 阶段不再抢占系统首先枚举的设备。
- 第一份真实输入报告到达时，根据报告来源 fingerprint 采用对应物理遥控器，并在同一份报告中继续完成 Profile 注册、动作识别和执行，不消耗首次按键。
- Profile 绑定完成后继续沿用现有逻辑创建新的 discovery monitor，处理剩余未绑定遥控器。
- 已绑定 monitor 仍只接收自身 active fingerprint；discovery 仍拒绝已被其他 monitor 占用的 fingerprint，没有放宽多设备隔离。

## Validation

- 旧失败复现：`swift test --filter diagnosticDiscoveryAcceptsTheRemoteThatWasActuallyPressed`，修复前 1 项失败。
- 修复后专项验证：`swift test --filter RemoteButtonsTests`，80 项通过，覆盖 discovery 路由、已绑定隔离、首个按键不被消耗、菜单键单击/双击手势、动作持久化及快捷键执行。
- 完整自动化：`swift test` 155 项通过；`./scripts/test.sh` 42 项通过；Release 构建及 `./scripts/verify-app.sh` 通过；`git diff --check` 通过。
- 本机 UI 回归：启动本次 `dist/Remote Mic.app`，进入按键页并打开菜单键单击编辑，确认固定组合键完整显示、“禁用按键”Switch 位于关闭按钮左侧、“打开具体 APP”默认收起且可展开，当前 cmux 选择在展开后仍正确显示。
- 双遥控器真机复验：用户完成本轮实际功能测试并确认全部通过，菜单键单击、双击及对应 APP 动作均恢复正常。
- 自动化边界：纯函数和硬件事件模拟用于持续回归路由决策及首份报告进入动作层；真实 IOHIDDevice 枚举顺序已由本轮用户真机验收覆盖。
