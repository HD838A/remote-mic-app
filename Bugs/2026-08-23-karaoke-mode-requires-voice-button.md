# 卡拉 OK 开启后仍需按住语音键

- 时间：2026-08-23
- 状态：候选修复完成，等待 RC001 / RC003 真机验收
- 影响范围：macOS 本地卡拉 OK；模式关闭时的普通语音不应受影响
- 用户期望：任意普通按键的单击、双击或长按只负责切换模式；开启后蓝牙麦克风持续输出到物理扬声器，不再按任何键，再次执行映射动作关闭

## 1. 复现 Bug

### 可重复触发条件

1. 把确定键或其他普通键的某个手势映射为“切换本地卡拉 OK”。
2. 执行该手势开启模式，此后不触碰语音键并对遥控器说话。
3. 再按住语音键说话，对比两种会话的日志和实际声音。

### 错误行为

- 开启后主机主动发送 `MIC_OPEN`，遥控器只返回 `STREAM_START session=0`，没有任何 PCM，约 1.5 秒后关闭。
- 按住语音键后出现非零 session 的 PCM，旧实现却会把它记为 `audio_confirmed`，让页面看起来像免按键已经成功。
- 实际体验仍依赖按住语音键，和切换式持续返听目标不符。

### 正常行为边界

- 映射手势只应切换模式；无论映射到单击、双击还是长按，开启后都不应再要求任何按键。
- 只有主机主动会话的真实 PCM 才能证明持续拾音成功；单独收到控制事件或实体语音键的 PCM 都不能算成功。
- 再次执行映射手势或点击页面关闭后，应结束主动会话并恢复普通 PTT / HTT 能力。

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

## 3. 查看代码与根因

1. 初始 ATVV v1.0 `GET_CAPS` 同时声明 PTT 与 HTT，随后直接发送 `MIC_OPEN`，没有为持续主机请求重新协商 On-Request 模式。
2. `XiaomiBluetoothBridge` 只记录一个可被后续 `STREAM_START` 覆盖的 `sessionID`，没有把 `AUDIO_START` 的 reason/session 转为明确来源。
3. `BridgeAppModel` 通过“主机开麦正在等待”推断流来源；因此实体 HTT 流到来时也会被当作主机主动流。
4. 空流超时后旧实现降级为“按住语音键返听”，这与本功能的切换式持续拾音定义冲突。
5. 真正连续的 ATVV v1.0 主机会话需要在有效 PCM 后定期发送 `MIC_EXTEND`，旧卡拉 OK 路径没有保活。

## 4. 修复

1. 开启卡拉 OK 时先运行时发送 On-Request-only `GET_CAPS`，协商完成后再发送 `MIC_OPEN`。
2. 根据 `AUDIO_START` 的 reason 和 session 将流标为 `host_mic_open`、`remote_ptt`、`remote_htt` 或 `unknown`；流来源变化时先结束旧会话再开始新会话。
3. 只有 `host_mic_open` 且实际解码出 PCM 的会话才标记为免按键成功。
4. 主机请求没有 `STREAM_START` 或开始后没有 PCM 时，关闭空会话并按 1、2、4、5 秒上限自动重试，不再要求用户按住语音键。
5. 确认主机 PCM 后每 8 秒发送一次 `MIC_EXTEND`；实体 PTT / HTT 流永不触发此保活。
6. 关闭模式后排队恢复标准 PTT + HTT 能力；恢复请求只在音频流停止后发送，避免与关闭中的流竞争。

## 5. 验证

- `swift test`：338 项、32 个 suite 全部通过。
- `scripts/test.sh`：42 项自检全部通过。
- `scripts/build-app.sh`：Release App 编译成功；`codesign --verify --deep --strict` 通过，签名为用户 Developer ID，Team ID `FH5RUQGB5U`，Hardened Runtime 有效。
- 新 App 与 `/Applications/SayAll.app` 的 bundle identifier、Team ID 和 designated requirement 一致，满足沿用现有 TCC 身份的代码签名边界；当前本地构建未提交 Apple 公证，不能当公开安装包发布。
- 最终签名 App 已在 `800 × 650` 检查中文浅色、中文深色和英文浅色“连接与语音”页面，卡拉 OK 开关语义与安全说明完整可见。
- 针对性测试覆盖任意普通按键手势映射、默认无绑定、主机与实体语音流来源区分、有界重试、只有确认的主机 PCM 才保活，以及稳定路由隔离。
- 自动化能证明协议命令、来源分类、重试和路由策略，不能证明 RC001 / RC003 固件会接受运行时 On-Request 协商并持续发送 PCM。
- 真机通过标准：开启后全程不触碰语音键，日志持续出现 `session=0 origin=host_mic_open`、PCM 批次数增长和周期性 `KARAOKE KEEPALIVE written=true`；持续 70 秒以上仍有声音；切换关闭后普通按住语音基线正常。
