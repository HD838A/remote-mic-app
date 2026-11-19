# Build 409 遥控器可用但卡片持续“状态确认中”

- 时间：2026-11-19
- 状态：诊断日志已补充，根因待现场日志确认
- 影响范围：2.0.9 Build 409；小米遥控器与苹果遥控器卡片状态
- 简单描述：新安装 Build 409 后，两只遥控器都能响应按键，语音键也能唤醒，但卡片持续显示橙色“状态确认中”；点击菜单栏“立即重新连接”后恢复。

## 现场证据

- 测试机不是开发机；本地偏好和本机已安装包不能作为该现场的证据。
- 用户提供两份新版本加密 `.rmlog`：
  - `sayall.app-2026-11-19-session-2AE1E83E.rmlog`
  - `sayall.app-2026-11-19-session-7D0C1E2D.rmlog`
- 原始日志和明文不得入库；本轮未取得可解密私钥，未把加密日志内容当作已确认事实。
- 可用的旧版解密日志是 2.0.9 Build 408，不是 Build 409：
  - 启动时 `AUDIO CONFIGURE operation_id=1` 在 `stage=prepare_engine` 停留超过 20 秒；
  - 没有对应的 `phase=completed`；
  - 随后反复出现 `AUDIO HEALTH stale`；
  - 卡片从 `.connected` 变为 `.confirming`。
- Build 409 的 `fc02144d` 已包含 PR #1136 和 `AudioEngineStartCoordinator`，因此旧 Build 408 的音频卡死不能直接解释 409 的全部现象。

## 代码事实

`RemoteDeviceCardStatus.resolve` 只有在已连接且按键、语音都确认就绪时才返回 `.connected`。任一为 `.unknown` 时返回 `.confirming`。

Build 409 的语音就绪分支中：

- 未选择输出设备，或音频状态包含 `failed` / `unavailable`，返回 `.failed`，卡片应为红色“语音异常”；
- 音频状态不是 `current_format` 且输出未就绪，返回 `.unknown`；
- 苹果遥控器还依赖 `siriRemoteAudioStatus`；
- 小米遥控器还依赖 BLE bridge 是否 `.ready`。

因此橙色“状态确认中”至少有两个不同来源：

1. 按键就绪未知：卡片读 BLE 档案，HID 监视器挂在另一条档案，常见于 HID/BLE 互补档案未合并。
2. 语音就绪未知：音频尚未确认，或苹果遥控器音频状态、BLE bridge 状态没有进入终态。

菜单栏“立即重新连接”会触发连接、发现和档案收敛，可能同时修复上述两类状态，不能据此单独判定是音频还是档案问题。

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
- 日志只包含布尔值、稳定状态名、型号和本地化 key，不包含设备名称、硬件标识、路径或用户内容。

## 验证

- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --scratch-path .build-public-diagnostics --filter 'RemoteDeviceCardStatusTests|RemoteProfilePersistenceTests'`：29 项通过。
- 公开模式全量测试：1530 项、112 个套件通过。
- 本轮未完成真实 Build 409 测试机复现，也没有新的真实设备日志；不得把自动化结果当作真机验收。

## 下一步

1. 用包含本诊断日志的测试包在测试 Mac 上复现。
2. 复现后收集新的 `.rmlog`，重点检查：
   - `REMOTE CARD_READINESS` 中 `button_reason=hid_monitor_missing` 或 `profile_hid=false`；
   - `voice_reason=audio_not_ready|apple_audio_unknown|bluetooth_bridge_not_ready`；
   - `SETTINGS REMOTE_PROFILE_PAIR` 的 `reason` 与计数。
3. 只有日志确认其中一个来源后，再做最小修复；不要同时改音频重试和档案合并。
