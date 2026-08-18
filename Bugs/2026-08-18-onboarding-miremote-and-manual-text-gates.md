# Onboarding 非 MiRemote 与手动文字错误通过

- 时间：2026-08-18
- 状态：候选修复完成，等待真实语音工具验收
- 影响范围：首次 Onboarding 音频设备页与语音文字测试页

## 复现

1. 音频页选择 Beosound、BlackHole 或其他非 `MiRemoteV 2ch` 设备；旧策略只检查所选 UID 是否仍存在，因此可以继续。
2. 完成一次有开始、PCM 样本和松开结束、但没有文字的语音会话；随后在测试输入框用键盘输入任意文字，旧实现会把输入框非空直接视为文字上屏成功。

用户截图显示语音页环境为 `Beosound A1 2nd Gen`，实时检查已收到声音但尚无文字。现有定向测试 `audioStepOffersEveryAvailableOutputInsteadOfRequiringMiRemote` 仍然通过，直接复现了第一项旧策略；流程能力模型也只有 `transcriptionAppeared` 布尔值，没有手动键盘来源状态。

## 日志检查

本机 `runtime.log` 最后更新时间早于本次反馈，且没有能与截图对应的 Onboarding 事件，因此不作为现场证据。两个问题均由当前流程策略和自动化模型稳定复现：设备策略接受任意存在的 UID，文字策略接受任意非空文本。

## 根因

1. `OnboardingAudioSelectionPolicy` 只验证“所选设备仍存在”，页面同时展示全部系统输出设备，没有验证所选设备是否为 `MiRemoteV 2ch`。
2. `transcriptionAppeared` 只检查输入框去除空白后是否非空；语音会话结束后的键盘输入与第三方语音工具写入没有区分。

## 修复

1. Onboarding 音频页只展示 `DoubaoAudioDevicePolicy` 识别到的 `MiRemoteV 2ch`，继续和完成页均要求它被实际选中；主设置页仍保留原有普通设备选择能力。
2. 每次所选来源开始新的语音会话时清空旧文字和上一次手动输入状态。
3. 输入框聚焦时由本地键盘事件产生的非空变化会标记为手动输入；该状态不能满足文字门禁，页面提示重新使用语音键。
4. 诊断新增 `voice.manual_input` 和不含文字内容的布尔字段，不记录用户输入内容。

## 验证

- 修改前：`audioStepOffersEveryAvailableOutputInsteadOfRequiringMiRemote` 通过，证明替代设备被明确允许。
- 修改后：Onboarding 定向测试 23 项通过，覆盖非 MiRemote 拒绝、MiRemote 缺失、手动键盘输入阻塞、真实文字状态及对应失败码。
- 完整 Swift 测试 235 项、项目自检 42 项和 Debug 构建通过。
- 中英文字符串与 diff 格式检查通过；实体遥控器路径音频页、语音页的浅色和深色生产截图已逐张检查，无裁切、内部滚动或黑白分栏。

## 验证边界

自动化不能证明豆包、微信输入法、Typeless 或其他语音工具在真实 Mac 上写入文字时不会被系统标记成键盘事件。真实 `MiRemoteV 2ch`、实体遥控器、iPhone、网页版及第三方语音工具仍需按测试手册验收。
