# iOS 手机语音键无响应

- 时间：2026-08-03
- 状态：已修复，真机体验曾要求复验
- 影响范围：iOS 0.8.x 与 macOS 1.6.x；手机语音和按键反馈
- 功能点：iPhone 按住说话、Fn/Globe 触发、震动反馈
- 简单描述：手机音频已传输，但 Mac 只记录 Fn 状态而未真正投递系统 Fn/Globe 事件；按键震动时机也绑定在抬起阶段。
- 原始记录：DEBUG.md，首次记录 fd10dd0

## 详细过程

## Observations

- 用户真机反馈：iOS App 已连接，普通遥控按键可用；按住麦克风时 iPhone 出现系统收音指示，但 Mac 与豆包没有响应。
- 用户真机反馈：麦克风键只有松开时能感到震动；期望按下、松开各震动一次。确定键也必须在按下时震动。
- `RemoteControlScreen.setVoiceActive(_:)` 已分别请求按下与松开震动，但 `VoiceButton` 使用 `DragGesture.onChanged` 作为按下入口，不能提供与按钮按压状态同等明确的触摸落下语义。
- 两个确定入口均通过普通 `Button` action 调用 `perform(.confirm)`；SwiftUI 的 Button action 在成功抬起后执行，所以现有确定键震动发生在松手时。
- iOS 录音成功后会持续发送 `voiceStart`、16 kHz 单声道 PCM 和 `voiceStop`；Mac 端已将收到的 PCM 接到现有虚拟音频输出。
- Mac 的手机语音开始路径会调用 `updateVoiceFunctionKeyState(streaming: true)`，但该方法只更新 `VoiceFunctionKeyLatch`、状态文案和日志，没有向系统投递 Fn/Globe 按下事件。
- 实体遥控器可用是因为 RC003 自身会产生 F5 硬件事件，并由 `RemoteVoiceFunctionMapper` 映射为 Fn/Globe；手机不存在这条硬件事件来源。
- 工作区原始状态干净，本次调查前没有未提交修改。

## Hypotheses

### H1: 手机语音路径没有真正产生 Fn/Globe 按键事件（ROOT HYPOTHESIS）

- Supports: 手机语音开始只改变锁存状态并写 `VOICE FN HARDWARE` 日志；代码调用图中没有 CGEvent/IOHID 按下或释放操作。实体遥控器则有独立的 F5 硬件事件来源。
- Conflicts: 无。
- Test: 检查手机语音调用图是否能到达任何系统按键投递 API，并用当前 SDK 构造 Fn 按下事件验证所需 key code 与 modifier flag 可表达。

### H2: Mac 在 `voiceStart` 异步确认期间丢弃了全部音频

- Supports: `PhoneRemoteServer.Client` 在 `isVoiceStarting` 阶段会忽略音频帧。
- Conflicts: 确认窗口只覆盖开始时的少量帧；持续按住后 `isVoiceActive` 会变为 true，后续帧应继续进入输出，无法解释豆包始终没有触发。
- Test: 为开始阶段缓存一帧或记录首帧到达状态，观察持续按住时是否仍无输出。

### H3: iOS 音频转换器没有产生 PCM

- Supports: iPhone 的系统收音指示只证明录音会话已激活，不直接证明转换回调有输出。
- Conflicts: 转换器、tap 和发送路径完整；当前症状首先表现为豆包没有被 Fn 唤起，且没有 iOS 端麦克风错误提示。
- Test: 记录非零 PCM 帧计数，确认 tap 与转换回调是否持续运行。

### H4: Mac 虚拟音频输出未就绪

- Supports: `startPhoneVoice()` 在输出未就绪时会拒绝手机语音。
- Conflicts: 拒绝时 Mac 会回传通用可理解错误，iOS 会结束语音并显示处理提示；用户描述是保持收音但 Mac/豆包无响应。
- Test: 检查语音开始返回值与音频输出就绪状态。

## Experiments

### E1: 验证 H1

- 调用图检查结果：`BridgeAppModel.updateVoiceFunctionKeyState` 没有调用 `KeyboardInjector`、`CGEvent.post` 或 IOHID 投递接口，H1 的缺失路径成立。
- SDK 原型结果：使用 `kVK_Function` 可构造 key code 63 的键盘事件，并可携带 `maskSecondaryFn`；事件字段可被 CoreGraphics 正确表达。
- 结论：H1 confirmed。无需修改网络协议或音频格式即可先修复系统语音键触发断点。

### E2: 验证确定键震动时机

- `Button` action 是现有唯一震动入口，且只在成功抬起时运行。
- 结论：确定键按下无震动由当前事件绑定直接导致。

### E3: 验证麦克风键震动时机

- 按下震动依赖 `DragGesture.onChanged`，松开震动依赖 `onEnded`；两者不是统一的按钮按压状态来源。
- 结论：改用明确的按压状态回调，并保持按下/松开分别触发，可消除按下反馈不稳定。

## Root Cause

手机语音会话只在 Mac 内部记录了 Fn 按下/释放状态，却没有真正投递系统 Fn/Globe 事件；同时 iOS 确定键把震动绑定在抬起 action，麦克风键的按下震动依赖不够明确的拖动变化入口。

## Fix

- 已实施：Mac 手机语音开始/停止时真正投递一次 Fn 按下/释放，并在失败时回滚锁存状态；实体遥控器继续使用自身硬件映射，不产生重复的软件事件。
- 已实施：iOS 麦克风键使用明确的按下/抬起状态回调；两个确定入口在按下时震动、抬起时发送命令。
- 不修改任何布局、网络协议、配对逻辑或音频编码格式。
- 验证：85 项 Swift Testing、36 项 Self Test、macOS Release 构建和 iOS 模拟器构建均通过；模拟器独立 touch down/up 验证麦克风按钮值按“正在准备 → 未录音”变化，且无障碍树只有一个麦克风按钮。
- 待真机验收：iPhone 的实际震动强度与 Mac 上豆包的真实唤起/收音，需要安装包含本修复的新包后确认。
