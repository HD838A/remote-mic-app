# Issue #137：RC003 丢失松开报告后实体左右方向键失效

- 时间：2026-08-21
- 状态：已修复，本地自动化通过，PR CI 与真实 RC003 丢包场景待验收
- 影响范围：macOS；RC003 处于非独占 `HID CONNECTED mode=monitored` 路径
- 原始反馈：<https://github.com/HD838A/remote-mic-app/issues/137>

## 复现证据

用户现场环境为 macOS 26.5.2（Apple Silicon）与小米蓝牙遥控器 RC003。连接日志包含：

```text
HID CONNECTED mode=monitored
seize_error=-536870207
```

可重复触发条件是：遥控器左键或右键产生 `down`，但蓝牙链路没有交付对应 `up`；随后外接键盘和 MacBook 内置键盘的同方向键均无响应，上下键仍正常，退出并重新启动无线麦后恢复。

本地没有真实 RC003，无法主动制造固件或蓝牙层丢包。安装 Xcode 26.3 后，新增回归已直接驱动生产 `KeyboardEventSuppressor` 完成确定性事件回放；Issue 的真实设备复现、当前状态机的代码路径和该回放共同作为复现依据。自动化仍不能表述为本机真机复现。

## 日志结论

Issue 只提供连接模式与 seize 失败码，没有提供问题发生时间段的完整 `runtime.log`，因此无法确认最后一条 `HID EDGE`、是否出现其他报告或确切丢包次数。

连接日志足以确认设备走非独占 monitored 路径；该路径会启用 `KeyboardEventSuppressor`。日志当前不打印 `heldEventCounts`，所以不能仅凭现有日志证明内部计数为 1，需结合代码状态机判断。

## 代码检查与根因

`HIDRemoteMonitor.process(usages:)` 在非独占模式收到遥控器 `down` 时调用 `eventSuppressor.arm(..., .down)`，只有后续报告的 usage 差集出现松开时才调用 `.up`。

修复前 `KeyboardEventSuppressor` 对每次 `.down` 增加 `heldEventCounts`，但没有过期或未配对首击恢复机制。`handle(...)` 只要发现相同 keyCode 的 held 计数大于零，就无条件吞掉所有 `keyDown`，没有区分遥控器自动重复与另一块物理键盘的新首击。丢失 `.up` 后，计数只能由 monitor 重置或 App 退出清除，这与“左右键失效、上下正常、重启恢复”的边界完全一致。

根因置信度：高。现场缺少完整 HID 边缘日志，不能证明具体丢包发生在哪一层，但生产状态机确实允许单次缺失 `.up` 永久阻塞相同 keyCode。

## 最小实验

新增回归序列直接驱动生产 suppressor：

1. `arm(left, .down)` 后交付遥控器原始首击，必须被抑制；
2. 不调用 `.up`，交付带 autorepeat 标记的遥控器重复事件，仍必须被抑制；
3. 交付不带 autorepeat 标记的实体键盘新首击，必须通过并清除陈旧状态；
4. 同一实体按键随后的 autorepeat 也必须通过。

在 `origin/main` 的无条件 held 判断下，第 3、4 步会继续被吞掉。修复分支上的该回归已通过；PR CI 仍需由上游仓库批准 fork workflow 后执行。

## 修复

- `.down` 与 `.up` 都进入原有 180ms pending 配对窗口，遥控器的原始首击按 HID 边缘关联抑制。
- 已配对首击之后，仅在 held 状态下抑制带 `keyboardEventAutorepeat` 标记的键盘重复事件，保持遥控器长按行为。
- held 状态下遇到未配对、非 autorepeat 的新键盘首击时，将其视为新的物理输入，清除该原生按键的陈旧 held 状态并放行。
- 保持 system-defined 媒体键、多遥控器计数、正常 `.up`、断连重置、合成事件 marker 和现有 180ms 窗口不变。

## 验证

已执行：

```text
swift test --filter RemoteButtonsTests
swift test --filter HardwareSimulationIntegrationTests
scripts/test.sh
```

本地验证结果：

- `swift test --filter RemoteButtonsTests`：89 项通过，包含缺失 release 自愈及多遥控器 autorepeat 基线。
- `swift test --filter HardwareSimulationIntegrationTests`：本地未配置可选 `REMOTE_MIC_HARDWARE_SIMULATION_PATH`，因此匹配 0 项，不能计为硬件模拟通过。
- `scripts/test.sh`：42 项通过，随后 Swift Package 构建成功。
- `git diff --check`：通过。

没有执行真实 RC003、真实蓝牙丢包、CGEvent tap 或内置/外接键盘验收；PR CI 仍等待上游批准 fork workflow。

真机验收必须覆盖：正常短按与长按左右键、丢失 release 后第一次实体键盘首击、内置与外接键盘、两只遥控器、断连与重连，并保留问题时间段完整日志。
