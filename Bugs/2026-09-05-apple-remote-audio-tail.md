# Siri Remote 松键后 MiRemoteV 2ch 电平偶发残留

## 复现与现场证据

- 设备：Apple Siri Remote A2854。
- 路由：遥控器麦克风 → PacketLogger XPC/HCI → Opus → PCM → `MiRemoteV 2ch` → 豆包。
- 现场表现：松开 Siri/语音键后，电平图偶尔仍继续波动；不是每次发生。
- 最近一次日志显示按键释放、PacketLogger 停止、Fn 释放和语音会话结束均出现，未发现释放事件丢失。

## 根因

Apple Remote 路径在 `BridgeAppModel.endAppleRemoteVoice` 中调用
`endVoiceSessionIfNeeded(flushAudio: false)`。这会停止采集，但保留已经排入
`AudioOutput` 的 PCM buffer，导致 `MiRemoteV 2ch` 继续收到尾部数据。尾部长度受
PacketLogger、Opus 解码和主线程排队时序影响，因此表现为偶发。

同时，`AppleRemoteAudioClient` 的 PCM 回调通过主队列异步投递，停止后已经排队的
回调原先没有 capture generation 保护，无法区分“当前会话数据”和“停止后的迟到数据”。

## 首版修复风险复核

首版曾把 Siri Remote 释放改为立即 flush，并立即关闭 capture generation。复核发现
`interrupted_samples > 0` 代表尚未播放的有效尾音被主动丢弃，迟到但仍属于本次会话的
PCM 也可能被 generation gate 拒绝，存在丢最后一个字的风险，因此该方案不作为最终实现。

本机真实 A2854 日志已直接证明该风险：四次会话分别中断了 2560、1600、2560、1600
个 16 kHz 样本，即主动截断约 160 ms、100 ms、160 ms、100 ms 的尾音。这一长度足以
影响最后一个音节或辅音，不能接受。

## 最终停止模型

1. Siri 键松开后进入 `closing`，立即要求遥控器停止继续采集，但保留当前 generation。
2. helper 确认停止后，PacketLogger/Opus 链路继续接收同一会话的在途尾包；连续 300 ms
   没有新的已解码 PCM，且主线程在途 PCM 投递数归零后才关闭 generation。
3. 所有同 generation PCM 提交到 `AudioOutput` 后，等待播放队列自然排空，不设置正常路径
   的强制 flush 超时。
4. 队列排空后才释放 Fn 并结束语音会话。正常路径要求 `interrupted_samples=0`。
5. 只有 helper 无响应、断连或 App 退出等异常恢复路径可以强制终止，并记录
   `completion=forced`、原因和可观测的中断样本数。
6. 释放时记录 pending、played、interrupted 的前后快照，确保能区分：
   - 采集仍在运行；
   - PCM 迟到回调；
   - AudioOutput 队列未清空；
   - 输出队列已清空但第三方电平图仍有外部延迟。
7. 如果松开后立即再次按下：
   - helper 尚未完成 stop 时恢复同一 generation，并按 stop → start 顺序继续采集；
   - helper 已停但 `MiRemoteV 2ch` 仍在排空时，取消旧 drain、启动新 generation，保留同一
     Fn/语音会话，不等待旧队列排空才重新开麦。

## 变更位置

- `Sources/RemoteMic/AppleRemoteAudioClient.swift`
- `Sources/RemoteMic/AppleRemoteHCIConfigurationClient.swift`
- `Sources/AppleRemoteHCIService/main.swift`
- `Sources/RemoteMic/BridgeAppModel.swift`
- `Tests/RemoteMicTests/AppleRemoteAudioTests.swift`
- `Testing/AppleRemoteHardwareInterface.md`
- `TODO.md`

## 验证

- 自动化：generation gate 验证停止后的旧回调被拒绝，以及新会话不会接受上一代回调。
- 自动化：`swift test --filter AppleRemoteAudioTests` 通过（9 项）；新增 HCI XPC 诊断代码编译通过。
- 构建：Developer ID Application `L3QHLDRPAY` Release App 构建成功，`codesign --verify --deep --strict` 通过；签名构建已进入 `packet_stream phase=ready result=authorized`。
- 真机边界：需要在 A2854 + `MiRemoteV 2ch` + 豆包上完成 10 次短按、5 次持续录音，并检查 `playback_stop` 的 pending 字段。

## 日志判断

成功停止应满足：

```text
APPLE REMOTE AUDIO capture_stop phase=completed result=tail_settled completion=normal
APPLE REMOTE AUDIO playback_stop phase=completed result=drained
pending_after_buffers=0 pending_after_samples=0 interrupted_samples=0
```

`closing_samples` 表示松键后仍属于原会话、且已经正常送入输出队列的在途尾音。
正常结束不应出现该 generation 的 `stale_generation`。如果 `completion=forced` 或
`interrupted_samples > 0`，本次会话必须标记为存在丢尾音风险，不能判定通过。

快速再次按下的成功日志应额外满足：

```text
APPLE REMOTE VOICE phase=resumed result=continued_session reason=rapid_repress
```

第二段开头的 PCM 不得出现 `stale_generation`；若出现 `deferred reason=previous_session_draining`，
本次连续语音用例判定失败。

## HCI 授权故障的一次性定位

App 侧会记录 `APPLE REMOTE HCI XPC phase=connecting`，其中包含客户端 Bundle ID、
Team ID 是否匹配以及是否为 ad-hoc 签名；远端代理错误会额外记录 `error_domain` 和
`error_code`。root helper 侧通过统一日志记录 `connection_rejected reason=` 的具体阶段，
包括 `guest_code_lookup_*`、`identifier_mismatch`、`team_mismatch`、`adhoc_signature`
和 `requirement_validation_*`。因此 `hci_helper_unreachable_4097` 不再需要靠猜测区分
helper 未运行、客户端未签名和安全策略拒绝。
