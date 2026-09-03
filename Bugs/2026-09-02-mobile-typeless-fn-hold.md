# 移动语音在 Typeless 模式下错误地长按 Fn

- 时间：2026-09-02
- 状态：候选修复完成，等待 iPhone、Apple Watch、Web 与 Typeless 真机验收
- 影响范围：开启“语音键模拟 Fn 点按”后，从 iPhone、Apple Watch 或 Web 发起的 Mac 端语音会话
- 功能点：移动语音、Typeless Fn 点按、虚拟麦克风、尾音排空
- 简单描述：移动音频能够进入 MiRemoteV，但 Mac 在整段会话中持续按住 Fn；Typeless 需要短按一次开始、再短按一次停止。

## 复现

触发条件：

1. Mac 选择 Fn/地球键并开启“语音键模拟 Fn 点按”。
2. 从 iPhone、Apple Watch 或 Web 开始移动语音。
3. 说话后停止会话。

修复前代码路径稳定执行 `Fn Down → 整段音频 → drain → Fn Up`，而不是 Typeless 需要的 `Fn Tap → 音频 → drain → Fn Tap`。正常边界是关闭 Fn 点按模式后仍应保持原有长按语义。

## 日志结论

旧现场的多次短录音均记录：

```text
PHONE VOICE FN DOWN
MOBILE VOICE started source=iphone
MOBILE VOICE audio_summary ... nonzero=... enqueue_failures=0
PHONE VOICE FN UP
MOBILE VOICE stopped source=iphone
```

其中音频统计存在非零样本且无入队失败，证明手机采集、传输、Mac 解码和虚拟音频链路已经工作。错误集中在系统 Fn 事件从开始保持到停止，与 Typeless 点按切换语义不一致。

## 代码根因

当前 `BridgeAppModel.startPhoneVoice` 无条件通过 `updateVoiceKeyState(... owner: .mobile)` 按下当前语音键；`stopPhoneVoice` 只在音频排空后释放。因此 `voiceFnTapModeEnabled` 只影响实体遥控器的 `VoiceFnTapSessionController`，没有进入移动语音 start/receive/stop 路径。

最小失败实验是在最新 `origin/main` 增加移动会话回归测试；修复前测试因不存在移动 Tap/Hold 适配器而编译失败，确认当前主线没有相应行为。

## 修复

- 新增独立 `MobileVoiceInputSession`，在每次会话开始时快照 Tap 或 Hold 模式。
- Fn Tap 模式复用现有 `VoiceFnTapSessionController`：等待目标就绪、缓存首段音频、短按 Fn 开始、播放音频、排空尾音、短按 Fn 停止。
- 非 Fn Tap 模式继续通过现有 `.mobile` owner 按住并释放 Fn、左 Command 或右 Command，不改变兼容路径。
- iPhone、Apple Watch 与 Web 继续复用同一个 Mac 移动语音入口，不修改客户端协议、PCM 格式或来源互斥规则。
- 停止完成和快速重启延后到音频排空及第二次 Fn 点按完成；App 退出时取消等待回调并释放可能保持的按键。
- 移动 Tap 日志使用 `MOBILE VOICE FN TAP DOWN/UP posted|failed`，不记录音频或识别文字。

## 自动化验证

- 修复前：`swift test --filter MobileVoiceInputSessionTests` 因 `MobileVoiceInputSession` 不存在而按预期编译失败。
- 修复后：`MobileVoiceInputSessionTests` 8 项通过，覆盖正常双点按、长按兼容、开始点按前停止、开始点按失败、停止点按失败、失败回退先于延迟重启、Bridge 模式选择和 App 退出释放。
- 受影响稳定基线通过：`VoiceFnTapSessionControllerTests` 8 项、`MobileVoiceLifecycleTests` 5 项、`VoiceFunctionKeyLatchTests` 4 项、`WatchBluetoothVoiceJourneyTests` 4 项、`VirtualAudioConnectionLifecycleTests` 21 项。
- `swift test` 全量 446 项通过；`./scripts/test.sh` 44 项通过；`swift build -c release` 通过。构建仅出现仓库既有 macOS API 弃用警告。

## 真机验证边界

自动化能证明 Mac 端事件顺序、音频 pre-roll、尾音排空和会话清理；不能证明 Typeless 最终收到真实 Fn 事件或文字完整上屏。合入或发布前仍需使用官方签名、公证候选完成：

1. iPhone、Apple Watch、Web 各自的正常和极短语音。
2. Typeless 第一次会话成功、首字尾字完整、连续快速重启不交错。
3. 关闭 Fn Tap 后豆包等长按工具继续工作。
4. 权限撤销、目标等待取消、断线和 App 退出后 Fn 不残留。
