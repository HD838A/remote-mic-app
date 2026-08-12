# Remote Mic 运行期间 MacBook 实体方向键偶发失效

- 时间：2026-08-12
- 状态：已修复，自动化验证通过，等待真机复验
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
- 进一步检查发现 `startRepeatIfNeeded` 的每次 App 定时连发也会再次调用 `.down`：一次真实按下经过数次连发后，`heldEventCounts` 会被累加多次，但真实松开只产生一次 `.up`。

## 复现状态

已使用生产 `KeyboardEventSuppressor` 完成确定性失败复现：依次登记两次 `.down`（一次物理按下和一次定时连发）后只登记一次 `.up`，MacBook 同键码的测试事件仍被 `handle` 返回 `true`。该失败不依赖真实硬件，稳定证明计数不平衡。真机仍建议按以下条件复验：

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

### H0：App 定时连发重复登记 `.down`，一次真实 `.up` 无法归零（已确认根因）

- Supports：方向键在 350ms 后每 100ms进入 App 定时连发；定时闭包每次都调用 `eventSuppressor.arm(.down)`；真实 HID release 只调用一次 `.up`。
- Conflicts：无。
- Test：按 `.down → .down → .up` 驱动生产 suppressor；修复前实体上键事件仍被抑制，稳定失败。

### H2：按住期间设备断连或 monitor 重置只清理 HID 状态，没有释放过滤器状态

- Supports：`resetInputState()` 清空 `activeUsages`，但没有通知共享 suppressor；设备移除、stop 和权限失效均会走该路径。
- Conflicts：用户没有说明问题前是否发生遥控器断连、休眠或权限变化。
- Test：模拟非独占设备 `.down` 后调用 `disconnectSimulatedDevice()` 或 monitor stop，确认 suppressor 是否仍拦截实体同键码事件。

### H3：系统事件来源无法被当前键码级过滤器区分，实体键盘事件被误认为遥控器原始事件

- Supports：过滤器描述符只有键码和 down/up 边沿；遥控器与内置键盘方向键使用相同键码。
- Conflicts：正常 press/release 时拦截窗口很短，只有过滤状态异常残留时才会形成持续用户影响。
- Test：在 suppressor 已 armed 的状态分别构造不同 event source 的同键码事件，确认当前实现全部抑制。

## Experiments

1. 在现有 suppressor 测试中临时加入 `.down → .down → .up`，预期最终实体 `keyDown` 不应被抑制。修复前测试稳定失败，确认 H0；临时断言随后移入完整 HID 模拟回归。
2. 使用非独占模拟遥控器按下上键，推进调度器到 650ms 以执行多次连发，再发送一次松开；修复后实体上键恢复。
3. 再次按下上键但不发送松开，直接模拟遥控器断连；修复后 monitor 重置会补发一次 `.up`，实体上键恢复，确认 H1/H2 的生命周期风险得到覆盖。

## Root Cause

非独占 HID 方向键的 App 定时连发错误地把每次合成动作都登记为新的物理 `.down`，导致 `heldEventCounts` 多次增加、真实松开只减少一次；同时 monitor 重置没有释放仍按住的 usage，使残留计数可持续拦截 MacBook 实体方向键。

## 当前结论

正式版 1.8.3 的代码中存在能够稳定产生该反馈的状态泄漏：长按方向键进入 App 定时连发后，即使正常收到真实 release，也会因重复 `.down` 留下计数；release 丢失或 monitor 在按住期间重置还会形成第二条泄漏路径。它能够解释“实体键盘失效、遥控器仍正常、退出 App 后恢复”的完整现象。

尚未取得用户现场日志，因此不能确认用户当时是正常长按残留，还是叠加了断连、休眠或报告丢失；但修复已同时覆盖两条可证实风险。

## 修复状态

- 删除 App 定时连发闭包中重复登记 suppressor `.down` 的逻辑；一次物理按下只登记一次，连发次数不再改变 held 计数。
- `resetInputState()` 在清空 `activeUsages` 前，为非独占设备仍按住的已知按键补发 `.up`；设备移除、停止、权限撤销、切换模拟设备等既有重置路径均得到兜底。
- 保持独占模式、按键映射、350ms 首次连发延迟、100ms 方向键重复间隔和合成动作不变。
- 新增硬件模拟回归，覆盖全部 11 个具有原生 macOS 事件的遥控器按键：四个方向键、音量加减、确定、Home、菜单、TV 和关机。每个按键均验证正常松开、按住期间断连和双遥控器共享计数；返回键没有对应原生事件，单独验证不会进入抑制器。

本次修复遵循：事件回放复现 → 核对现有日志能力与事件路径 → 用最小实验确认状态泄漏 → 实施最小修复 → 重跑原始复现和稳定基线。

## 验证边界

- 已完成：修复前失败复现；硬件模拟套件直接驱动生产 monitor、调度器和 suppressor，覆盖 11 个原生按键的正常松开、断连释放和双遥控器共享状态，以及返回键不进入抑制器；既有 7 个连发按键、36 个手势、12 个原始按键和异常/断连基线均通过。
- 已完成：Apple Silicon 与 Intel 配置变体的完整 Swift Testing 各 234 项通过，`scripts/test.sh` 两种配置各 42 项通过。
- 已完成：非打包 Release 可执行文件分别通过 `arm64 / macOS 14.0` 与 `x86_64 / macOS 13.0` 交叉编译及架构检查。
- 待完成：真实 RC001/RC003 在 `HID CONNECTED mode=monitored` 下长按四个方向键后测试 MacBook 实体方向键；按住期间断开遥控器、休眠唤醒及权限撤销的真机复验。
- 自动化不能证明真实 CGEvent tap、固件 release 时序或用户最终键盘体验，发布前仍需最小真机门禁。
