# 同机多账户切回后遥控器按键可用但麦克风不拾音

## 状态

**未复现，根因未确认。** 本轮只做了两件事，且都不依赖根因结论：

1. **日志补充**：把「会话离开前台 / 切回前台」这条链路的状态与决策补齐，使现场日志能直接区分
   「蓝牙语音链路掉了」和「虚拟音频没重绑」，不再需要靠猜。
2. **受门控的最小恢复**：挂起原因全部解除后，如果所有已配置的桥都没就绪且没有正在进行的语音，
   主动重建一次蓝牙语音链路——即把用户已经在用的「立即重新连接」自动化到症状出现的时刻。
   任何一台桥已就绪、或有活跃语音时，逻辑与改动前**完全等价**（空操作）。

真实双账户复现与真机验收**尚未完成**，因此本条不标记为已修复。

## 复现条件

对应 Issue [#497](https://github.com/HD838A/remote-mic-app/issues/497)（2026-09-26 通过工作台提交；
同一份反馈也以微信群转述出现过）。反馈描述的是这样一条序列：

1. 一台 Mac（M2 Pro），macOS 上存在**两个用户账户**，都装并运行无线麦SayAll.app。
2. 用户在账户 A 下正常使用实体遥控器语音输入。
3. 用「切换用户」切到账户 B，并在账户 B 下也使用同一台遥控器。
4. 切回账户 A 后：**遥控器按键仍能唤起语音输入，音量键和语音键都有响应，但麦克风不拾音**。

现场未提供日志、版本号、macOS 小版本与第三方语音工具名称。附带的界面截图显示
「正在查找小米遥控器」与「未选择语音输出设备或设备不可用」同时出现，而音频设备列表里
**已经检测到 `MiRemoteV 2ch`**——说明驱动本身在，出问题的是连接与音频通道的恢复。

## 现场证据与日志结论

- 证据类型：**仅口述 + 3 张设置界面截图**。压缩包内不含任何日志附件或文件卡片。
- 截图是设置页的静态快照，**不能代表故障瞬间的运行时状态**，也不能证明事件顺序。
- 因此本轮**没有任何一侧的运行日志**，无法核对 `SYSTEM AUDIO`、`BLE`、`AUDIO REBIND` 事件序列。
- 结论：现象真实可信，但「哪一环断了」在改动前**无法从证据区分**。

## 代码根因（未确认，按代码证据列出）

以下都在改动前的 `origin/main` 上逐条核对过，但都是**读码得到的候选根因，不是已确认根因**：

- `handleSystemAudioLifecycle` 只有在 `.systemDidWake` 时才会触发蓝牙重连恢复
  （`BluetoothWakeRecoveryPolicy.shouldForceReconnect` 判定为 `started && event == .systemDidWake`）。
  `.sessionDidBecomeActive`（切回前台）**不会**触发任何蓝牙恢复。
- `sessionDidResignActive` 只走音频释放，**不解除蓝牙连接**；所以两个账户的实例会同时保活
  BLE central，而实体遥控器同一时刻只能被一个 central 连接 → 本账户的链路可能被另一个账户顶掉。
- 切回后 `resumeVirtualAudioOutputIfNeeded` 需要 `readyBluetoothBridgeCount > 0` 才会重绑虚拟音频。
  若桥没就绪，它只记录 `AUDIO REBIND deferred reason=bluetooth_ready`，**不会推进重连**。
- `XiaomiBluetoothBridge.handleDisconnect` 会自动重连，但退避上限 60s；用户手动点「立即重新连接」
  会 `reconnectPolicy.reset()` 并立刻重连。这与用户现场「必须点一下才恢复」的行为一致。
- `ApplicationInstanceGuard` 用 `.userDomainMask` 主目录 + 本会话 `NSRunningApplication`，
  两个账户的实例**互不可见**，因此「不同账户实例同时运行」在现有实现下是设计允许的，
  不是回归。

候选假设与相对可能性：H1 切回不重建 BLE 语音链路（高）｜H2 残留挂起原因导致音频不重绑（中）｜
H3 两个实例争抢同一台遥控器的连接（中）｜H4 第三方工具保留了失效输入流（低，且不可观察）。
**H1 的代码缺口最直接，也是本轮恢复逻辑针对的对象。**

## 本次改动

### 1. 日志补充（`Sources/RemoteMic/BridgeAppModel.swift`、`XiaomiBluetoothBridge.swift`）

- `SYSTEM AUDIO` 事件行新增 `configured_bridges`、`discovery_bridge` 两个上下文字段：
  只靠 `ready_bridges` 无法区分「有桥但都没就绪」和「根本没有桥」。
- 新增决策日志 `SYSTEM AUDIO voice_link_recovery event=... cause=no_ready_bridge ...`：
  只在判定需要恢复时写出，说明为什么在会话切回时发起蓝牙恢复。
- 蓝牙恢复日志从 `BLE WAKE recovery_*` 改为 `BLE RECOVERY phase=... trigger=<reason>`，
  同一入口现在能区分 `trigger=system_wake`（系统唤醒）与 `trigger=session_activated`（会话切回）。
  改动前这条链路在会话切回时**完全静默**，是本次反馈无法定性的直接原因。

补齐后，同一条现场可以按下面的顺序自证：

```text
SYSTEM AUDIO event=session_did_resign_active changed=true suspended=true reasons=session_inactive ...
SYSTEM AUDIO event=session_did_become_active changed=true suspended=false reasons=none ready_bridges=0 configured_bridges=1 ...
SYSTEM AUDIO resume_skipped reason=system_session_did_become_active required=false ready_bridges=0 selected=true
SYSTEM AUDIO voice_link_recovery event=session_did_become_active cause=no_ready_bridge ready_bridges=0 configured_bridges=1 ...
BLE RECOVERY phase=begin trigger=session_activated target_bridges=1 ...
BLE RECOVERY phase=requested trigger=session_activated state=... lifecycle=... central_state=... generation=...
```

之后应继续出现 `BLE SCANNING` / `BLE CONNECTED` / `BLE READY`（成功）或
`BLE DISCONNECTED` + `BLE RECONNECT scheduled failure_count=...`（仍在失败，可看到退避）。

### 2. 受门控的最小恢复（`BluetoothLifecycle.swift`、`BridgeAppModel.swift`）

`BluetoothWakeRecoveryPolicy` 新增 `shouldRecoverVoiceLinkAfterResume`，四个条件**同时**满足才恢复：

| 条件 | 值 | 理由 |
| --- | --- | --- |
| 已启动 | `true` | 未启动时不做任何事 |
| 已配置的桥 | `> 0` | 没有桥就凭空启动连接，属于扩大行为 |
| 就绪的桥 | `== 0` | 任一桥就绪即空操作，**不打断健康连接** |
| 活跃语音 | `false` | 正在说话时不介入，**不打断会话** |

改动后与 `.systemDidWake` 的分工：系统唤醒仍是强恢复（`shouldForceReconnect` 不变），
本次新增的是「链路其实已经掉了」的按需恢复。恢复入口统一为
`recoverBluetoothVoiceLink(reason:)`，桥侧为 `recoverVoiceLink(reason:)`。

**不属于本次范围**（未做，也不应在没有证据时做）：

- 未在 `sessionDidResignActive` 时主动断开蓝牙。那会改变常驻行为并有打断后台语音的风险，
  需要独立产品需求与真机验证，不能作为「顺手修复」合入。
- 未改动 `ApplicationInstanceGuard` 的跨账户互斥策略。
- 未改动音频释放 / 重绑优先级、`ATVV` 协议路径或语音键生命周期。

## 验证

新增的自动化用例（已写入 `Tests/RemoteMicTests/BluetoothLifecycleTests.swift`，**由 CI 执行**）：

- `sessionResumeRecoversVoiceLinkOnlyWhenNoBridgeIsReady`：真值表覆盖「就绪 / 无桥 / 未启动 /
  有活跃语音」四种不应恢复的情况，以及「有桥但都没就绪」这一应恢复的情况。
- `sessionResumeRecoveryIsWiredIntoTheSystemAudioLifecycle`：源码回归，防止 `handleSystemAudioLifecycle`
  丢失恢复调用或退回「系统唤醒专用」的旧命名。

本机实际执行的验证：

| 命令 | 结果 |
| --- | --- |
| `SKIP_SWIFT_PACKAGE_BUILD=1 zsh scripts/test.sh` | 自检 **48/48 通过**（真实编译了改动的 `BluetoothLifecycle.swift`） |
| 手动重建本地依赖模块后对 `Sources/RemoteMic/*.swift` 做 `-typecheck` | 退出码 **0**、错误数 **0**（仅既有弃用告警） |
| 新策略真值表 7 条断言（独立编译并真跑） | 全部 PASS |
| `git diff --check` | 通过 |

**本机无法执行的项（不得记作已通过）**：这台机器只装了 CommandLineTools、没有完整 Xcode，
其 `swift` 对 `Package.swift` 直接报 `unable to type-check this expression in reasonable time`，
因此 `swift build` / `swift test` 在本机任何 worktree 都无法运行；`import Testing` 的类型检查
也做不了（CLT 不含 swift-testing）。**构建与测试门禁只能由 CI 承担。**

**未完成的边界（必须明确，不能当成已验收）：**

- 未在真实双账户环境复现，未取到任何一侧的 `runtime.log`。
- 未覆盖真实 BLE 顶连接、真实 `MiRemoteV 2ch` 写入、真实第三方语音工具文字上屏。
- 单元测试只能证明「策略真值表」和「恢复被接线」，不能证明切回后麦克风真的恢复拾音。
- 真机验收步骤见 `Testing/MacIdleSleepAudioRelease.md` 的快速用户切换用例。

## 后续

1. 用双账户在同机复现并采集两侧 `~/Library/Logs/RemoteMic/runtime.log`，核对上面的事件序列，
   据此确认或否证 H1/H2/H3。
2. 若日志显示恢复已发起但桥始终无法就绪，则 H3（两个实例争抢同一台遥控器）成立，
   需要单独的产品决策：会话离开前台时是否主动释放 BLE 连接。
3. 在结论明确前，本条保持「未复现」，不声称已修复。
