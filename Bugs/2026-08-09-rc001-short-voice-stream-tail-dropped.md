# RC001 Short Voice Stream Tail Dropped on STREAM_STOP

- 时间：2026-08-09
- 状态：已修复，模拟回归通过
- 影响范围：macOS 1.8.0 预览版；RC001 语音，RC003 共享停止路径
- 功能点：ATVV 短语音播放收尾
- 简单描述：RC001 音频虽成功解码入队，但远端停止时播放器立即清空队列，使短语音整段或尾部丢失。
- 原始记录：DEBUG.md，首次记录 本次修复

## 详细过程

## Observations

- 现场版本为 Remote Mic 1.8.0；RC001 普通 HID 按键可用，但语音没有实际输出。
- 运行日志记录了 RC001 的 `STREAM START`、音频解码并以 `accepted=true` 路由到虚拟音频，以及紧随其后的 `STREAM STOP`；这只能证明音频成功入队，不能证明完成播放。
- RC001 的现场会话通常约 0–1 秒；RC003 的会话通常持续数秒至数十秒。
- 独立硬件模拟项目的 `direct-stream` 在最后音频分片后 30 ms 发送 `STREAM_STOP`，共提供一帧 120 字节 ATVV 音频，是稳定的 RC001 短流最小复现。
- 当前集成测试只断言 ATVV 解码得到 240 个 PCM sample，没有覆盖停止事件对待播放队列的影响。
- `bluetoothBridgeDidStopVoice` 在普通虚拟麦克风模式调用 `endVoiceSessionIfNeeded(flushAudio: true)`；`AudioOutput.endSession()` 随即清空待播放计数并 `stop/reset` 播放节点。
- RC003 的稳定基线仍应覆盖无需主动 `MIC_OPEN` 的 `STREAM_START → AUDIO → STREAM_STOP`。

## Hypotheses

### H1: STREAM_STOP 立即清空播放器，丢弃 RC001 短流尾部（ROOT HYPOTHESIS）

- Supports: RC001 会话短、音频已成功入队、停止路径立即清队列；RC003 长会话已有前段音频完成播放，因而可能表面正常。
- Conflicts: 该停止逻辑早于 RC001 正式适配；早期“可用”结论可能只验证了协议和入队，尚无最终包真实播放证据。
- Test: 用硬件模拟器短流驱动生产解码器，并在停止事件处模拟当前普通模式的 flush 策略；若有效 PCM 被清空且断言失败，则确认该边界。

### H2: RC001 与 RC003 使用不同的 ADPCM nibble 顺序或同步方式

- Supports: 用户观察到只有 RC001 语音不可用。
- Conflicts: 两款设备返回相同 ATVV v1.0 能力、120 字节帧；日志显示 RC001 已解码并成功入队。
- Test: 对 RC001 抓取帧与模拟帧执行生产解码，比较 sample 数量、连续性和幅度。

### H3: 多遥控器 active identifier 路由到了错误设备

- Supports: 问题出现在多遥控器适配后的版本。
- Conflicts: 日志明确记录 `model=rc001 route=virtual_audio accepted=true`，说明 RC001 是当前活动语音设备。
- Test: 同时模拟两个设备交替开始、发送音频和停止，断言音频只进入当前设备会话。

### H4: RC001 需要主动 MIC_EXTEND 保活

- Supports: RC001 的语音会话明显短于 RC003。
- Conflicts: 停止命令由遥控器主动发送；既有协议基线是设备可直接发送语音流，当前证据更直接指向停止后的本地清队列。
- Test: 比较发送与不发送 MIC_EXTEND 的控制事件序列；若设备始终主动停止且此前已有完整音频帧，则不能解释已入队音频无输出。

## Experiments

1. **RC001 短流 + 当前停止策略 — 确认 H1。** 使用独立硬件模拟项目的 `direct-stream` 驱动生产 ATVV 解码器，得到 240 个有效 PCM sample；随后用 4 行诊断代码模拟普通模式 `handledByFnTapMode == false` 时的立即 flush，待播放 sample 变为 0，集成测试在 `#expect(!scheduledSamples.isEmpty)` 稳定失败。诊断代码已回退。
2. **隔离工作树依赖身份检查。** 模拟器工作树目录名会改变 SwiftPM 本地包 identity，因此正式集成检测使用原模拟器路径加载同一 fixture；这只影响测试装载方式，不影响复现结论。

## Root Cause

RC001 的短语音帧虽已成功解码并入队，但 `STREAM_STOP` 在播放完成前立即调用 `AudioOutput.endSession()` 清空队列并重置播放器，导致整段或尾部语音被丢弃；RC003 较长的会话让前段音频有机会先播放，掩盖了同一停止策略缺陷。

## Fix

- 蓝牙遥控器收到 `STREAM_STOP` 时保留已经排队的虚拟音频，只结束会话状态；Fn 点按模式仍由既有控制器完成自己的排空和按键释放。
- 独立硬件模拟项目新增明确标识为 RC001 的短语音场景：一帧 120 字节音频被拆成 40/80 字节，最后分片后 30 ms 停止。
- Mac 集成测试同时驱动 RC001 短流与 RC003 普通直接流，断言生产解码得到的 240 个 sample 在远端停止后仍全部留在播放队列。

## Validation

- 修复前诊断测试稳定失败：240 个有效 sample 在当前停止策略下变为 0。
- `hardware-simulation`：17 项测试通过。
- `HardwareSimulationIntegrationTests`：RC001 与 RC003 两种直接流及其余硬件集成测试共 11 项通过。
- 自动化验证覆盖协议事件、生产解码和停止策略；RC001 实际扬声/虚拟麦克风输出仍建议在安装预览包后补一次真机听感确认。
