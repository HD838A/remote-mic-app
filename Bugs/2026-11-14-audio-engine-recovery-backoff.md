# 音频引擎重绑后误报可用并在活跃语音中持续丢包

- 时间：2026-11-14
- 状态：候选修复完成；自动化通过，真实 RC003、豆包和蓝牙耳机复测待完成
- 影响范围：蓝牙遥控器语音、手机/Watch 语音、Apple Remote 语音、Chromecast 语音中所有需要临时重绑虚拟音频出口的会话
- 功能点：`VirtualAudioOutput.configureAsync`、`BridgeAppModel` 音频恢复与语音启动
- 关联 Issue：#1035
- 关联历史记录：[`2026-09-05-idle-audio-rebind-loop.md`](2026-09-05-idle-audio-rebind-loop.md)
- 命名说明：现场设备名是旧安装的 `MiRemoteV 2ch`；新安装同一设备显示为 `SayAll`，稳定 UID 仍为 `MiRemoteV2ch_UID`。本文保留现场名称以便对照日志。

## 问题

#1035 在现场 1.9.21（build 174）中记录到：虚拟音频引擎重绑后 `engine_running=false`，但重绑仍返回成功；随后约 1 Hz 重复 `AUDIO ENGINE configuration_changed → AUDIO RECOVERY → AUDIO REBIND`，语音会话的 `enqueue_failures` 恒等于 `batches`，豆包只收到静音。

现场关键日志：

```text
AUDIO READY target={MiRemoteV 2ch id=94} state={engine_running=false ...}
AUDIO REBIND finished reason=recovery_engine_configuration_change success=true ... ready=false
AUDIO ENGINE configuration_changed generation=59
AUDIO RECOVERY begin id=20 reason=engine_configuration_change
AUDIO WRITE rejected count=207 reason=playback_not_ready state={engine_running=false ...}
ATVV STREAM summary trace=15 ... batches=156 ... enqueue_failures=156
```

最新 `origin/main`（`db4e7b1e`）已经修掉其中一部分：

- 默认输入变化不再触发恢复；
- 已绑定、空闲、无待播尾包时忽略自造的 `engine_configuration_change`；
- `AUDIO READY` 只在 `isReadyForTestTone` 通过后记录。

但源码仍保留两条导致用户可见 100% 丢包的路径：

1. **重绑完成态误报**：`configureVirtualAudioOutput` 已经算出 `isAudioOutputReady`，日志也写成 `success=true ready=false`，但 completion 仍传递 `configured`，没有合并当前就绪状态。语音启动的异步重绑拿到 `true` 后，会把配置期间缓存的 PCM 送入一个已经停止的引擎；`VirtualAudioOutput.enqueue` 对每个批次返回 `playback_not_ready`，会话继续、输入法只收到静音。
2. **恢复失败没有重启或退避**：恢复完成只记录 `result=degraded`，随后 `audioRecoveryWorkItem = nil`。下一次尝试只能依赖另一条 `engine_configuration_change`；活跃语音时策略明确要求恢复，而调度仍是固定 1 秒去抖。重绑自身触发的配置通知可以再次排入恢复，形成约 1 秒一圈的活跃语音循环。

## 复现边界

- 现场证据来自 1.9.21 build 174 的完整日志，触发条件为豆包占用虚拟设备、显式选择兼容麦克风以及系统默认输入切换。
- 2.0 源码已关闭空闲循环和默认输入入口，因此普通静置不再复现原日志形态；本次修复按源码控制流确认残留路径，并新增纯逻辑回归测试。
- 尚未在最新候选包上完成真实 RC003、豆包、蓝牙耳机和虚拟设备占用组合复测；没有真机结果前不标记为已验收。

## 修复

### 1. 重绑完成必须同时满足配置成功与当前就绪

新增 `AudioConfigurationCompletionPolicy.reportsReady(configured:readyNow:)`。`configureVirtualAudioOutput` 在 completion、诊断事件和测试音状态中统一使用该结果：

```swift
let reportsReady = AudioConfigurationCompletionPolicy.reportsReady(
    configured: configured,
    readyNow: self.isAudioOutputReady
)
completion(reportsReady)
```

这样即使音频队列返回成功、但主线程完成时引擎已经停止，异步语音启动也会收到 `false`，不再把缓存音频送入死引擎。

### 2. 恢复失败进入有界退避

新增 `AudioRecoveryBackoffPolicy` 与 `AudioRecoveryBackoffState`：

- 重试延迟为 2、4、8 秒，共 3 次；
- 初始恢复失败后立即排入第一次重试；
- 重试仍失败时继续下一档；
- 输出恢复健康、新的语音启动、系统恢复或真实硬件变化会重置退避；
- 重绑进行中到来的自造 `engine_configuration_change` 记录为 `recovery_in_flight` 并忽略，避免完成回调尚未返回时被再次排入；
- 退避期间到来的自造 `engine_configuration_change` 记录为 `retry_pending` 并忽略，不再重置节奏；
- 新的非恢复重绑（语音启动、测试音、设置变更、系统恢复）会使旧恢复失效，避免迟到的恢复完成再次重绑；
- 3 次重试仍失败时记录 `retry_exhausted`，当前会话内不再接受自造配置变化触发的恢复；新的语音会话或真实硬件变化会重新武装。

退避只在仍有活跃语音或待播尾包时执行；空闲、系统挂起、Mac 麦克风会话或无虚拟音频需求时跳过并复位，避免把空闲用户重新拉回重绑循环。

### 3. 保持现有完整性语义

- 不 flush、不丢弃已排队音频；
- 不改变 `AudioEngineConfigurationChangePolicy` 对空闲、活跃、待播尾包和绑定状态的判定；
- 不改变语音键按下/释放时序、ATVV 解码、录音或路由；
- 新增日志只包含稳定枚举、短生命周期 attempt 编号、延迟、待播计数和既定诊断状态。

## 验证

自动化：

- `swift test --disable-keychain --filter AudioConfigurationChangeRecoveryTests`：11 项通过。
- `swift test --disable-keychain`：1420 项 / 104 suites 通过。
- `scripts/test.sh`：`RESULT passed=48 failed=0`。
- `scripts/check-repository-boundaries.sh`：`REPOSITORY BOUNDARY PASS`。
- `git diff --check`：通过。

新增回归断言：

- 配置成功但当前不就绪时必须报告未就绪；
- 退避按 2/4/8 秒递增并在 3 次后耗尽；
- 恢复健康后重置退避；
- 重复活跃失败只能消耗有限重试预算，不能无限维持现场循环。

## 本地包 build 361 复验记录

2026-11-14 使用本地 public 包 `2.0.0 (361)`、源码 `db4e7b1e`（dirty）在真机 RC003 上执行：

- 7 次蓝牙语音会话全部 `enqueue_failures=0`，`engine_running=true`、`player_playing=true`、`bound_to_selected=true`；没有 `AUDIO WRITE rejected`。
- 空闲时 `doubao_device_selected` 重绑 1 次，成功；没有 1 秒级 `AUDIO REBIND begin` 连发。
- 切换系统默认输入 2 次，均记录 `AUDIO RECOVERY ignored ... detail=properties=default_input explicit_output_unchanged`，符合 2.0 的既定行为。
- 设备列表变化 4 次（含 AirPods Pro 3 接入），触发的 `recovery_hardware_change` 均 `result=ready`，耗时 78–101 ms。
- 全程 `AUDIO ENGINE configuration_changed` 0 次、`AUDIO WRITE rejected` 0 次、`retry started` 0 次、`enqueue_failures == batches` 0 次。

结论：这次运行证明**健康路径没有回归**，但没有触发失败重绑，因此没有覆盖本次新增的退避和循环抑制路径。不能把这轮结果当作 #1035 故障路径的现场验收。

### 2026-11-14 活跃语音中重绑（PID 59968）

重新启动同一 build 361 后，使用后台 Accessibility 点击在语音进行中触发 `选择 MiRemoteV 2ch`，不改变前台输入框：

- 语音会话 trace=1 于 `05:55:25.563` 接受，`05:55:28.316` 发生 `doubao_device_selected` 重绑，`05:55:28.400` 新引擎 ready；14.43 秒、`batches=920`、`enqueue_failures=6`（0.65%），`coverage_pct=95.6`。
- 第二次 trace=2 于 `05:57:19.286` 接受，`05:57:21.509` 发生 `doubao_device_selected` 重绑，`05:57:21.623` 新引擎 ready；12.51 秒、`batches=791`、`enqueue_failures=3`（0.38%），`coverage_pct=94.9`。
- 两次重绑窗口内各出现一次 `AUDIO WRITE rejected count=1 reason=playback_not_ready`；随后音频恢复，结束时 `engine_running=true player_playing=true`。
- 没有 `AUDIO ENGINE configuration_changed`、没有 `retry started`、没有 1 秒级重绑循环。
- 当次没有文字不是音频丢失：系统默认输入为 `Andy AirPods Pro 3`，豆包没有从 `MiRemoteV 2ch` 取音；日志 `default_input` 全程为 AirPods。需要把豆包麦克风明确选为 `MiRemoteV 2ch`/`SayAll`，或把系统默认输入切回该设备后复验文字。
- 两次会话都因为少量 `enqueue_failures` 被标记为 `audio_enqueue_failed`，trace=2 还出现 `TRANSCRIPT CAPTURE canceled reason=discontinuous_after_finish`。这是重绑瞬间少量批次失败触发的本地会话分类，不是整段 100% 丢包；但会让本地转写捕获放弃该会话，属于本次修复之外的残余体验问题。

结论：**活跃语音中正常重绑不会导致整段 100% 丢包，也不会进入 1 秒循环**；两次重绑都成功，所以没有触发退避重试。失败重绑的 `retry started` 路径仍未现场覆盖。少量重绑窗口丢批次仍会把会话标记为 `audio_enqueue_failed` 并取消本地转写捕获，需要单独评估是否在重绑期间缓冲而非丢弃。

未完成：

- 真实 RC003 + 豆包 + 蓝牙耳机 + `MiRemoteV 2ch` 被占用组合下的现场复测；
- 真实设备拔插、睡眠唤醒和语音会话中切换默认输出的端到端验证；
- 连续快速会话和 60 秒长录音回归；
- 需要至少一次活跃语音中的失败重绑，才能看到 `retry started`、`retry_pending` 和 `retry_exhausted`；
- 需要把豆包麦克风明确指向 `MiRemoteV 2ch`/`SayAll` 后，补一次“重绑后文字仍出现”的验证。

这些边界没有真机结果前只能称为候选修复。

## 验证日志

新增事件：

```text
AUDIO RECOVERY ignored ... recovery_in_flight retry_attempt=N
AUDIO RECOVERY ignored ... retry_pending retry_attempt=N
AUDIO RECOVERY ignored ... retry_exhausted retry_attempt=N
AUDIO RECOVERY retry started attempt=N delay_ms=2000|4000|8000 reason=...
AUDIO RECOVERY retry completed result=ready|degraded attempt=N ...
AUDIO RECOVERY retry_skipped reason=virtual_audio_inactive|system_suspended|mac_microphone_active|no_active_audio attempt=N
AUDIO RECOVERY retry_exhausted reason=... attempts=3
```

判定重点：

- 失败重绑后不应再出现同一秒级的连续 `AUDIO REBIND begin`；应看到递增的 `retry started delay_ms`；
- 语音会话结束时 `enqueue_failures` 应低于 `batches`，最好为 0；
- 若仍出现 `enqueue_failures == batches`，保留日志并检查是否在 `retry_exhausted` 后仍有自造 `configuration_changed` 被接受。
