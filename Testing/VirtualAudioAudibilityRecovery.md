# 虚拟声卡静音与低音量自动恢复测试

## 适用范围

- 分支：`codex/fix-virtual-audio-audibility-20260920`
- 跟踪 Issue：[#475](https://github.com/HD838A/remote-mic-app/issues/475)
- 设备：`MiRemoteV 2ch`；原生 `BlackHole 2ch` 需要单独完成同类验证
- 路径：App 启动配置、测试音、实体遥控器、iPhone、Apple Watch、网页和其他复用
  `VirtualAudioOutput` 的语音入口

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

预期：策略测试覆盖明确静音、低于 `0.2`、等于或高于 `0.2`、未知属性、修复成功及修复后仍不可用。

本机安装 MiRemoteV 2ch 时，可以运行显式设备变更测试：

```bash
SAYALL_TEST_MUTATE_VIRTUAL_AUDIO_LEVEL=1 swift test --disable-keychain \
  --filter installedMiRemoteVCanRecoverFromMuteAndLowVolume
```

该测试会保存原值，先把 input/output 两端临时设为 `mute=1 / volume=0`，再设为
`mute=0 / volume=0.19`，分别调用产品修复代码并验证恢复为 `mute=0 / volume=1.0`，
最后恢复测试前原值。执行结束后仍需独立读回确认。

## 用例一：明确静音与低音量

1. 分别把所选受支持虚拟声卡的 input/output 主声道设为 `mute=1 / volume=0` 和
   `mute=0 / volume=0.19`。
2. 启动无线麦或点击测试音。
3. 再次读取设备属性并检查日志。

预期：只对所选受支持虚拟设备执行修复；属性恢复为未静音和 `1.0`。日志包含
`AUDIO AUDIBILITY repair`、稳定设备分类、修复动作、修复前后 scalar、`volume_low`、
`minimum_volume_scalar=0.2` 和 `result=ready`。

失败：仍为静音/低于 `0.2`、只修改一个 scope、日志报告 ready 但读回仍不可用，或日志包含
设备 ID、UID、自定义名称及用户内容。

## 用例二：保留阈值及以上音量

1. 分别把 input/output volume 设为 `0.20` 和 `0.25`，保持未静音。
2. 重新配置设备并开始一次测试音或语音。
3. 读回属性。

预期：volume 保持 `0.20` / `0.25`，`volume_restore_attempted=false`；只有严格小于 `0.2`
的值才恢复到 1。

## 用例三：默认增益

1. 使用没有 `gainDB` 持久化值的新 UserDefaults 启动设置。
2. 使用已保存其它增益值的 UserDefaults 重新启动设置。

预期：新安装默认增益为 `10 dB`；已有用户保存的增益保持原值，不强制迁移到 10。

## 用例四：属性未知或不可写

1. 使用不公开 mute/volume 的受支持回环设备，确认属性读数为 `unknown`。
2. 使用可复现只读或写入失败的测试替身，制造修复后仍明确静音。

预期：属性不存在时保持兼容，不仅因 unknown 阻断；已知静音或低于阈值但写入/读回未恢复时，
配置失败且不得进入 Ready，也不得产生 `delivered_to_selected_device` 的假成功。

## 用例五：启动后再次静音或调低音量

1. 启动 App 并确认虚拟声卡 Ready。
2. 在空闲状态把设备改为 `mute=1 / volume=0` 或 `mute=0 / volume=0.19`。
3. 分别从实体遥控器、iPhone、Apple Watch 和网页开始下一次语音。

预期：每个入口现有的实时音频健康检查发现静音或低音量，重新配置并修复后才接受语音；
不得丢失首字，不得通过 flush 丢弃尾音。

## 稳定功能回归

- 测试音仍能完成真实播放回调。
- RC003 普通 `STREAM_START → AUDIO → STREAM_STOP` 首字低延迟、尾字完整。
- 连续快速语音 generation 相互隔离。
- 物理扬声器、麦克风及未知设备的 mute/volume 不被修改。
- PR #323 的按需占用策略不属于本修复，不能用频繁释放/重建设备代替属性自愈。

## 验证边界

- 自动化证明策略、编译与 MiRemoteV 属性写入路径，不证明真实语音工具已经收到声音。
- 必须使用真实虚拟设备、真实控制来源和真实第三方工具完成最终文字上屏，才能称为完整验收。
- MiRemoteV 2ch 的结果不能替代原生 BlackHole 2ch；后者未完成前保持待验证。
