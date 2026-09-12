# 1.9.18「语音键模拟 Fn 点按」自动关闭

- 日期：2026-09-01
- 反馈版本：1.9.18（Build 171）
- 影响范围：macOS；RC003；Typeless 等点按 Fn 开始和结束的语音工具
- 当前状态：候选修复完成；等待 PR CI 与 RC003/Typeless 真机验收

## Observations

1. 用户截图显示“语音键模拟 Fn 点按”曾处于开启状态；反馈为 1.9.18 中该开关经常自行关闭。截图不包含发生时间、遥控器连接状态或现场日志。
2. `AppSettings.voiceFnTapModeEnabled` 的 `didSet` 会立即写入 UserDefaults，因此运行时写成 `false` 会永久覆盖用户偏好，而不只是临时改变界面。
3. `BridgeAppModel.startIfNeeded()` 在启动时立即调用 `applyHIDSettings()`；此时 RC003 可能尚未唤醒，或者 BLE Ready 早于 macOS 枚举出对应 HID service。
4. `applyHIDSettings()` 在请求 Fn 点按且 neutralize 失败时，无论 `matchedServiceCount` 是 0 还是存在真实写入失败，都会把 `voiceFnTapModeEnabled` 写成 `false`。
5. 用户主动开启时走 `enableVoiceFnTapMode()`；该路径同样在 `matchedServiceCount == 0` 时立即把开关写回 `false`。
6. 仓库已有真机记录证明 BLE Ready 与 HID service 枚举存在时序差：曾出现 `VOICE FN MAPPING ... matched=0`，500 ms 后恢复为 `matched=1 applied=1`。
7. 本机现存 1.9.18 日志不是反馈用户现场，没有捕获该用户开关从 true 变为 false 的时间段，因此不能用来判定其具体一次触发来源。

## Hypotheses

### H1：暂时缺少 RC003 HID service 被当成永久配置失败（ROOT HYPOTHESIS）

- Supports：启动、BLE Ready、唤醒和用户主动开启都会立即尝试 neutralize；两条失败分支均不区分 `matched=0` 与真实写入失败，并持久化 `false`。仓库已有 HID 晚到真机日志。
- Conflicts：缺少反馈用户同一时间段的 `runtime.log`，无法证明其每次都命中 `matched=0`。
- Test：在现有 HID 恢复源码回归测试中要求出现 Fn 点按专用的 `mode_pending_mapping reason=no_matching_service` 分支；旧代码应失败。

### H2：辅助功能权限被撤销或签名升级后权限暂时不可用

- Supports：`applyHIDSettings()` 和 `enableVoiceFnTapMode()` 在 Accessibility 不可信时会关闭偏好；Fn 软件注入需要该权限。
- Conflicts：反馈只说明“经常自动关闭”，没有权限弹窗或系统设置证据；仓库代码同时存在更直接的 `matched=0` 自动关闭路径。
- Test：收集现场 `HID PERMISSIONS ... accessibility=false`；自动化继续验证权限不足的既有门禁，不在本修复中改变权限策略。

### H3：Fn 开始或结束事件注入失败触发安全回退

- Supports：`VoiceFnTapSessionController` 的 `start_tap_failed` / `stop_tap_failed` 会调用 `handleVoiceFnTapFailure` 并关闭偏好。
- Conflicts：该路径会写入明确的 `VOICE FN TAP failed reason=...`；现有反馈未提供此日志，且 `CGEvent` 创建失败相对少见。
- Test：现场日志搜索 `VOICE FN TAP failed`；现有控制器测试继续覆盖注入失败后的安全回退。

## Experiment

计划：向现有 `hidRecoveryReappliesTheCurrentVoiceKeyModeWithoutForcingFn` 测试临时增加一条源码断言，要求 `applyHIDSettings()` 包含 `VOICE FN TAP mode_pending_mapping reason=no_matching_service`。如果当前 main 测试失败，则确认 Fn 点按没有把“无 service”作为可恢复等待状态；实验后撤回临时断言。

结果：确认。`swift test --filter hidRecoveryReappliesTheCurrentVoiceKeyModeWithoutForcingFn` 在 `VoiceKeyModeTests.swift:238` 按预期失败，输出的完整 `applyHIDSettings()` 只有 Command 模式的 `mode_pending_mapping`，Fn 点按分支直接执行 `settings.voiceFnTapModeEnabled = false`。临时断言已撤回。

## Root Cause

1.9.18 及修复前 main 把 `voiceFnTapModeEnabled` 同时作为用户持久化意图和运行时有效状态；启动、重连、唤醒或用户主动开启时，只要 RC003 HID service 尚未枚举出来，代码就把可恢复的 `matched=0` 当成永久失败并持久化关闭开关。

## Fix

1. 在现有 `HIDMappingRecoveryPolicy` 中明确区分“没有枚举到匹配 service”和“已经存在目标但映射失败”。
2. `applyHIDSettings()` 遇到 `matched=0` 时保留 `voiceFnTapModeEnabled`，停用当前 Fn 点按会话，记录 `VOICE FN TAP mode_pending_mapping reason=no_matching_service`，并进入既有有限 HID 恢复。
3. 用户手动开启 Fn 点按时应用同一策略：HID 尚未出现则保持开关开启并等待；目标已出现但写入失败仍沿用原有安全回退，关闭设置并恢复硬件 Fn。
4. 不改变辅助功能权限门、Fn 注入失败回退、切换 Command 时关闭 Fn 点按、完整目标事务回滚或普通硬件 Fn 路径。

## Validation

- 修复前：临时回归断言使 `swift test --filter hidRecoveryReappliesTheCurrentVoiceKeyModeWithoutForcingFn` 按预期失败。
- 修复后：同一命令通过，覆盖 `matched=0` 保留、存在目标失败不保留，以及自动重应用和手动开启两个接线入口。
- 定向回归：`VoiceKeyModeTests` 15 项、`RemoteVoiceFunctionMapperTests` 12 项、`VoiceFnTapSessionControllerTests` 8 项、`BluetoothLifecycleTests` 17 项全部通过。
- `swift test`：435 项、37 个 suite 全部通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：44 项项目自检全部通过。
- `swift build -c release`：通过；只有仓库既有的 macOS API deprecated warning。
- 真机边界：尚未使用真实 RC003 执行“遥控器休眠 → 先启动 App → 后唤醒遥控器 → Typeless 第一次语音”；不能把自动化表述为第三方 App 真机验收。
