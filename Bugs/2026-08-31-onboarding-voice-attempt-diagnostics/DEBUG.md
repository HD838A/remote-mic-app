# Onboarding 语音诊断无法区分焦点、音频输出与第三方未提交

## Observations

- 现场版本为无线麦SayAll.app `1.9.19 (172)`、macOS 26、arm64、豆包输入法、Fn、实体遥控器。
- 单次终态为 `voice.input_target_focus_lost`，但同时存在 `voice_first_responder_at_start=true`、`voice_first_responder_at_end=true`、`voice_focus_lost=true`。这只能证明中间至少出现过一次瞬时异常快照，不能证明结束时仍失焦。
- 本次会话时长仅 `793ms`，首个样本延迟为 `0ms`，最终没有文字；摘要没有记录会话过短是否可能影响外部工具提交。
- `BridgeAppModel.bluetoothBridge(_:didDecode:)` 在调用 `audioOutput.enqueue(samples:)` 后，无论返回成功还是失败，都会调用 `publishCurrentVoiceSampleReceiptIfNeeded`。因此 `voice_samples_received=true` 只证明 SayAll 收到并解码 PCM，不证明 PCM 已成功送入虚拟输出。
- `bluetoothBridgeDidStartVoice` 会在开始前执行实时音频健康检查；会话能够开始说明当时引擎、播放器和设备绑定通过检查，但不能证明整个 attempt 内持续健康。
- `VirtualAudioOutput.diagnosticState()` 已能检查引擎、播放器、所选设备、AudioUnit 实际设备及绑定结果；ATVV 运行日志也已有批次、样本、入队失败、pending buffer 和排空事件，但这些事实没有进入用户可复制的 Onboarding 诊断，也没有与 Onboarding attempt ID 关联。
- `OnboardingView.updateTranscriptFocus` 只要录音或等待期间出现一次 editor 未挂载、window 非 key 或 first responder 不匹配，就永久设置 `focusLost=true`。诊断没有记录异常维度、发生阶段、次数、首次/末次时间和恢复耗时。
- `voice_probable_cause` 当前直接复制 `voice_terminal_result`，没有 `confirmed` 标记，不符合 `LOGGING.md` 对事实、未知和推测分离的要求。
- 无法在代理环境复现用户真实豆包输入法和实体遥控器提交失败；当前可重复复现的是诊断数据模型无法区分多个候选原因。
- 用户随后确认：豆包输入法内部选择了错误的麦克风，手动改为与 SayAll 输出一致的 `MiRemoteV 2ch` 后立即恢复。该反馈确认了本次现场的第三方麦克风配置根因，但不改变 SayAll 无法通过公开接口自动读取豆包内部设置的边界。

## Hypotheses

### H1：Onboarding 诊断投影丢失关键音频与焦点时序（ROOT HYPOTHESIS）

- Supports：音频运行层已有实际绑定、入队和排空信息，但 `FirstUseVoiceAttemptDiagnostic` 没有对应字段；焦点只保存粘滞布尔值；`probable_cause` 直接复制终态。
- Conflicts：无。
- Test：沿实体遥控器数据流静态回放 `decoded → enqueue(false) → publish receipt`，并构造开始/结束聚焦但中间异常的 attempt，确认两者在现有摘要中分别仍表现为 `samples_received=true` 和 `input_target_focus_lost`，无法唯一定位。

### H2：用户现场的虚拟音频输出实际失败

- Supports：摘要没有入队成功、实际设备绑定和排空证据；`hasReceivedCurrentVoiceSamples` 不受 enqueue 结果约束。
- Conflicts：会话开始前实时健康检查已通过，`audio_output_ready=true`；历史实现会在 stale 时重绑并在失败时拒绝开始，因此现场发生全程错误路由的概率低于诊断缺失。
- Test：取得同一 attempt 的 `ATVV STREAM summary`、`AUDIO WRITE rejected` 和 `AUDIO PLAYBACK drained/interrupted`；当前用户摘要未包含这些事实。用户修正豆包麦克风后同一链路恢复，进一步降低了 SayAll 输出失败的可能性。

### H3：豆包面板引起瞬时焦点波动，但输入目标随后恢复

- Supports：开始和结束 first responder 均为 true，只有粘滞 `focusLost=true`；物理遥控器路径无需用户点击其他窗口。
- Conflicts：没有焦点事件时间线，不能确认波动来自豆包、SwiftUI/AppKit 生命周期还是其他窗口事件。
- Test：记录每次焦点异常的维度、阶段、次数、首次时间、末次时间和恢复耗时；只有截止时仍异常才归类为持续失焦。

### H4：793ms 会话过短，豆包没有产生可提交的识别结果

- Supports：有效会话不足一秒，最终无文字；第三方语音识别通常需要足够语音时长。
- Conflicts：SayAll 无法读取豆包内部识别状态，也不能定义豆包的精确最短提交时长。
- Test：把 `session_duration_ms` 作为已观察事实，并将“短会话”仅作为未确认候选，不覆盖音频或焦点的确定失败。

### H5：豆包内部麦克风没有选择 SayAll 当前输出的虚拟设备（现场根因）

- Supports：用户将豆包麦克风手动改为 `MiRemoteV 2ch` 后立即恢复；该设置与 SayAll 音频页选择分别位于虚拟设备两端，SayAll 不会自动修改豆包内部设置。
- Conflicts：SayAll 无法使用公开接口读取豆包内部麦克风，因此不能由自动日志直接确认该字段。
- Test：用户在豆包公开设置界面将麦克风从错误设备改为 `MiRemoteV 2ch`，原路径从失败变为通过。
- Result：confirmed by user reproduction。日志必须把 SayAll 输出验证和外部工具麦克风不可观察状态分开，并记录配置检查是用户确认而非自动检测。

## Experiments

### E1：静态数据流回放 H1

- `didDecode` 中 `enqueued` 失败只增加 `bluetoothVoiceEnqueueFailureCount`，随后仍发布 `hasReceivedCurrentVoiceSamples=true`。
- Onboarding 只订阅 `hasReceivedCurrentVoiceSamples`，可复制摘要没有读取 `bluetoothVoiceEnqueueFailureCount`、实际 AudioUnit 绑定或播放排空结果。
- `FirstUseVoiceAttemptPolicy` 在无文字时只要 `focusLost=true` 就优先返回 `input_target_focus_lost`，不考虑焦点是否已经恢复。
- 结果：H1 confirmed。现有摘要可以把“音频入队失败”和“收到且成功播放”都表示为 `voice_samples_received=true`，也会把“瞬时失焦后恢复”表示为确定的焦点失败。

## Root Cause

诊断缺陷的根因是 Onboarding 只采集上游收到样本和粘滞失焦布尔值，没有把同一次 attempt 的实际音频路由、入队、播放排空、焦点转换和“第三方麦克风不可自动观察”边界关联起来，同时把分类结果直接当作 probable cause。用户现场的功能根因已由用户复验确认为豆包内部麦克风未选择 `MiRemoteV 2ch`。

## Fix

- 将诊断 schema 提升为 `3`，同一 attempt 按 generation 记录音频来源、直连/Typeless Fn 点按路线、收到/调度/实际播放/中断/pending 样本、入队失败、所选设备类型、AudioUnit 实际设备类型和绑定结果。
- 播放计数按语音 generation 隔离，快速连续会话不会把上一会话的迟到播放完成算入下一会话；flush 后迟到 callback 不再修改已结束会话。
- `playback_pending` 和 Fn pre-roll 尚未调度只在三秒观察截止后仍未完成时才判定音频投递失败，避免把正常排空过程误报为失败。
- 焦点记录丢失次数、具体异常维度、首次发生时间、累计持续时间、结束/截止状态和是否恢复；只有截止时仍未就绪才归类为 `input_target_focus_lost`。
- 语音测试页增加不可忽略的双端配置确认卡，明确 SayAll 音频页只设置输出端，豆包/微信/Typeless/其他语音工具还必须在自身设置中选择同一个麦克风。工具或 SayAll 音频设备变化后确认自动失效。
- 第三方工具内部麦克风继续标记为 `observable=false`。当 SayAll 已确认音频完整送达、焦点正常但没有文字时，终态停在 `external_tool_internal_state_unavailable`，并把“麦克风是否与 SayAll 所选设备一致”列为首个检查项，不伪装成自动确认的根因。

## Verification

- `swift test --filter OnboardingFlowTests --filter VirtualAudioConnectionLifecycleTests`：63 项通过。
- `swift test`：435 项、37 个 suite 全部通过。
- `scripts/test.sh`：44 项项目自检通过，并完成 Debug Swift Package 构建。
- `swift build -c release`：Release 构建通过。
- 自动化覆盖持续失焦与瞬时失焦恢复、音频设备未就绪/路由不匹配/入队失败/播放中断/pending、外部麦克风未确认、直接与 Fn 点按路线，以及快速连续 generation 的计数隔离。
- 生产 `OnboardingView` 已生成并逐张检查三种控制方式的浅色/深色完整流程：实体遥控器 18 张、iPhone App 20 张、网页版 20 张，共 58 张；无裁切、内部滚动或明暗分栏。截图只证明静态页面，不替代真实连接和语音链路验收。
- 用户现场已完成真实豆包复验：在豆包设置中把麦克风改为 `MiRemoteV 2ch` 后，原实体遥控器语音路径恢复。
- 实体 RC003 的本次新诊断字段、iPhone Nearby、网页真实 WSS、微信、Typeless 和 BlackHole 仍属于独立真实环境验收边界；不得把自动化、截图或用户的豆包复验表述为这些链路已通过。
