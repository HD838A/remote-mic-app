# Onboarding 已收到语音但没有文字，诊断事件反复跳变

- 时间：2026-08-29
- 基线：无线麦SayAll.app `1.9.18 (171)`
- 状态：候选修复完成，等待真实第三方语音工具验收
- 影响范围：首次使用向导的语音测试页，尤其是选择“其他语音工具”的用户
- 用户现场：macOS 26、arm64、实体遥控器、语音工具 `other`

## 复现

现场诊断摘要显示一次完整语音操作已经走过无线麦自身链路：

```text
voice_started=true
voice_samples_received=true
voice_ended=true
transcription_appeared=false
failure=voice.no_transcript
```

蓝牙、输入监控、辅助功能、控制连接、音频设备和输出均为可用。用户按下并松开语音键后，向导输入框没有出现文字，因此不能进入下一步。

同一现场的 `recent_events` 在几秒内反复记录：

```text
voice.no_samples → voice.session_not_ended → voice.no_transcript
```

每个中间状态又分别产生 `blocked` 与 `recovered`，无法判断这些记录属于哪一次操作，也无法区分“输入目标没有真正聚焦”和“第三方语音工具收到音频但没有提交文字”。

## 日志结论

1. 可以确认实体遥控器语音会话开始、PCM 样本到达、松开停止和 SayAll 音频输出链路都已发生。
2. 不能确认底层文本控件在语音开始时是否为 `NSWindow.firstResponder`。现有 `focus=true` 只来自 SwiftUI `FocusState`，不是 AppKit responder chain 的事实。
3. 选择“其他语音工具”时，SayAll 不能读取第三方 App 的内部识别、候选或提交状态；合规边界内只能观察自身输入目标和最终是否有文字写入。
4. `voice.no_samples` 和 `voice.session_not_ended` 是正常录音过程中的阶段，不应在一次操作结束前作为终态失败写入历史。

## 假设

### H1：SwiftUI 焦点状态与真实 first responder 不一致（已确认的实现缺陷）

- 支持：语音测试使用 `TextEditor` 和 `@FocusState`，只切换布尔状态；代码没有读取或验证 `NSWindow.firstResponder`。
- 影响：第三方输入工具可能把文字提交到其他控件或没有可写入目标，用户看到“有声音、没文字”。
- 边界：现场摘要本身不能证明这一次一定命中了焦点失配，但当前实现无法排除，也无法诊断。

### H2：诊断器把进行中的阶段误记成独立失败（已确认根因）

- 支持：`FirstUseDiagnosticContext.failureReason` 依次根据当前布尔值返回 `voice.no_samples`、`voice.session_not_ended` 和 `voice.no_transcript`；`OnboardingView.recordFailureTransition` 对每次变化立即写 `blocked/recovered`。
- 最小实验：按代码顺序回放 `started → samples → ended`，不输入文字，即得到现场相同的三段失败跳变。
- 结论：这些日志不是三种独立故障，而是同一次操作的正常阶段加一个终态失败。

### H3：第三方语音工具没有提交文字（现场最高概率边界结论）

- 支持：现场已证明 SayAll 收到并输出音频，最终没有文字。
- 冲突：缺少真实 first responder、焦点丢失时间和文字等待窗口，当前无法把原因唯一归到第三方工具。
- 合规边界：不得读取第三方 App 内部文件、数据库、私有协议或识别状态。

## 根因与修复目标

问题由两个层面共同造成：

1. 语音测试页没有以 AppKit responder chain 建立并验证真实文字输入目标，仅依赖 SwiftUI `FocusState`。
2. 诊断记录没有“单次语音尝试”概念，把正常中间阶段当成失败，且缺少输入目标、关键时延、单一终态和第三方边界字段。

候选修复必须保持原有严格门槛：只有真实语音会话开始、收到 PCM、会话结束、文字实际进入向导输入框且不是物理键盘手输，才能继续。不得通过跳过、手动确认或放宽门槛绕过问题。

## 计划中的最小修复

1. 在语音测试页使用本文件内的最小 `NSViewRepresentable` 文本编辑器，由 SwiftUI `Binding<String>` 继续作为文字状态源；AppKit 只负责 `NSTextView` 生命周期、first responder 请求和真实焦点回报。
2. 每次语音键按下建立递增的 attempt，状态只沿 `idle → recording → awaiting_transcript → passed/failed` 前进；一次 attempt 只产生一个终态。
3. 松开语音键后保留短暂文字提交等待窗口；等待期不记录 `voice.no_transcript`。
4. 脱敏诊断增加 attempt、触发路径、触发键模式、输入框挂载、窗口 key 状态、语音开始/结束时 first responder、焦点丢失、首个样本延迟、会话时长、文字等待时长、单一终态、最高概率原因和诊断边界。
5. 不记录用户文字、文字长度、语音内容、前台 App、输入来源 PID、键码、蓝牙地址或设备 UID。

## 验证要求

1. 自动化回放一次完整语音 attempt，证明中间阶段不再写入多个失败终态。
2. 验证有文字时仍需同时满足开始、PCM、停止和非手动输入门槛。
3. 验证无文字时只在等待窗口结束后得到一个终态，并能区分输入目标未就绪、焦点丢失、无样本、未结束和外部工具未提交。
4. 验证诊断文本只包含规范化状态与毫秒时延，不包含正文、路径、设备标识或第三方内部数据。
5. 使用真实 RC003 与豆包、微信、Typeless、至少一个“其他语音工具”分别验收文字上屏；自动化和构建不能替代该边界。

## 候选修复验证

- `swift test --filter OnboardingFlowTests`：37 项通过。
- `swift test`：426 项、37 个 suite 通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：44 项通过。
- `swift build -c release`：Production 配置构建通过。
- `git diff --check`：通过。
- 使用生产 `OnboardingView` 离屏生成浅色/深色实体遥控器路径各 9 张 PNG，全部为 `2040 × 1608`；逐张查看未发现新输入框裁切或外观分裂。
- 尚未在真实 RC003、豆包、微信、Typeless 或其他第三方语音工具中确认文字提交；本候选不能替代该现场验收。
