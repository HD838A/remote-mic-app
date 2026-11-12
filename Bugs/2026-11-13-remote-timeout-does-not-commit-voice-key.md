# 远端 60 秒停止后语音工具没有收到 Fn 抬起

- 时间：2026-11-13
- 状态：候选修复，策略与事件注入自动化待执行；真实豆包 60 秒复测待完成
- 影响范围：macOS 蓝牙遥控器语音键；硬件映射的 Fn 长按模式；远端 60 秒超时停止
- 功能点：语音键结束、第三方语音工具提交与结束
- 简单描述：远端在 60 秒超时停止音频后，App 结束了蓝牙流和本地录音，但没有向目标语音工具发送 Fn 抬起，工具仍停在长按听写状态，因此不提交文字也不结束。
- 开发基线：`origin/main` `6a3075651875a2724013ebce11407302eeb91281`

## 错误证据与日志边界

build 344 的明文日志（2026-11-12 16:09:47–16:10:47 UTC，本机 00:09–00:10）记录了硬件映射 Fn 长按会话：

```text
16:09:47.197 ATVV AUDIO diagnostic ... voice_key_mode=fn voice_fn_tap=false
             trigger_path=hardware_mapping voice_mapping_applied=true
16:10:47.133 ATVV AUDIO diagnostic operation_id=1 phase=stopping reason=remote_stop
16:10:47.133 ATVV STREAM STOP session=116
16:10:47.137 ATVV STREAM tail ... fn_pressed_at_stop=false
16:10:47.135 ATVV AUDIO diagnostic ... phase=software_trigger edge=up mode=fn
             result=hardware_path_unobserved
16:10:47.148 TRANSCRIPT CAPTURE canceled reason=discontinuous_after_finish
```

同一会话的远端控制停止在 build 343 解密日志中为：

```text
60.060s ATVV CONTROL opcode=0x00 bytes=2 raw=0008
60.075s ATVV STREAM STOP
60.092s ATVV CONTROL opcode=0x00 bytes=2 raw=0002
```

`raw=0008` 是 60 秒超时停止；`raw=0002` 是随后用户松开遥控器语音键。日志没有 `VOICE KEY ... edge=up result=event_submitted`，目标语音工具没有收到结束事件。

日志只保留模式、控制字节、结果原因和计数，不记录用户语音内容或目标工具文字。

## 根因假设与实验

- H1：音频和蓝牙流没有结束，导致工具不提交。已被日志否定；`ATVV STREAM STOP`、录音资产保存和 `ATVV AUDIO completed=normal` 都存在。
- H2：本地转写捕获取消就是目标工具不提交的原因。已否定；本地捕获只负责 App 的语音记录，不控制第三方工具的提交。
- H3：硬件映射 Fn 模式没有发送软件 Fn 抬起。日志中的 `updateVoiceKeyState` 在 `forceSoftware=false` 且 `mode.usesHardwareMapping` 时直接返回，只记录 `hardware_path_unobserved`，没有真实按键事件；与现场一致。

结论：远端超时停止时，物理 Fn 仍处于按下状态；App 的正常释放路径按硬件映射跳过软件抬起，目标工具因此保持在长按听写状态。

## 修复

- 解析 ATVV `STOP` 控制字节：`0x08` 标记为 `remote_timeout`，`0x02` 标记为 `remote_release`；保留普通 stop 的默认释放语义。
- 在蓝牙停止回调中读取最后一个停止原因。仅当以下条件同时满足时，强制发送一次软件 Fn 抬起：
  - 停止原因是 `remote_timeout`；
  - 当前语音键模式使用硬件映射（Fn）；
  - Fn tap 模式未启用；
  - 软件按键 latch 当前未持有。
- 强制抬起通过现有 `KeyboardInjector.setVoiceKeyPressed` 发出，不延长音频、不重开麦克风、不改变正常松开路径。
- 日志增加 `ATVV STREAM STOP ... reason=remote_timeout|remote_release` 和
  `VOICE KEY mode=fn edge=up result=event_submitted|event_submit_failed reason=remote_timeout_commit`。
- 正常 `remote_release` 不增加额外事件，避免改变已验证的松键行为。

## 验证

已执行：

- `swift test --disable-keychain --filter 'BluetoothVoiceStopPolicyTests|ATVVAudioDiagnosticsTests|BluetoothLifecycleTests'`：60 项 / 3 suites 通过。
- `git diff --check`：通过。

待执行：

- 受影响语音键/本地记录回归。
- 本地 release App 构建与真实豆包 60 秒复测，确认目标工具在超时停止时提交并结束。

## 验证边界

自动化只能证明控制字节映射、策略条件和“无先前按下也能发出 Fn up”的事件注入；不能证明豆包等第三方工具会接受合成 Fn 抬起。真实 RC003 + 豆包必须复测 60 秒超时、正常松键、连续快速按和异常断开。修复不延长远端 60 秒音频，也不恢复超时后的尾音；本地 `TRANSCRIPT CAPTURE` 的取消是另一个独立问题。
