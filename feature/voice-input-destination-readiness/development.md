# 开发记录

## 关键设计

1. `BridgeAppModel` 在执行内置 App、自定义 App 或自定义快捷键前登记目标意图；Fn 模式关闭时不创建等待请求。
2. `VoiceInputDestinationCoordinator` 观察 system-wide Accessibility 最终焦点，而不是信任“启动请求已提交”或专用聚焦函数返回值。
3. 明确目标 App 时要求 focused 元素属于该 Bundle ID；未知全局快捷键允许采用切换后的第一个 App，采用后若再次切换则取消。
4. 只接受启用、可编辑、非受保护的文本区域、文本框或组合框；密码、Token、密钥等语义字段拒绝。
5. `VoiceFnTapSessionController` 在等待期间沿用 pre-roll 缓存，目标就绪后开始；无 pending 时保持旧 150 ms 时间线。
6. 最大等待 5 秒，缓存上限同步扩大为 5 秒 16 kHz Int16 音频。取消后在当前物理语音停止前抑制残余音频，避免回落到另一条输出路径。

## 涉及文件

- `Sources/RemoteMic/VoiceInputDestinationCoordinator.swift`：目标意图、系统焦点快照、安全分类、等待和取消状态机。
- `Sources/RemoteMic/VoiceFnTapSessionController.swift`：接入目标 readiness，扩大 pre-roll，并处理等待取消。
- `Sources/RemoteMic/BridgeAppModel.swift`：统一 HID、手机和网页动作执行入口，登记目标并显示轻量状态。
- `Tests/RemoteMicTests/VoiceInputDestinationCoordinatorTests.swift`：目标状态机和安全分类。
- `Tests/RemoteMicTests/CoreVoiceInputJourneyTests.swift`：App 动作到第一次语音的连续旅程。
- `Tests/RemoteMicTests/HardwareSimulationIntegrationTests.swift`：RC001/RC003 协议事件到首次 Fn 语音的模拟硬件旅程。

## 已确认根因

现场 `APP ACTION opened` 与 `APP FOCUS succeeded` 相差 2～3 秒，旧 Fn 会话固定 150 ms 后启动。修复前复合测试稳定记录提前 Fn 和 `start_tap_failed`，证明问题是跨组件竞态，不是 Codex 专用选择器或“三次计数”。详细证据见 [`Bugs/2026-08-11-voice-input-before-target-focus.md`](../../Bugs/2026-08-11-voice-input-before-target-focus.md)。

## 已知限制

- 未知全局快捷键无法从系统层面证明用户意图，只能采用快捷键后出现的前台 App；一旦采用后再次切换会取消。
- 真实第三方 App 可能使用非标准或动态 Accessibility 控件，必须通过预览版实测确认。
- 自动化可以证明事件、缓存和 Fn 配对，不能证明最终第三方输入法文字上屏。
