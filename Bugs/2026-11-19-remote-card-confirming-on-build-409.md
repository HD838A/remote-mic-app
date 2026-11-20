# Build 409 遥控器可用但卡片持续“状态确认中”

- 时间：2026-11-19
- 状态：阻塞区间已由 Build 409 日志定位；具体调用和底层原因未确认，已补分步日志，暂不提交修复
- 影响范围：2.0.9 Build 409；小米遥控器与苹果遥控器卡片状态
- 简单描述：新安装 Build 409 后，两只遥控器都能响应按键，语音键也能唤醒，但卡片持续显示橙色“状态确认中”；点击菜单栏“立即重新连接”后恢复。

## 现场证据

- 测试机不是开发机；本地偏好和本机已安装包不能作为该现场的证据。
- 用户提供两份新版本加密 `.rmlog`：
  - `sayall.app-2026-11-19-session-2AE1E83E.rmlog`
  - `sayall.app-2026-11-19-session-7D0C1E2D.rmlog`
- 两份日志已按 `sayall-rmlog-decrypt` 的受控流程解密；明文只保存在仓库外，不进入 Git。Build 409 的文件是 `7D0C1E2D.log`，共 2040 条记录，时间范围 13:33–13:41。
- Build 409 的关键事件顺序：

```text
13:33:33.354  AUDIO CONFIGURE operation_id=1 stage=connect_mixer elapsed_ms=2106
13:37:39.800  AUDIO CONFIGURE operation_id=1 stage=prepare_engine elapsed_ms=248559
13:37:41.800  AUDIO CONFIGURE operation_id=1 phase=timed_out result=failed reason=prepare_timeout elapsed_ms=250559
13:37:45.918  AUDIO CONFIGURE operation_id=1 phase=completed result=ready attempts=2
```

- `connect_mixer` 与 `prepare_engine` 之间没有 `open_output_unit`，间隔 248 秒。`open_output_unit` 日志位于 `engine.attach`、`engine.connect` 之后、`engine.outputNode.audioUnit` 之前，因此 Build 409 的阻塞边界是 `engine.attach` 或 `engine.connect`，尚未走到 `outputNode.audioUnit` / `AudioUnitSetProperty`。Build 409 的 `AudioEngineStartCoordinator` 从 `prepare_engine` 才开始计时，所以这 4 分钟阻塞发生在超时机制之前，超时不会触发。
- 阻塞期间 `operation_id=2...15` 的配置请求在串行队列中等待。`operation_id=1` 恢复后，队列逐个重配置，直到 `card_15 state=connected`（13:38:01.290）卡片才离开“确认中”。菜单栏“立即重新连接”与队列恢复同时发生，不是独立的修复证据。
- `card_12` 的 HID 已经连接；卡片进入 `.confirming` 的原因是 `audioStatus` 未 ready，不是 HID/BLE 档案未合并。同一日志没有把苹果遥控器语音授权列为阻塞点，但本次没有执行权限专项验收，不能据此反向证明授权永远正常。

## 已定位的阻塞区间

`RemoteDeviceCardStatus.resolve` 只有在已连接且按键、语音都确认就绪时才返回 `.connected`；任一为 `.unknown` 时返回 `.confirming`。Build 409 日志中的按键侧已经就绪，语音侧一直停在音频配置未完成。

`VirtualAudioOutput.configureOnEngineQueue` 在 `connect_mixer` 与 `prepare_engine` 之间同步执行：

```swift
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: sourceFormat)
```

`connect_mixer` 之后、`open_output_unit` 之前没有其他日志，间隔 248 秒，因此阻塞边界在 `engine.attach` 或 `engine.connect`。现有日志不能证明是哪一个调用，也不能证明底层是驱动、`coreaudiod`、设备枚举还是其他 HAL 状态。

Build 409 的 `AudioEngineStartCoordinator` 只包住后面的 `engine.prepare()` 和 `engine.start()`，所以这 4 分钟发生在超时保护之外：

1. 当前配置操作无法完成，`isAudioOutputReady` 保持 false。
2. 后续配置、停止和恢复任务全部排在同一个队列后面。
3. 卡片语音判定保持 `.unknown`，`RemoteDeviceCardStatus.resolve` 返回 `.confirming`。

## 为什么暂不修复

把 `engine.attach` 和 `engine.connect` 一起移入有界工作线程可以缓解这一区间，但无法证明具体是哪一行阻塞，也无法证明修复覆盖了真实根因。这是推断性修复，本次已撤回，不提交。

下一步只补分步日志：在 `engine` 创建、player 创建、attach、connect、output unit、设备选择、prepare、start 前后各加一个稳定 stage。下一次现场复现时，最后一个 stage 就是实际卡点，不需要再猜。

Build 408 已在 `prepare_engine` 阻塞；`AudioEngineStartCoordinator` 对 408 的修复仍然有效。Build 409 的阻塞提前到建图段，两个现场不能共用同一个结论。

## 已排除的假设

- HID/BLE 互补档案未合并：`card_12` 的 HID 已连接，卡片诊断状态由音频未 ready 触发；不能解释本次两只遥控器同时卡住。
- 苹果遥控器语音权限或 Siri 音频未就绪：日志没有把该状态作为阻塞点。
- 菜单栏“立即重新连接”主动修复：日志显示它发生在音频队列恢复之后或同时，不能单独证明因果。

## 本次诊断改动

- 新增 `REMOTE CARD_READINESS` 日志，与 `REMOTE CARD_STATUS` 使用同一 `operation_id`：
  - `state`、`model`、`connected`、`history`；
  - `buttons`、`button_reason`；
  - `voice`、`voice_reason`；
  - `profile_hid`、`profile_bt`、`hid_monitor`、`button_cache`；
  - `apple_connected`、`audio_status`、`audio_ready`、`audio_selected`；
  - `bridge`、`siri_audio`、`profiles`、`connected_profiles`。
- 新增 `SETTINGS REMOTE_PROFILE_PAIR phase=skipped result=not_merged`：
  - `reason=group_count|hid_only_count|ble_only_count|hid_not_live_or_selected|ble_not_connected|identity_or_name_conflict`
  - 同时记录 `group_count`、`hid_only`、`ble_only`、`both`、`active_hid`、`selected_hid`、`connected_ble`。
- 新增音频建图分步 stage，用来区分具体阻塞调用：
  - `engine_created`、`player_created`；
  - `attach_player`、`attach_player_completed`；
  - `connect_mixer_call`、`connect_mixer_completed`；
  - `open_output_unit_completed`、`select_device_completed`；
  - `prepare_engine_completed`、`start_engine_completed`。
- 日志只包含布尔值、稳定状态名、型号和本地化 key，不包含设备名称、硬件标识、路径或用户内容。

## 验证

- 本轮是日志改动，不含修复。
- 定向回归 `VirtualAudioConnectionLifecycleTests|RemoteDeviceCardStatusTests|RemoteProfilePersistenceTests`：80 项通过。
- 公开全量测试：1530 项、112 个套件通过。
- 公开 Release 构建：`SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain --scratch-path .build-public-diagnostics -c release` 通过。
- `verify-repository-governance.sh`：通过；`check-repository-boundaries.sh`：`REPOSITORY BOUNDARY PASS`。
- 新增测试检查分步 stage 是否仍接线：`engine_created`、`player_created`、`attach_player_completed`、`connect_mixer_completed`、`open_output_unit_completed`、`select_device_completed`、`prepare_engine_completed`、`start_engine_completed`。
- 本轮日志来自真实 Build 409 测试机；新分步日志尚未在测试 Mac 上产生，具体阻塞调用仍待下一份 `.rmlog` 确认。

## 下一步

1. 用只包含分步诊断日志的测试包在测试 Mac 上复现启动和“立即重新连接”流程。
2. 收集新的 `.rmlog`，找到 `AUDIO CONFIGURE operation_id=...` 的最后一个 `stage=`：
   - `connect_mixer`：`AVAudioEngine` 初始化；
   - `engine_created`：`AVAudioPlayerNode` 初始化；
   - `player_created`：创建完成、尚未进入 attach；
   - `attach_player`：`engine.attach`；
   - `attach_player_completed`：attach 已返回、尚未进入 connect；
   - `connect_mixer_call`：`engine.connect`；
   - `connect_mixer_completed`：connect 已返回、尚未进入 output unit；
   - `open_output_unit`：`engine.outputNode.audioUnit`；
   - `open_output_unit_completed`：output unit 已返回、尚未进入设备选择；
   - `select_device`：`AudioUnitSetProperty`；
   - `select_device_completed`：设备选择已返回、尚未进入 prepare；
   - `prepare_engine`：`engine.prepare`；
   - `prepare_engine_completed`：prepare 已返回、尚未进入 start；
   - `start_engine`：`engine.start`；
   - `start_engine_completed`：start 已返回。
3. 只有新日志确认具体调用后，才修改对应调用；如果最后一个 stage 是 `*_completed`，说明该调用已返回，需要结合下一条日志判断卡在哪一段，不能直接把它当作根因。如果日志仍无法区分，再在卡住时抓取 `sample SayAll` 或 `spindump`，补充 HAL 栈。
