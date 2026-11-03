# 虚拟声卡音量与静音测试

## 适用范围

- 分支：`codex/fix-virtual-audio-audibility-20260920`；2026-11-03 起音量改由连接页「音量」滑块决定
- 跟踪 Issue：[#475](https://github.com/HD838A/remote-mic-app/issues/475)
- 设备：`MiRemoteV 2ch`；原生 `BlackHole 2ch` 需要单独完成同类验证
- 路径：App 启动配置、测试音、实体遥控器、iPhone、Apple Watch、网页和其他复用
  `VirtualAudioOutput` 的语音入口

> 2026-11-03 起不再使用「低于 `0.2` 才恢复 `1.0`」的固定阈值，也不再让用户直接改设备音量：
> 虚拟声卡自身音量由 App 固定写成 `1.0`，用户唯一的「音量」（连接页，0–1000%）作用在
> 送往语音工具的写缓冲出口，0% 静音、100% 原始音量、1000% 约 +20 dB。下文用例已按新语义更新。

## 测试前准备

1. 确认当前选择的是 MiRemoteV 2ch 或 BlackHole 2ch。
2. 记录设备 input/output scope 主声道的 mute 和 volume 原值。
3. 确认没有正在进行的语音、会议或录音会话。
4. 保留 `~/Library/Logs/RemoteMic/runtime.log` 的问题时间段；本功能新增的
   `AUDIO AUDIBILITY` 日志不得包含音频、文字、设备 ID、UID、自定义设备名或路径。

## 自动化

```bash
swift test --disable-keychain --filter VirtualAudioConnectionLifecycleTests
```

预期：策略测试覆盖明确静音、设备音量恒为满值（任何被外部改小的值都要写回）、
未知属性、写入成功及写入后仍不可用；`outputVolumePercentMapsToLinearScale` 覆盖
百分比与线性系数/分贝的换算、越界钳制和放大削顶。

本机安装 MiRemoteV 2ch 时，可以运行显式设备变更测试：

```bash
SAYALL_TEST_MUTATE_VIRTUAL_AUDIO_LEVEL=1 swift test --disable-keychain \
  --filter installedMiRemoteVCanRecoverFromMuteAndLowVolume
```

该测试会保存原值，先把 input/output 两端临时设为 `mute=1 / volume=0`，再设为
`mute=0 / volume=0.19`，分别调用产品写入路径并验证恢复为 `mute=0 / volume=1.0`，
最后恢复测试前原值。执行结束后仍需独立读回确认。

## 用例一：明确静音

1. 分别把所选受支持虚拟声卡的 input/output 主声道设为 `mute=1 / volume=0` 和
   `mute=0 / volume=0`。
2. 启动无线麦或点击测试音。
3. 再次读取设备属性并检查日志。

预期：只对所选受支持虚拟设备执行写入；属性恢复为未静音且音量为 `1.0`。日志包含
`AUDIO AUDIBILITY repair`、稳定设备分类、`volume_adjustment_attempted`、写入前后 scalar、
`target_volume_scalar` 和 `result=ready`。

失败：仍为静音、只修改一个 scope、日志报告 ready 但读回仍不可用，或日志包含
设备 ID、UID、自定义名称及用户内容。

## 用例二：用户音量只作用于送往语音工具的声音

1. 连接页「语音设备」面板把「音量」设为 `100%`，确认设备 input/output volume 为 `1.0`。
2. 把「音量」拖到 `200%`，用同一条遥控器说同一句话，对比语音工具收到的响度。
3. 再拖到 `40%` 与 `0%`，分别重复一次；每次都要读回设备属性。

预期：设备 input/output 始终是 `1.0`（滑块不再写设备属性）；`200%` 明显变响、`40%` 明显变小、
`0%` 完全静音；拖动过程中不需要重新连接音频，也没有可听的中断。日志 `AUDIO AUDIBILITY repair`
里的 `user_volume_percent` 跟随滑块变化。

失败：设备音量被滑块改写、拖到 0% 仍有声音、放大后出现爆音/削顶以外的失真，或需要重建链路才生效。

## 用例三：默认音量与历史值迁移

1. 使用没有 `outputVolumePercent`、也没有 `gainDB` 的干净 UserDefaults 启动设置。
2. 使用只有历史 `gainDB = 10` 的 UserDefaults 重新启动设置。

预期：新安装的「音量」为 `100%`（原始音量）；历史保存过增益的用户按幅度折算迁移，
`10 dB` 显示为约 `316%`，听感与升级前一致。两端都不会把设备音量改离 `1.0`。

## 用例四：属性未知或不可写

1. 使用不公开 mute/volume 的受支持回环设备，确认属性读数为 `unknown`。
2. 使用可复现只读或写入失败的测试替身，制造修复后仍明确静音。

预期：属性不存在时保持兼容，不仅因 unknown 阻断；已知静音、写入失败或读回与目标不一致时，
配置失败且不得进入 Ready，也不得产生 `delivered_to_selected_device` 的假成功。

## 用例五：启动后再次静音或被外部改动

1. 启动 App 并确认虚拟声卡 Ready。
2. 在空闲状态把设备改为 `mute=1`，或把 volume 改成与连接页目标明显不同的值（例如 `0.31`）。
3. 分别从实体遥控器、iPhone、Apple Watch 和网页开始下一次语音。

预期：每个入口现有的实时音频健康检查发现静音或音量偏离 `1.0`，重新配置并写回满音量后才接受语音；
不得丢失首字，不得通过 flush 丢弃尾音。用户设置的「音量」不受影响。

## 用例六：外部改动设备音量不改变用户设置

1. 连接页「音量」设为 `300%` 并确认生效。
2. 在「音频 MIDI 设置」或任何其他 App 把 MiRemoteV 主音量改成 `0.31`（约 6%）。
3. 观察连接页「音量」数值，然后重新连接音频并再说一句话。

预期：滑块仍显示 `300%`（用户意图不被外部改动覆盖）；重新连接后设备写回 `1.0`，
声音恢复到用户设定的大小。若外部改动发生在会话中，下一次语音前的健康检查应把它写回 `1.0`。

## 稳定功能回归

- 测试音仍能完成真实播放回调。
- RC003 普通 `STREAM_START → AUDIO → STREAM_STOP` 首字低延迟、尾字完整。
- 连续快速语音 generation 相互隔离。
- 物理扬声器、麦克风及未知设备的 mute/volume 不被修改。
- PR #323 的按需占用策略不属于本修复，不能用频繁释放/重建设备代替属性自愈。
- 音量作用在 App 写缓冲出口，因此不放宽设备音量属性；不要改成「用户音量写进设备」以免与外部改动互相覆盖。

## 验证边界

- 自动化证明策略、编译与 MiRemoteV 属性写入路径，不证明真实语音工具已经收到声音。
- 必须使用真实虚拟设备、真实控制来源和真实第三方工具完成最终文字上屏，才能称为完整验收。
- MiRemoteV 2ch 的结果不能替代原生 BlackHole 2ch；后者未完成前保持待验证。
