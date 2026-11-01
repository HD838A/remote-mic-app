---
title: 按键手势学习的双击间隔被压缩到 0–1 ms
template: doc
---
## 状态与范围
时间：2026-11-01。状态：已修复，等待真实遥控器复验。
范围：`Sources/RemoteMic/HIDRemoteMonitor.swift` 的报告时间戳来源、`Sources/RemoteMic/BridgeAppModel.swift` 的手势学习入口、`Sources/RemoteMic/RemoteButtonGestureLearning.swift` 的双击间隔判定。不涉及界面文案、手势阈值默认值、长按识别或发布流程。

## 现象与证据
按键页「学习你的单击、双击和长按」在 2/3 步骤稳定给出 1 ms，同一次会话里还出现过 0 ms；同一轮的单击 284 ms、长按 1017 ms 都合理。

`runtime.log` 里同一套 HID 链路的 `since_release_ms`（松手→再按下）共 20 次采样，最短 59 ms，从未出现个位数毫秒；手势学习的 `double_ms` 历史值为 76 / 96 / 168 / 172 ms。用户不可能在 1 ms 内完成松手再按下，所以异常只在测量侧，不在手指侧。

## 根因
两个缺陷叠加，缺一不会出现 0/1 ms。

1. **时间戳取在处理时刻，而报告要排队到主线程才处理。** `HIDRemoteMonitor.handleReport` 先在报告线程做原生事件预登记，再用 `DispatchQueue.main.async` 把解析交给主线程。手势学习原先在 `handleButtonGestureLearning` 里另读一次 `ProcessInfo.processInfo.systemUptime`：第一次松手会触发步骤切换（状态改写、卡片重绘、日志写入），这段时间里排队的下一条报告被处理时，读到的时刻已经贴近第二次按下，`松手→再按下` 被压进同一毫秒。系统本来就提供硬件到达时间戳（`IOHIDReportWithTimeStampCallback` 的 `timeStamp`），原实现注册的是不带时间戳的回调版本，等于把它丢掉了。
2. **`max(0, …)` 把负值静默变成 0。** 时间戳一旦乱序或压缩，负的间隔不会报错，直接写成 0 ms 显示给用户，现场只看到「0 ms」这个不可能值，没有留下可判断的记录。

## 修复
- 改用 `IOHIDManagerRegisterInputReportWithTimeStampCallback`，在报告回调里把 mach 绝对时间按 `mach_timebase_info` 换算成与 `DispatchTime.uptimeNanoseconds` 同刻度的纳秒，随报告一路传到 `onRuntimeButton` 和手势学习器；`HID EDGE` 的 `since_release_ms` / `hold_ms` 也改用同一时刻，诊断口径统一。
- `RemoteButtonGestureLearner` 增加 `minimumDoubleClickIntervalMilliseconds = 20`：松手→再按下短于它时按重复边沿处理，丢弃这次按下、重新从该次按压计数，既不写入学习结果也不推进到长按；阈值只用于排除手指不可能完成的间隔，正常快速双击（40 ms 量级）仍可测量。
- 丢弃次数记入 `RemoteButtonGestureLearningStatus.discardedDoubleClickEdges`，并由 `BridgeAppModel` 写成 `phase=measured result=discarded reason=implausible_double_click_interval` 诊断行，异常不再无声。

## 验证
- 新增 5 项自动化：1 ms 间隔被丢弃且随后真实双击仍能测出、乱序负间隔不再写成 0、两对抖动边沿被吸收且不跳过双击步骤、报告时间戳优先于处理时刻、mach tick 换算。
- `swift test --disable-keychain --disable-sandbox`：1175 项全部通过（含此前因本机缺 `ripgrep` 而失败的一项）。
- `bash scripts/verify-repository-governance.sh`：通过。
- 反向对照：把 20 ms 下限改成 0 后重跑，新增用例出现 9 处断言失败——1 ms 和 5 ms 的重复边沿被当作有效双击写进结果、步骤被提前推进到长按；恢复后全部通过。

## 未覆盖边界
真机复验尚未执行：需要在 rc003 上重跑一次学习，确认 2/3 步骤给出的是人类量级的间隔，并且日志里不出现 `result=discarded`。本修复不改变手势阈值默认值，也不涉及语音键路径。
