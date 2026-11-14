# 音频配置变化恢复测试手册

## 适用范围

- 目标分支：包含 `Bugs/2026-09-05-idle-audio-rebind-loop.md` 和 `Bugs/2026-11-14-audio-engine-recovery-backoff.md` 修复的分支
- 覆盖改动：`AVAudioEngineConfigurationChange` 去抖后区分空闲自造变化与真实恢复需求；活跃语音、待播尾包、解绑和未知状态仍保留恢复；同一去抖窗口内真实硬件变化优先于后到的引擎通知；重绑完成态同时校验配置结果和当前就绪状态；恢复失败按 2/4/8 秒有界退避，耗尽后停止当前会话的自造通知重试
- 缺陷记录：[`Bugs/2026-09-05-idle-audio-rebind-loop.md`](../Bugs/2026-09-05-idle-audio-rebind-loop.md)、[`Bugs/2026-11-14-audio-engine-recovery-backoff.md`](../Bugs/2026-11-14-audio-engine-recovery-backoff.md)

## 测试前准备

1. 在设置里选定兼容虚拟麦克风：新安装为 `SayAll`，旧安装为 `MiRemoteV 2ch`。
2. 观察命令：

```
grep -E "AUDIO RECOVERY .*phase=(started|applying|completed)|configuration_changed" ~/Library/Logs/RemoteMic/runtime.log | tail -30
```

## 用例

### AC-01 空闲不再刷屏重绑（核心用例）

1. 连接遥控器，选定 `SayAll`（旧安装为 `MiRemoteV 2ch`），然后**什么都不做**，静置 5 分钟。
2. 统计：

```
grep "AUDIO RECOVERY .*phase=applying" ~/Library/Logs/RemoteMic/runtime.log | cut -c1-16 | uniq -c | tail -6
```

预期：`AUDIO RECOVERY ... phase=applying ... reason=engine_configuration_change` **不再以每分钟数十次的速率出现**。偶发的 `phase=completed result=ignored ... decision=still_bound_idle` 是正常的、期望的。

失败判定：`AUDIO RECOVERY ... phase=applying ... engine_configuration_change` 持续每分钟数十次；或日志文件几分钟内涨到 4MB 触发轮转。

> 参考数据：在同形态代码上做过同机对比，修复前 3 分钟约 144 次，修复后 0 次。本次上游版本请在你的日常使用环境确认一次，特别是**遥控器保持连接**的常驻状态。

### AC-02 真实拔插外接设备仍能及时恢复（须实测，代理未做）

这是本次改动最需要真机确认的一项：修复缩小了「需要恢复」的判定范围，必须确认真实设备变化没有被一起忽略掉。

1. 选定 `SayAll`（旧安装为 `MiRemoteV 2ch`），触发一次语音让音频真正开始播放。
2. 插拔一个外接音频设备（如 USB 声卡、DJI Mic 接收器、外接显示器自带音箱），或在系统声音设置里切换默认输出再切回。
3. 观察日志。

预期：如果实际绑定丢失或状态未知，应出现 `AUDIO RECOVERY ... phase=applying`，且相同 `operation_id` 的完成记录为 `result=ready`、`bound_to_selected=true`。仅切换与明确选择的虚拟输出无关的系统默认输出时允许忽略，但下一次语音必须仍可正常播放。

失败判定：设备变化后 App 不再恢复，音频停留在错误设备上；或语音播放中断且不恢复。

如果日志同时出现 `hardware_change` 和 `engine_configuration_change`，预期最终执行记录仍应使用 `reason=hardware_change`，不能只出现 `decision=still_bound_idle` 后结束。

### AC-03 语音播放中不受影响

1. 按住语音键，说一段较长的话（10 秒以上）。
2. 全程观察日志。

预期：若配置变化导致引擎或播放器不健康，活跃语音不会命中 `still_bound_idle`，恢复路径仍会执行；语音音频连续、完整，与上一正式版体验一致。

失败判定：语音中途卡顿、丢尾、或会话卡死（参见 `Bugs/2026-09-05-voice-session-wedges-when-audio-reconfigures-mid-drain.md`）。

### AC-04 长时间运行不复发

1. 让 App 正常运行数小时（含息屏、睡眠唤醒各一次）。
2. 统计当天日志的 `AUDIO RECOVERY ... phase=applying ... engine_configuration_change` 总数与每分钟峰值。

预期：不出现持续的高频重绑段。

失败判定：任意时段重新出现每分钟数十次的重绑。

### AC-06 活跃语音中重绑失败进入有界退避（Issue #1035）

1. 选定 `SayAll`（旧安装为 `MiRemoteV 2ch`），按住遥控器语音键持续说话。
2. 在语音进行中触发一次重配：用后台辅助功能按“选择 SayAll”，或由系统设备变化触发。
3. 如果重绑后 `AUDIO REBIND finished ... ready=false` 或 `AUDIO RECOVERY ... result=degraded`，继续观察 20 秒。

> 注意：不要在前台手动点击“选择 SayAll”。点击会把焦点切到设置窗口，原输入框可能收不到文字，导致无法判断最终文字。本用例首先看日志；若要同时保留输入框焦点，必须用不激活设置窗口的后台 Accessibility 点击，或改用系统音频设备变化触发。

预期：

- 不应在 1 秒内再次全量重绑；应依次出现 `AUDIO RECOVERY retry started attempt=1|2|3 delay_ms=2000|4000|8000`；
- 重绑完成回调返回前到来的自造 `engine_configuration_change` 记录为 `recovery_in_flight`；退避期间到来的记录为 `retry_pending`，两者都不重置延迟；
- 重试期间输出恢复健康时记录 `retry completed result=ready`，并允许后续语音继续；
- 3 次仍失败时记录 `retry_exhausted`，本会话内不再接受自造 `configuration_changed` 触发的恢复；下一次语音按键或真实硬件变化重新武装；
- 会话结束时 `enqueue_failures` 不再恒等于 `batches`，最佳为 0。

失败判定：仍出现约 1 秒一圈的 `AUDIO REBIND begin`；或 `retry_exhausted` 后继续因自造通知重绑；或 `ATVV STREAM summary` 的 `enqueue_failures == batches`。

### AC-05 音频重配不阻塞 AppKit 主线程（Issue #596，自动化与现场验收边界分开）

1. 选定 `SayAll`（旧安装为 `MiRemoteV 2ch`），保持 App 窗口可见。
2. 插拔外接音频设备，或在系统声音设置中切换默认输出。
3. 在重配日志出现时移动窗口、打开设置页并点击一个无破坏性的控件。

预期：自动化测试确认音频队列被阻塞时，主线程仍可执行配置请求、停止、诊断和事件处理；日志中的 `AUDIO CONFIGURE` 和 `AUDIO READY` 包含 `queue=audio_output`，主线程不等待 `mainMixerNode` 或 HAL 查询。真实窗口移动、点击和外接设备拔插仍需在现场完成。

失败判定：窗口出现“程序没有响应”；或重配日志缺少音频队列字段；或重配完成前主线程无法处理输入。

## 日志收集

```
cp ~/Library/Logs/RemoteMic/runtime.log ~/Desktop/ac-runtime.log
grep -c "AUDIO RECOVERY .*phase=applying" ~/Desktop/ac-runtime.log
```

每个真正执行的去抖恢复会先记录一条 `phase=started result=pending`，并按相同 `operation_id` 记录且只记录一条 `phase=completed`。空闲自造通知应结束为 `result=ignored decision=still_bound_idle`；实际恢复应结束为 `result=ready|degraded`。结合 `requested_reason`、`effective_reason`、`includes_hardware_change`、`engine_running`、`player_playing`、`bound_to_selected`、待播计数和 `elapsed_ms` 判断是否保留了真实硬件变化，以及恢复后是否真的可用。

重绑失败后的退避使用独立事件：`AUDIO RECOVERY retry started attempt=… delay_ms=…`、`retry completed result=ready|degraded`、`recovery_in_flight`、`retry_pending`、`retry_skipped` 和 `retry_exhausted`。这些事件与原始 `operation_id` 分开，避免把一次重试误记成一次新的用户触发恢复；`attempt` 只在本进程内递增。新的非恢复重绑会使旧恢复失效，防止迟到回调再次重绑。日志不包含设备 UUID、用户路径或音频内容。

## 验证边界

- 已完成（自动化）：策略测试覆盖空闲循环、活跃语音、待播尾包、健康输出、解绑、未知状态，以及硬件变化与引擎通知混合时硬件事件优先；配置完成态要求“配置成功且当前就绪”；恢复退避按 2/4/8 秒递增并在 3 次后耗尽，健康输出会复位；静态回归确认配置没有同步 `configure` 入口、启动和重配都使用 `configureAsync`，引擎构造与 HAL 调用位于串行音频队列；配置跳过、失败、开始和成功日志都包含 `queue=audio_output` 与 `elapsed_ms`；`swift test` 全量、`scripts/test.sh`、边界检查。
- 参考（同形态代码的代理真机观测）：AC-01，同机对比修复前 48 次/分钟 → 修复后 0 次/3 分钟；本次上游版本尚未复测。
- 已完成（自动化）：AC-05 的配置队列阻塞、主线程事件处理、配置日志队列与耗时字段；已在 `SayAll`（旧名 `MiRemoteV 2ch`）兼容虚拟麦克风上验证首次播放、播放器重启后的连续三次播放和自然排空。未执行真实 AppKit 窗口操作。
- 2026-11-14 本地 public 包 `2.0.0 (361)`、源码 `db4e7b1e`（dirty）真机 RC003 记录：7 次语音全部 `enqueue_failures=0`；默认输入切换均被忽略；设备变化恢复均 `result=ready`；没有 `AUDIO ENGINE configuration_changed`、`AUDIO WRITE rejected` 或 `retry started`。该轮健康路径通过，但**未触发失败重绑**，AC-06 的退避路径仍未验证。
- 2026-11-14 同一 build 361 的活跃语音重绑记录：后台 Accessibility 在 trace=1 会话内触发 `doubao_device_selected`；重绑窗口出现 1 次 `AUDIO WRITE rejected`，随后 `AUDIO READY`；会话 14.43 秒、`batches=920`、`enqueue_failures=6`（0.65%）。trace=2 重复同一操作：12.51 秒、`batches=791`、`enqueue_failures=3`（0.38%）。两次都不是 100% 丢包，没有 1 秒循环和 `retry started`；少量失败仍会把会话标记为 `audio_enqueue_failed`，trace=2 出现 `TRANSCRIPT CAPTURE canceled reason=discontinuous_after_finish`。当次无文字是因为系统默认输入为 AirPods，豆包未从虚拟麦克风取音；需要把豆包麦克风明确选为 `MiRemoteV 2ch`/`SayAll` 后补文字验证。
- **未完成（须用户实测）**：AC-02 真实拔插、AC-03 语音播放中、AC-04 长时间运行、AC-06 活跃语音中重绑失败退避。其中 AC-02 至 AC-04 和 AC-06 需要真实设备操作、语音会话和长时间运行。
- **未完成（须用户实测）**：语音键在音频输出已就绪、首次配置、配置中松键三种状态下的按下响应、首个有效音频和释放收尾。
- 自动化覆盖范围：Bluetooth、Apple Remote、Chromecast 和移动端路径均检查“语音路径先启动、音频配置异步执行、配置期间缓存 PCM、松键后先送尾包再自然排空”。
- 无法由代理执行：真实 `coreaudiod` 无响应，以及外接设备在语音播放期间的拔插恢复。
