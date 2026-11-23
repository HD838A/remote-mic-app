# 虚拟音频引擎初始化阻塞导致语音会话永不结束、菜单栏图标长期变红

- 时间：2026-11-24
- 状态：候选修复；自动化通过，等待真实虚拟声卡、遥控器和第三方语音工具验收
- 影响范围：macOS；小米 RC001/RC003 蓝牙语音 + SayAll 虚拟音频输出的用户；虚拟输出配置在 Core Audio 层被阻塞之后
- 功能点：`AudioOutput` 配置队列与 `AVAudioEngine` 建图、蓝牙语音会话收尾、`VoiceSessionWarningLevel` 菜单栏告警
- 简单描述：用户完全没有操作时菜单栏图标也一直红，且语音实际不出声。日志显示音频配置卡在 `AVAudioEngine()` 构造处，永久占住共享串行 `engineQueue`；此后所有配置请求只排队不执行，语音会话等不到配置回调，因此永不收尾，而 53/57 秒提醒按“会话存活时长”照常触发。

## 现场证据

App `2.0.0 (267)`，公开构建通道。用户提供三份加密 `.rmlog`，按受控流程解密后分析；三段合计覆盖本地时间（UTC+8）2026-11-22 21:14 → 2026-11-24 00:25，跨一次完整故障周期。截图只作外部现场证据，图片字节不入仓库。

用户描述：图标变红，无论有没有在操作都是红的；语音功能本身“没问题”；再点一下语音键会短暂恢复。日志与描述一致，但实际音频并未送达虚拟麦克风（见下）。

### 卡死点

`19:59:xx` 之前音频配置正常。`20:05:02`（`12:05:02Z`）一次配置在选设备阶段失败，紧接着的下一请求停在建图阶段：

```text
12:05:02.206Z AUDIO CONFIGURE failed reason=set_current_device queue=audio_output
              error_domain=os_status error_code=1852797029
12:05:02.207Z AUDIO CONFIGURE operation_id=1122 phase=completed result=failed
              reason=configure_failed status_key=audio.output.select_failed
12:05:02.241Z AUDIO CONFIGURE operation_id=1123 phase=started result=pending queue_wait_ms=0
12:05:02.241Z AUDIO CONFIGURE operation_id=1123 phase=applying result=pending
              stage=connect_mixer queue=audio_output elapsed_ms=1
```

`stage=engine_created` 此后从未出现。`AudioOutput.swift` 中这两个阶段之间只有一行 `let engine = AVAudioEngine()`，即阻塞发生在引擎构造，而不是 `prepare()`/`start()`。`error_code=1852797029` 为 `'nope'`（`kAudioHardwareIllegalOperationError`）。

### 之后整段日志

- `20:05` 之后共 **831 条** `AUDIO CONFIGURE phase=requested`，**0 条** `phase=started`。
- 全量最后一条 `AUDIO READY` 停在 `20:05:02.139`；最后两小时（`22:28`–`00:25`）内 `AUDIO READY` 为 0，`phase=started` 为 0。
- 同一时段 `AUDIO HEALTH stale` 359 次，全部只是重新排队，没有一次推进。

### 语音会话侧后果

```text
23:49:35.576 ATVV STREAM accepted trace=1348 model=rc003 operation_id=1429
23:49:37.587 ATVV STREAM stop_deferred_until_audio_ready result=pending_tail
             pending_samples=32000
23:49:40.211 ATVV STREAM ignored reason=duplicate_start      ← 此后每次按语音键都走这条
```

- 最后两小时内 `accepted` 1 次、`ignored_duplicate_start` **87 次**。
- 该时段所有 ATVV 记录均为 `routed_samples=0`、`observed_result=local_delivery_failed`：解码出的 PCM（单条最多 176880 samples）没有一个写进虚拟输出。

即“语音功能没问题”并不成立，只是用户当时没有真正测试文字上屏。

### 图标变红的时间线

```text
20:44:57 UI VOICE_WARNING phase=completed result=applied model=rc003 level=critical
23:49:25 UI STATUS_ITEM applied from=streaming_critical to=streaming       ← BLE 断链
23:49:25 UI VOICE_WARNING phase=completed result=reset cause=session_end
23:49:35 ATVV STREAM accepted trace=1348
23:50:29 UI VOICE_WARNING ... level=warning
23:50:32 UI VOICE_WARNING ... level=critical                               ← 到日志结束仍红
```

`20:44:57` 到 `23:49:25` 连续红 **3 小时 4 分**；`23:50:32` 之后到日志结束（`00:25`）持续红。两次解除都不是用户操作，而是 BLE 断链把会话状态整体清掉。

## 已确认根因

1. **阻塞点在共享队列上**：`AVAudioEngine()` 构造、`attach`、`connect`、`outputNode.audioUnit`、`AudioUnitSetProperty(CurrentDevice)` 都在串行 `engineQueue` 上同步执行，没有任何超时。一次 HAL 阻塞就把队列永久占死。
2. **会话无法收尾**：输出未就绪时开始录音会进入 `awaitsOutputConfiguration`，停止走 `stop_deferred_until_audio_ready`，只有配置完成回调才会调用 `finishBluetoothVoice`。配置永不回调 → `finishBluetoothVoice` 永不执行。
3. **告警按会话存活时长计时**：`startVoiceSessionWarningTracking` 从会话开始按 wall clock 排 53/57 秒定时器，与实际是否在传 PCM 无关。会话卡住后，即使完全没操作也必然到点变红。
4. **按键被吞**：`activeBluetoothVoiceDeviceIdentifier` 只在 `finishBluetoothVoice` 里清空，因此永不释放；`bluetoothBridgeDidStartVoice` 遇到它非空就直接 `duplicate_start` 返回，后续按键全部无效。

后三条都是第 1 条的必然下游，不是独立缺陷。

## 为什么卡片上的恢复入口救不回来

`recoverRemoteVoiceAudio()` 有两道门都过不去：

- `guard !isStreaming`：会话卡死时 `isStreaming` 永为 `true`（`finishBluetoothVoice` 内的 `endVoiceSessionIfNeeded` 跑不到），按钮被 `audio_in_use` 挡住。
- 即使绕过，它最终只是再发一次 `configureAsync`，仍然排在同一条已经卡死的队列后面。

因此现场唯一的恢复手段是退出 App 重开（新进程、新队列）。

## 版本核对

`v2.0.10` = `origin/main` = `4d258262`（2026-11-23）。逐点核对结果：

| 问题 | 2.0.10 |
| --- | --- |
| `AVAudioEngine()` 建图卡死 | 未修：建图仍在 `engineQueue`；`AudioEngineStartCoordinator` 只覆盖 `prepare()`/`start()` |
| 会话无超时 | 未修：`ensureVirtualAudioOutputReady(completion:)` 无超时，无看门狗 |
| `duplicate_start` 吞键 | 未修：identifier 非空即返回 |
| 53/57 秒按 wall clock | 未修：与故障前实现一致 |

2.0.10 相比故障版本新增的 `AudioEngineStartCoordinator`（`b0cf2624`）把 `prepare()`/`start()` 移到独立队列并限时 2 秒，能修掉“阻塞发生在 prepare”这一种；本次阻塞发生在它之前的引擎构造，因此同一现象仍会复现。

## 未确认

- HAL 层为什么在 `AVAudioEngine()` 构造处阻塞：日志只能证明卡在这里，不能区分虚拟驱动实例被反复重建、`coreaudiod` 对新客户端响应阻塞、设备枚举与引擎创建竞态。需要在卡住时 `sample SayAll` / `spindump` 对照 `coreaudiod` 系统日志。
- 同机 `MiRemoteV 2ch` 当时的驱动实例状态：日志未记录。

## 修复

只改一处根因：`AudioOutput.configureOnEngineQueue` 里所有会同步触达 HAL 的步骤——设备枚举、音量修复、`AVAudioEngine()` 构造、`attach`、`connect`、`outputNode.audioUnit`、`CurrentDevice` 属性写入、`prepare()`、`start()`——整体挪进一次有界执行，复用 `AudioEngineStartCoordinator` 已有的超时、取消令牌与 cleanup。

- `AudioEngineStartCoordinator` 新增带返回值的 `run`，`start` 退化为 `run<Void>` 的薄包装；已有调用和夹具不受影响。
- 建图失败改为抛错，由串行队列上的同一处代码写 `status` 和日志，避免在 worker 里并发写串行状态。
- 超时仍沿用稳定标识 `reason=prepare_timeout`，并新增 `last_stage=` 指明预算在哪一步耗尽（现场会显示 `last_stage=connect_mixer`）。
- 取消令牌在建图后、`prepare` 后、`start` 后各检查一次，命中即停引擎再抛，孤儿引擎不会继续占用设备。
- 新增可注入的 `audioGraphFactory` 仅用于测试阻塞或抛错；生产默认值不变。

一次 HAL 阻塞最多占用共享队列 2 秒（加一次重试），配置 completion 必然回调，`failBluetoothVoiceConfiguration` → `finishBluetoothVoice` 会清 identifier、取消告警计时、把 `isStreaming` 置回 false。红色图标、`duplicate_start` 吞键、恢复入口被挡三个下游症状同时消失，没有单独打补丁。

没有采用的替代方案：

- 只给 53/57 秒计时加“实际 PCM 在传才算”：不解决队列被永久占用，语音照样不出声。
- 给延迟收尾的会话加“N 秒强制结束”：把卡死藏起来，下一次按键仍然失败。
- 检测卡住自动重建音频子系统：旧队列的线程仍阻塞，等于把同一个坑挪到另一个观测点。
- 把 `engineQueue` 改成并发队列：配置、播放状态和尾音排空都依赖它的串行性，会引入一批新竞态。

## 验证

自动化：

- 新增 `blockedAudioGraphBuildKeepsTheSharedConfigurationQueueMoving`：注入一个在引擎构造处阻塞的图工厂，断言第一条配置在有界时间内失败（`firstElapsed < 2`）、日志出现 `phase=timed_out` 且 `last_stage=connect_mixer`、第二条配置仍然能 `phase=started` 并完成。
- 反向验证：把建图临时挪回共享队列后，同一用例在 `firstElapsed < 2` 处失败（实测 40.3 秒仍未返回）；恢复修复后通过。
- 原有 `audioConfigurationUsesBoundedEngineStartAndLogsRetry` 增加位置断言，确认建图发生在那次有界调用内部、且早于 `prepare`。

真实环境边界：

- 尚未用真实 `MiRemoteV 2ch` 复现 Core Audio 在 `AVAudioEngine()` 构造处的阻塞，因此“阻塞时自动恢复”只有夹具证据。
- 尚未完成实体 RC003 的连续语音、尾音排空和第三方语音工具文字上屏复验。
- 本次修复不改变底层 HAL 行为：若阻塞真的发生，用户会看到卡片「语音异常」+「恢复语音」，而不是永久红图标和只能重启 App。
