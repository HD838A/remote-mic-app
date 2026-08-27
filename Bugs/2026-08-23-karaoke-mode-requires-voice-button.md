# 卡拉 OK 开启后仍需按住语音键

- 时间：2026-08-23
- 状态：根因已由 RC003 真机日志确认；已撤回无效的持续开麦状态机，改为按真实语音流自动本地路由
- 影响范围：macOS 本地卡拉 OK；模式关闭时的普通语音不应受影响
- 最终行为：任意普通按键的单击、双击或长按只负责切换本地路由；开启后，按住遥控器语音键产生的真实音频自动输出到物理扬声器，松开结束本段，再次按住自动开始下一段

## 1. 复现 Bug

### 可重复触发条件

1. 把确定键或其他普通键的某个手势映射为“切换本地卡拉 OK”。
2. 执行该手势开启模式，此后不触碰语音键并对遥控器说话。
3. 再按住语音键说话，对比两种会话的日志和实际声音。

### 错误行为

- 开启后主机主动发送 `MIC_OPEN`，遥控器只返回 `STREAM_START session=0`，没有任何 PCM，约 1.5 秒后关闭。
- 按住语音键后出现非零 session 的 PCM，旧实现却会把它记为 `audio_confirmed`，让页面看起来像免按键已经成功。
- 实际体验仍依赖按住语音键，和切换式持续返听目标不符。

### 原期望与硬件边界

- 原期望是映射手势开启后无需再按键持续拾音，但该 RC003 固件没有提供这种真实 PCM。
- 只有主机主动会话的真实 PCM 才能证明免按键拾音；单独收到控制事件或实体语音键的 PCM 都不能算成功。
- 在无法改变遥控器固件的边界内，合理行为是让模式只控制路由，并保留遥控器标准“按住收音、松开停止”的 PTT / HTT 交互。

## 2. 查看日志

现场日志 `/Users/anlewo/Library/Logs/RemoteMic/runtime.log` 在 UTC 13:17 显示：

```text
HID GESTURE button=ok trigger=doubleClick
KARAOKE MODE enabled trigger=button_mapping
ATVV MIC_OPEN host_request
ATVV STREAM START session=0
KARAOKE HOST_OPEN fallback reason=audio_timeout close_written=true
ATVV STREAM summary ... batches=0 samples=0
```

UTC 13:37 附近出现的 `audio_confirmed` 都紧随实体语音键 HID 报告，音频会话是 `session=61/62`，而不是主机主动会话 `session=0`。因此旧日志中的“确认”是假阳性。

同一日志记录 `default_input={name=MacBook Air麦克风 id=81}`。这只能说明 Codex 的免按键语音可以使用 Mac 的 Core Audio 输入，不能证明 RC003 固件已经在无按键时发送 PCM。

2026-08-24 复核用户点击 ChatGPT 语音按钮的同一现场时间段，macOS Core Audio 统一日志显示 `BuiltInMicrophoneDevice` 由 ChatGPT 音频服务 PID 启停，并有非静音输入；SayAll 没有产生新的 ATVV 流。因此 ChatGPT 的免按键录音是 Mac 物理麦克风基线，不是 RC003 主动开麦成功。

新增 `scripts/verify-rc003-hold-to-talk.sh` 后，对现场最近一次卡拉 OK 会话得到：

```text
evidence on_request=1 host_attempts=4 host_empty=4 host_audio=0 htt_streams=3 htt_audio=3
result=requires_voice_button reason=host_open_empty_remote_htt_has_pcm
```

该结果把“主动请求已响应”和“实际产生 PCM”分开，并要求同一会话存在实体 HTT 有声对照，避免把连接、解码器或输出故障误判为遥控器必须按住。

## 3. 查看代码与根因

1. 初始 ATVV v1.0 `GET_CAPS` 同时声明 PTT 与 HTT，随后直接发送 `MIC_OPEN`，没有为持续主机请求重新协商 On-Request 模式。
2. `XiaomiBluetoothBridge` 只记录一个可被后续 `STREAM_START` 覆盖的 `sessionID`，没有把 `AUDIO_START` 的 reason/session 转为明确来源。
3. `BridgeAppModel` 通过“主机开麦正在等待”推断流来源；因此实体 HTT 流到来时也会被当作主机主动流。
4. 空流超时后旧实现降级为“按住语音键返听”，这与本功能的切换式持续拾音定义冲突。
5. 后续候选实现虽然补充了 On-Request、来源分类、重试与 `MIC_EXTEND`，但现场判定器仍确认主机 4 次只有空流，而实体 HTT 3 次均有 PCM；协议控制命令无法令当前 RC003 固件真正持续采集。
6. 根本错误不是物理输出播放器，而是产品状态机假定“模式开启”等于“遥控器已经能持续送流”。这导致无效空流、重试和保活常驻，并让界面承诺了硬件不能提供的能力。

## 4. 最终修复

1. 卡拉 OK 开关只保存当前会话中的目标遥控器和物理输出，不再协商 On-Request、发送主动 `MIC_OPEN`、等待空流、自动重试或发送 `MIC_EXTEND`。
2. 目标遥控器按住语音键后仍走标准 ATVV `STREAM_START → AUDIO → STREAM_STOP`；模式开启时把解码 PCM 送入独立物理输出，模式关闭时继续送入原虚拟麦克风 / Fn 路径。
3. 每段流结束后保留卡拉 OK 开启状态并回到“等待按住语音键”；下一段真实语音流自动重新使用物理路由。
4. 模式进行中被关闭时只关闭当前活动流，并保留 2 秒关闭超时与断线恢复保护；空闲关闭不会发送无意义的蓝牙控制命令。
5. 页面、README、TODO 和测试手册全部改为准确描述硬件边界，不再宣称免按键持续拾音。

## 5. 验证

- `scripts/test-rc003-hold-to-talk-verifier.sh` 覆盖：确认必须按住、主动持续 PCM 成功、缺少实体对照、只有实体流、非 RC003、对照顺序错误、只判读最近会话；七类夹具通过。
- `scripts/verify-rc003-hold-to-talk.sh` 对当前现场日志返回 `requires_voice_button`。这是真实日志判定，不代表代理重新操作了实体硬件。
- 合入最新 `origin/main` 后重新执行 `swift test`：347 项、34 个 suite 全部通过；本地卡拉 OK 聚焦测试 7 项通过。
- `scripts/test.sh`：42 项自检全部通过。
- `scripts/build-app.sh`：`1.9.8 (131)` Release App 编译成功；`codesign --verify --deep --strict` 通过，签名为用户 Developer ID，Team ID `FH5RUQGB5U`，Hardened Runtime 有效。
- 新 App 与 `/Applications/SayAll.app` 的 bundle identifier、Team ID 和 designated requirement 一致，满足沿用现有 TCC 身份的代码签名边界；当前本地构建未提交 Apple 公证，不能当公开安装包发布。
- 最终签名 App 已在 `800 × 650` 重新检查中文浅色、中文深色和英文浅色“连接与语音”页面，“开启后按住语音键返听”的开关语义与安全说明完整可见。
- 针对性测试覆盖任意普通按键手势映射、默认无绑定、主机与实体语音流来源区分、稳定路由隔离，并静态确认卡拉 OK 状态机不再包含主动开麦、重试、保活或能力恢复。
- 自动化能证明编译、路由策略、状态机边界和历史日志判定器，不能替代新设备、新固件或真实声学输出。
- 真机通过标准：开启并空闲时没有主机主动开麦；连续多次按住语音键均出现 `route=local_karaoke accepted=true` 且耳机可闻，松开后停止；关闭后普通按住语音走虚拟麦克风，前后台、断连重连、锁屏睡眠和多遥控器隔离均正常。
