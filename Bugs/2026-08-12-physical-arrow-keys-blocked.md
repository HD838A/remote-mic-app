# Remote Mic 运行期间 MacBook 实体方向键偶发失效

- 时间：2026-08-12
- 状态：已确认代码风险，未修复
- 影响范围：macOS 正式版 1.8.3；Remote Mic 运行且自定义按键映射开启；小米遥控器处于非独占的兼容监听模式
- 功能点：HID 遥控器监听、原始键盘事件抑制、方向键映射
- 简单描述：Remote Mic 运行期间，MacBook Pro 实体键盘的方向键偶发无响应；小米遥控器方向键仍然可用，退出 Remote Mic 后实体方向键恢复。
- 原始记录：用户反馈；`v1.8.3` 标签代码检查。未取得用户现场日志，未在本机使用正式版安装包与真实遥控器复现。

## 用户反馈

用户使用正式版 1.8.3 时发现：有时保持 Remote Mic 运行，会导致 MacBook Pro 实体键盘方向键失效，上下方向键按下没有反应；此时小米遥控器的上下方向键仍可正常工作。退出 Remote Mic 后，实体键盘立即恢复。

## Observations

- 反馈只发生在 Remote Mic 运行期间，退出 App 后恢复，问题范围指向 App 进程中的 HID 监听或全局键盘事件过滤器。
- 遥控器方向键仍能执行，说明遥控器报告处理和 Remote Mic 合成动作没有整体停止。
- `v1.8.3` 的 `KeyboardEventSuppressor` 使用 session 级 CGEvent tap 监听全局 `keyDown`、`keyUp` 和系统按键事件。
- 遥控器在兼容监听模式下按下方向键时，`HIDRemoteMonitor.process(usages:)` 会调用 `eventSuppressor.arm(button:edge:.down)`；只有后续 HID 报告产生 `released` 差集时才调用 `.up`。
- `KeyboardEventSuppressor` 按键码维护 `heldEventCounts`。只要某方向键计数大于零，所有相同键码的 `keyDown` 都会被抑制。该判断没有区分事件来自小米遥控器还是 MacBook 实体键盘。
- 上、下、左、右方向键分别使用 macOS 键码 `126`、`125`、`123`、`124`，遥控器原始事件与实体键盘事件因此会命中同一描述符。
- `HIDRemoteMonitor.resetInputState()` 在设备移除、停止监听或权限失效时清理自身的 `activeUsages`，但不向共享 `KeyboardEventSuppressor` 补发仍按住按键的 `.up`。
- `KeyboardEventSuppressor.stop()` 会清空 `heldEventCounts`，与“退出 Remote Mic 后实体键盘立即恢复”的现场边界一致。
- 现有测试 `nativeKeyAutoRepeatIsSuppressedUntilEveryRemoteReleases` 只验证正常收到 `.up` 后恢复，没有覆盖松开报告丢失、按住期间断连或 HID 状态重置。

## 复现状态

尚未完成真实硬件复现。根据用户描述，建议后续使用以下条件复现：

1. 安装并运行正式版 1.8.3。
2. 开启自定义按键映射和所需的输入监控、辅助功能权限。
3. 确认日志中遥控器处于 `HID CONNECTED mode=monitored` 或其他非独占兼容路径。
4. 按住一个遥控器方向键，在松开、遥控器断连、休眠唤醒或报告链路抖动附近反复测试。
5. 在 Remote Mic 继续运行时按 MacBook 实体键盘的相同和不同方向键。
6. 退出 Remote Mic，确认失效按键是否立即恢复。

错误结果：某个实体方向键在遥控器已经松开后仍被持续拦截。

正常边界：未触发卡住的其他按键仍可用；退出 App 后所有实体按键恢复。

## 日志状态

本次没有用户现场日志，无法确认具体发生时间、设备模式、最后一次 HID pressed/released 报告或断连顺序。后续需要收集问题发生前后的日志，重点核对：

- `HID CONNECTED mode=...`
- 最后一条 `HID BUTTON button=...`
- `HID DISCONNECTED`、权限失效或 monitor 重建事件
- 问题发生后是否缺少对应方向键的 release 状态

当前日志不会直接打印 `heldEventCounts`，因此日志只能辅助确认事件顺序，不能单独证明过滤器内部计数已经卡住。

## Hypotheses

### H1：遥控器松开报告丢失后，方向键在全局过滤器中保持为按下状态（主要假设）

- Supports：`heldEventCounts` 没有超时；相同方向键的全部 `keyDown` 都会被抑制；退出 App 会清空状态；遥控器合成事件带有 marker，可以绕过过滤器，因此遥控器仍可用。
- Conflicts：没有用户现场日志或真实硬件复现证明此次现场确实丢失了 release 报告。
- Test：在 1.8.3 代码上模拟 `.down` 后不发送 `.up`，确认 MacBook 同键码事件持续被 `handle` 返回 true；再通过真实遥控器断连或报告回放验证同样状态。

### H2：按住期间设备断连或 monitor 重置只清理 HID 状态，没有释放过滤器状态

- Supports：`resetInputState()` 清空 `activeUsages`，但没有通知共享 suppressor；设备移除、stop 和权限失效均会走该路径。
- Conflicts：用户没有说明问题前是否发生遥控器断连、休眠或权限变化。
- Test：模拟非独占设备 `.down` 后调用 `disconnectSimulatedDevice()` 或 monitor stop，确认 suppressor 是否仍拦截实体同键码事件。

### H3：系统事件来源无法被当前键码级过滤器区分，实体键盘事件被误认为遥控器原始事件

- Supports：过滤器描述符只有键码和 down/up 边沿；遥控器与内置键盘方向键使用相同键码。
- Conflicts：正常 press/release 时拦截窗口很短，只有过滤状态异常残留时才会形成持续用户影响。
- Test：在 suppressor 已 armed 的状态分别构造不同 event source 的同键码事件，确认当前实现全部抑制。

## 当前结论

正式版 1.8.3 的代码中存在能够产生该反馈的真实状态泄漏：非独占遥控器方向键进入 `heldEventCounts` 后，只有对应 release 才会解除；release 丢失或 monitor 在按住期间重置时，过滤器可能继续拦截 MacBook 实体键盘的相同方向键。该代码路径能够解释“实体键盘失效、遥控器仍正常、退出 App 后恢复”的完整现象。

由于尚未取得用户现场日志或完成正式版 1.8.3 真机复现，具体现场触发条件仍标记为待确认；不能把“release 丢失发生于断连、休眠或某个固件时序”写成已证明事实。

## 修复状态

未修复。本提交只建立 Bug 记录和索引，没有修改 `KeyboardEventSuppressor`、`HIDRemoteMonitor`、蓝牙、音频、设置、测试或其他业务代码。

后续修复必须重新遵循：正式版复现或事件回放复现 → 核对日志 → 用最小实验确认状态泄漏 → 实施最小修复 → 重跑原始复现和稳定基线。修复方案尚未在本记录中确定。

## 验证边界

- 已完成：检查 `v1.8.3` 标签的事件过滤器、HID 生命周期和已有回归测试。
- 未完成：用户现场日志核对、真实 1.8.3 App 复现、真实遥控器断连/休眠复现、修复验证。
- 本次没有运行产品测试或构建，因为没有修改业务代码；仅对 Markdown 和 Git diff 做结构及空白检查。

