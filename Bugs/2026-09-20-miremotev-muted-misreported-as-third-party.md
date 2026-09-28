# 虚拟设备被静音或音量过低时仍判定「送达成功」，并把失败归因为第三方工具配置

- 时间：2026-09-20
- 状态：现象与根因已确证；自动解除静音与低音量保护的候选修复已完成，等待合入与发布后验证
- 影响范围：所有把音频写入 `MiRemoteV 2ch` 或 `BlackHole 2ch` 的语音路径，
  包括 Onboarding 语音测试、实体遥控器、iPhone App、网页版与回眸。
  当所选虚拟设备处于静音（mute=1）或音量低于 `0.2` 时进入自动恢复，与第三方语音工具无关。
- 功能点：虚拟音频输出、语音送达判定（`VoiceAudioDeliveryPolicy`）、
  Onboarding 语音测试诊断与恢复文案
- 简单描述：所选虚拟音频设备被静音或音量为 0 时，SayAll 仍报告
  `audio_result=delivered_to_selected_device`，界面提示「声音链路正常」，
  并把失败归因为第三方工具未提交文字。
- 原始记录：本机 `~/Library/Logs/RemoteMic/runtime.log`（2026-09-19T17:06–17:12Z，
  构建自 `origin/main` `940dde5`，`ver=1.9.21 build=227`）；CoreAudio 设备属性查询；
  双进程回环实验（见 E1）。日志未记录任何语音内容。跟踪 Issue：[#475](https://github.com/HD838A/remote-mic-app/issues/475)。

## Observations

- 用户在 Onboarding 语音测试页按住遥控器语音键说话时，豆包输入法的麦克风电平
  完全没有反应。
- SayAll 侧连续 6 次 attempt 全部报告成功送达，例如其中一次：

  ```text
  VOICE_ATTEMPT terminal result=external_tool_no_commit
    audio_result=delivered_to_selected_device
    audio_selected=miremotev_2ch   audio_actual_start=miremotev_2ch
    audio_bound_start=true         audio_bound_observation=true
    audio_received_samples=140160  audio_scheduled_samples=140160
    audio_played_samples=140160    audio_interrupted_samples=0
    audio_pending_samples=0        audio_enqueue_failures=0
    external_microphone_observable=false
    external_microphone_user_confirmed=true
  ```

- SayAll 对**收到的**音频的自测表明输入侧不是静音：

  ```text
  ATVV STREAM tail trace=4 model=rc003 route=virtual_audio
    tail_samples=4800 tail_nonzero=4795 tail_peak=6287 tail_rms=1469
  ```

- 也就是说：输入侧是真实语音，SayAll 报告全部渲染完成，而设备侧无声。

## Hypotheses

### H1：所选虚拟设备本身被静音，SayAll 的送达判定不覆盖设备属性（ROOT CAUSE）

- Supports：`MiRemoteV 2ch`（`AudioDeviceID 97`）查询结果为
  `kAudioDevicePropertyMute = 1`、`kAudioDevicePropertyVolumeScalar = 0.00`。
- Supports：该设备是 BlackHole `v0.7.1` 的重打包版本
  （见 `TECHNICAL.md`），BlackHole 会遵守设备自身的 mute/volume，
  因此写入的音频在通过时被衰减为零。
- Supports：E1 的双进程回环实验在恢复设备音量前完全无声，恢复后即出现与写入
  振幅精确一致的信号，说明设备属性是唯一变量。
- Supports：`VoiceAudioDeliveryPolicy.result(for:)` 的判定条件只覆盖
  `generation`、`receivedSamples`、`outputAtStart` 的
  `selectedDeviceKind` / `engineRunning` / `playerPlaying` /
  `boundToSelectedDevice`、`enqueueFailures`、`interruptedSamples`、
  `scheduledSamples`、`pendingSamples`、`playedSamples`——
  **均属主机侧渲染状态，不包含目标设备的 mute 与 volume。**
- Conflicts：无。

### H2：第三方工具（豆包）内部麦克风选择错误

- Supports：[Onboarding 语音测试页隐藏第三方配置](./2026-09-05-onboarding-voice-test-hidden-tool-configuration.md)
  记录的现场根因即为豆包麦克风选择错误，手动改为 `MiRemoteV 2ch` 后立即恢复。
- Conflicts：该假设要求设备上确实有音频可供第三方读取；E1 证明恢复前设备侧为
  纯静音，第三方无从接收。用户本次亦确认豆包麦克风已正确设置。
- 结论：本次现场不是该原因。但**两者会产生完全相同的诊断外观**，
  这正是本问题值得记录的原因。

### H3：系统静音（默认输出设备）传导到虚拟设备

- Supports：用户当时将 Mac 系统声音设为静音。
- Conflicts：系统静音作用于**默认输出设备**（`MacBook Pro扬声器`，
  `id 132`，实测 `mute=1 volume=0.00`），与 `MiRemoteV 2ch`（`id 97`）
  各自持有独立的 mute/volume。实测恢复后（`id 97` 为 `mute=0 volume=1.00`）
  在系统仍处静音的状态下完成了通过的语音测试。否定。

### H4：应用自身设置了设备音量或静音

- Conflicts：`Sources/` 中仅有两处 CoreAudio 写操作——`AudioOutput.swift:219` 的
  `setDefaultInputDevice` 与 `AudioOutput.swift:557` 的 `AudioUnitSetProperty`，
  均不涉及 `kAudioDevicePropertyMute` 或 `kAudioDevicePropertyVolumeScalar`。
  否定。

## Experiment

### E1：双进程回环实验

- 方法：一个进程向 `MiRemoteV 2ch` 写入 440 Hz 正弦波（振幅 0.5），
  另一个**独立进程**同时从该设备录音，模拟 SayAll 写 / 第三方读的真实分工。
- 恢复设备属性前：

  ```text
  写入侧：dataPlayedBack fired = true，player.isPlaying = true
  读取侧：peak=0.0000 rms=0.0000   windows-with-signal = 0/12
  ```

- 设置 `kAudioDevicePropertyMute = 0`、`kAudioDevicePropertyVolumeScalar = 1.0`
  后重跑同一实验：

  ```text
  读取侧：peak=0.5000 rms=0.3059   windows-with-signal = 10/12
  首样本：-0.342, -0.320, -0.298, -0.274 …（连续正弦）
  ```

- `peak=0.5000` 与写入振幅精确一致，回环链路逐位可用。
  （末 2 秒静音为写入进程先结束，属预期。）

### E2：恢复后重走真实语音测试

- 结果：`VOICE_ATTEMPT terminal attempt=6 result=passed probable_cause=passed`、
  `audio_received_samples=54960`、`played_samples=54960`、
  `enqueue_failures=0`、`focus_loss_count=0`、`transcript_wait_ms=40`。
- 文字在 40ms 内上屏，远小于 3 秒判定窗口。

### E3：产品代码自动恢复真实 MiRemoteV 2ch

- 本机先独立读取 MiRemoteV 2ch 的 input/output scope 主声道属性，确认两端均支持
  可读、可写的 `kAudioDevicePropertyMute` 与 `kAudioDevicePropertyVolumeScalar`。
- 测试保存原值后，把 input/output 两端都设为 `mute=1 / volume=0`，再调用产品中的
  `ensureVirtualAudioDeviceAudible`；约 0.1 秒内自动恢复为 `mute=0 / volume=1.0`。
- 测试使用 `defer` 恢复原始值；测试结束后再次由独立 CoreAudio 查询确认 input/output
  均为 `mute=0 / volume=1.0`。

## 根因

所选虚拟设备处于静音或音量过低，音频在设备内部被静音或显著衰减。
SayAll 的送达判定完全基于主机侧渲染状态，不含目标设备的 mute/volume，
因此无法区分「我们渲染出去了」与「它到达了线路上」，
于是报告 `delivered_to_selected_device`，并在失败归因上指向第三方工具。

## 修复

在配置输出和每次语音开始前的实时健康检查中，对受支持的虚拟回环设备读取 input/output
scope 主声道的 `kAudioDevicePropertyMute` 与 `kAudioDevicePropertyVolumeScalar`：

- 只有明确 `mute=true` 时才写回 `false`；只有明确 `volume<0.2` 时才恢复为 `1.0`。
- `volume>=0.2` 完全保留；CoreAudio scalar 与 App 的 PCM 增益是两套独立控制，新安装的
  App 增益继续默认为 `10 dB`，已有用户保存值不变。
- 只对稳定识别为 `MiRemoteV 2ch` 或 `BlackHole 2ch` 的设备执行修复；实体扬声器、
  实体麦克风和未知设备不读取为门禁，也不写入任何属性。
- 属性不存在时记录为 `unknown` 并保持兼容；属性存在但写入后仍静音或低于阈值时，输出配置失败，
  不再把设备标为 Ready。
- 健康检查会实时读取属性；用户在 App 启动后再次静音或调低虚拟声卡，下一次语音开始前会触发
  重新配置和同一套自愈。
- 运行日志只记录稳定设备分类、是否静音、音量是否为零、是否尝试修复和最终结果，
  不记录设备 ID、UID、自定义名称或用户音频。

## 验证

- 设备属性读回：`mute=0`、`volume=1.00`。
- 回环：0/12 → 10/12 窗口有信号，`peak` 与写入振幅一致。
- 真机：实体 RC003 遥控器 + 真实豆包输入法，语音测试 `result=passed`，
  `transcript_wait_ms=40`。
- 自动化：`VirtualAudioConnectionLifecycleTests` 覆盖明确静音、`0.19`、`0.20`、`0.21`、
  未知属性、修复成功、写入/读回后仍低于阈值，以及未知设备不适用；设置测试锁定
  新安装默认 `10 dB` 且已有保存值不变。
- 真实属性自愈：`SAYALL_TEST_MUTATE_VIRTUAL_AUDIO_LEVEL=1 swift test --disable-keychain
  --filter installedMiRemoteVCanRecoverFromMuteAndLowVolume` 通过。
- 未执行：macOS 26 上的候选 App 验证；原生 `BlackHole 2ch` 的属性写入与真实回环；
  实体 RC003 从自动修复到第三方文字上屏的完整候选 App 复验。

## 边界与遗留

- **静音的来源未查明。** 已排除系统静音（H3）与应用自身（H4）。
  可能是 macOS 按设备持久化的音量：若 `MiRemoteV 2ch` 曾在某一刻作为默认输出设备
  时被静音（静音键或某应用静音了默认输出），该状态会写入它自己的持久化音量并保留。
  **该推测无法在本机回溯确认，仅作提示，不作为已确认事实。**
  相关线索见未合并的 PR #323（「实体遥控器按需占用虚拟声卡，空闲时不压低系统播放音量」）。
- 自动修复只恢复明确的静音和低于 `0.2` 的音量，不会提高阈值及以上音量；若设备不公开这些属性，
  仍需依靠真实回环和最终文字上屏确认。
- 本问题与
  [Onboarding 语音诊断无法区分焦点、音频输出与第三方未提交](./2026-08-31-onboarding-voice-attempt-diagnostics/DEBUG.md)
  所列假设互补：该文档的 H2 已考虑「虚拟音频输出实际失败」，但把低概率归因于
  「会话开始前的实时健康检查已通过」。本文记录的情形**恰好通过全部既有健康检查**
  （引擎运行、播放器播放、设备绑定、入队成功、播放完成），
  因此是该假设清单未枚举的第三种模式。
