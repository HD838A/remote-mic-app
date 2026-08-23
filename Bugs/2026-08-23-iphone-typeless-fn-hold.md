# iPhone 语音在 Typeless 模式下长按 Fn 导致无法唤起

- 时间：2026-08-23
- 状态：候选修复完成，等待官方签名构建与 iPhone / Typeless 真机验收
- 影响范围：开启“语音键模拟 Fn 点按”后，通过 iPhone、Watch 或 Web 向 Mac 发送的移动语音会话
- 功能点：移动语音、Typeless Fn 快捷键、虚拟麦克风、音频排空
- 简单描述：手机音频能够完整到达 MiRemoteV，但 Mac 在整段录音期间持续按住 Fn；Typeless 需要一次短按开始、再次短按停止，因此不会被正确呼出。

## 复现证据

1. Mac 已开启“语音键模拟 Fn 点按”，实体小米遥控器能够正常呼出 Typeless。
2. iPhone 已连接 SayAll，点按手机语音按钮并说话。
3. MiRemoteV 收到非零音频，Typeless 历史记录没有新增识别结果。
4. 即使把手机录音缩短到约一秒，仍然无法可靠呼出 Typeless。

正常边界：关闭 Fn 点按模式时，手机语音继续使用原有“开始时按下 Fn、音频排空后释放 Fn”的兼容路径。

## 日志结论

用户现场 `2026-08-23 18:28` 左右的三次短录音均呈现同一种事件顺序：

```text
PHONE VOICE FN DOWN
MOBILE VOICE started source=iphone
MOBILE VOICE audio_summary ... nonzero=... enqueue_failures=0
PHONE VOICE FN UP
MOBILE VOICE stopped source=iphone
```

其中一段为 `batches=7 samples=10960 nonzero=10382 enqueue_failures=0`。这证明手机麦克风、网络传输、Mac 解码和虚拟音频入队均正常；Fn 从会话开始保持到结束，而不是 Typeless 要求的短点按。把录音缩短并不会改变该事件模型。

## 根因

实体遥控器的 Fn 点按模式由 `VoiceFnTapSessionController` 管理，会在开始和停止时分别产生一组约 120 ms 的 Fn 点按，并在首次点按完成前缓存音频。

移动语音路径没有复用该会话控制器。`BridgeAppModel` 原先通过 `VoiceFunctionKeyLatch` 在 `startPhoneVoice` 中发送 Fn Down，在 `stopPhoneVoice` 排空音频后才发送 Fn Up。因此手机、Watch 和 Web 在开启 Fn 点按设置后仍然使用整段长按语义，和 Typeless 的切换式快捷键不兼容。

## 修复

- 新增统一的 `MobileVoiceInputSession`，根据现有 Fn 点按设置选择会话语义。
- Fn 点按开启时：等待目标输入位置、缓存首段音频、短按 Fn 开始、发送完整音频、排空尾音、再次短按 Fn 停止。
- Fn 点按关闭时：保留原有 Fn 长按和直接音频入队行为。
- 移动语音停止完成信号延后到音频排空和第二次 Fn 点按完成，避免快速重启时交错。
- iPhone、Watch 和 Web 共用同一移动语音入口，无需修改客户端协议。
- 日志会为每个真实 Fn 边沿记录 `PHONE VOICE FN DOWN/UP posted`；发送失败记录 `failed` 并关闭点按模式。

## 修改文件

- `Sources/RemoteMic/MobileVoiceInputSession.swift`
- `Sources/RemoteMic/VoiceFnTapSessionController.swift`
- `Sources/RemoteMic/BridgeAppModel.swift`
- `Tests/RemoteMicTests/MobileVoiceInputSessionTests.swift`
- `Testing/iPhoneTypelessFnTap.md`
- `TODO.md`

本次未修改手机协议、PCM 格式、增益、MiRemoteV 声道布局、蓝牙遥控器解码或 Typeless 设置。

## 验证

- 修复前回归测试：`MobileVoiceInputSession` 不存在，测试按预期编译失败。
- 定向回归：移动语音输入、Fn 点按会话和移动停止/重启共 15 项通过。
- `git diff --check`：通过。
- 全量 Swift 测试、自检和 Release 构建：见候选提交验证记录。
- iPhone → Mac → MiRemoteV → Typeless 最终文字上屏：等待官方 Developer ID 签名、公证构建真机验收。

## 验证边界

自动化能够证明两次短点按、首段音频缓存、尾音排空、快速重启以及关闭点按模式后的兼容行为；不能证明 Typeless 对真实 macOS 键盘事件的最终响应，也不能替代 iPhone 网络、虚拟音频设备和第三方 App 的端到端验收。本机没有项目要求的 Developer ID 身份，因此不得安装或分发 ad-hoc、未公证热修复包。
