# 增益说明被错误分隔为独立设置行

## 复现

- 环境：用户提供的“连接与语音”页面浅色截图。
- 操作：查看“语音输出”分区中的“增益”滑块及其下方“0 dB 保持原始音量…”说明。
- 实际结果：增益控件与说明之间出现一条完整的系统行分隔线，说明看起来像下一项独立设置。
- 预期结果：说明直接解释增益设置，应与滑块属于同一表单行；分隔线只出现在这组内容与下一项“音频状态”之间。

## 日志结论

检查截图时段以及最近运行日志，没有发现 SwiftUI、布局约束、资源加载或窗口错误。本问题是稳定的静态视图层级错误，不是运行时状态异常。

## 反馈循环

修复前运行结构门禁：

```text
FAIL: gain help is still a separate Form row with its own separator
```

门禁同时要求 `audioSettingsPanel` 只引用一个 `audioGainSettingsRow`，并要求该行内部同时包含增益 `LabeledContent` 与 `audio.gain.help`。

## 根因

`audioSettingsPanel` 直接把增益 `LabeledContent` 和说明 `Text` 写成 grouped `Form` 的两个相邻子视图。系统正确地把它们识别为两个设置行，并自动在两者之间绘制分隔线。源码中没有手写 `Divider`，说明也不是整个“语音输出”分区的 footer。

## 修复

- 新增 `audioGainSettingsRow`，使用一个左对齐 `VStack` 同时承载增益控件和说明。
- `audioSettingsPanel` 只把该组合视图作为一个表单行。
- 保留原文案、滑块 `0...24` 范围、1 dB 步长、绑定、数值显示和后续音频状态/操作。
- 新增设置页源码回归测试，锁定说明与控件必须位于同一行的结构。

## 验证

- 原结构门禁修复后输出：`PASS: gain help is inside the same Form row as the gain control`。
- `swiftc -frontend -parse Sources/RemoteMic/SettingsView.swift Tests/RemoteMicTests/SettingsPageRegressionTests.swift`：通过。
- `git diff --check`：通过。

## 验证边界

Xcode 27 下 30 项设置页测试、342 项全量测试、成品构建与完整性检查通过；中文浅色/深色 `800 × 650` 和浅色 `920 × 700` 连接页确认说明与增益属于同一行。英文长文案换行仍按测试手册人工复核。
