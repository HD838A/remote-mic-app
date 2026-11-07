# 唤醒后 BLE 语音链路静默停死：跳过系统已连接候选且扫描无窗口

- 时间：2026-11-07
- 状态：候选修复；本机 rc003 真机两次睡眠（蓝牙断电）→唤醒验证通过，用户实际语音输入正常；等待维护者复验
- 影响范围：macOS `1.9.21 (174)`（`main` 同逻辑）、小米蓝牙语音遥控器 2 Pro（rc003）
- 功能点：CoreBluetooth 睡眠唤醒恢复、连接发现、ATVV 语音链路
- 简单描述：睡眠唤醒后 BLE central 断电重连；唤醒瞬间 `retrievePeripherals(withIdentifiers:)` 可能返回空，而旧发现策略在「有已保存身份且缓存直连可重试」时跳过 `retrieveConnectedPeripherals`；扫描又没有窗口，重连循环静默终止。HID 按键继续工作，语音完全无响应，只能手动点「立即重新连接」或重启 App。

## 现场证据（1.9.21，本机真机）

2026-11-07 本地时间 21:23（睡眠后唤醒）：

```text
21:23:04.530 SYSTEM AUDIO event=system_will_sleep ... suspended=true
21:23:09.647 BLE CENTRAL state=4 lifecycle=scanning(19) generation=19
21:23:09.697 HID DISCONNECTED
21:23:36.141 SYSTEM AUDIO event=system_did_wake ... ready_bridges=0
21:23:36.855 BLE WAKE recovery_requested state=bluetoothUnavailable(bluetooth.status.off)
             lifecycle=scanning(16) central_state=0 generation=16
21:23:37.027 BLE SCANNING
21:23:37.082 BLE SCANNING
# 之后到 21:36 没有任何 BLE 事件：没有 CONNECTING / CONNECTED / SCAN TIMEOUT
```

- 19:49:57 之后没有任何 `ATVV STREAM`；
- 21:23–21:36 期间 `HID REPORT accepted` 持续出现，说明遥控器与系统 HID 链路正常、电量正常；
- 同一台机器重启 coreaudiod 并重启 App 后，`BLE CONNECTING source=target_identifier` → `BLE READY` 约 50 ms，语音恢复。

结论：这不是设备离线，也不是配置问题，而是 BLE 发现/重连循环在唤醒后静默终止。

## 代码根因

1. `XiaomiBluetoothBridge.discoverOrScan` 的 connected-candidate 查询被
   `VoiceRemoteDiscoveryPolicy.shouldQuerySystemConnectedCandidates` 门控：
   `hasSavedTarget && allowsCachedTargetRetrieval` 时返回 false。唤醒恢复走
   `recoverVoiceLink → reconnectNow`，后者把 `allowsCachedTargetRetrieval` 重置为 true，
   于是这条唯一能发现「系统已连接、但不广播」设备的路径被跳过。
2. `BluetoothScanRecoveryPolicy.shouldStartScanTimeout` 只在
   `hasSavedTarget && !allowsCachedTargetRetrieval` 时开窗口；本场景下扫描永远停在
   `.scanning`，不会产生下一次 attempt。
3. 两者叠加：唤醒瞬间 target 查询返回空 → 跳过系统已连接候选 → 进入无窗口扫描 →
   循环静默终止。即使几秒后系统重新连上遥控器，App 也不会再查一次。

## 最小修复

1. `discoverOrScan` 每轮都查询 `retrieveConnectedPeripherals(withServices: [ATVV])`；
   是否采纳仍由 `VoiceRemoteAdmission` 统一判定，非目标 UUID 不会误收。
2. `BluetoothScanRecoveryPolicy.shouldStartScanTimeout(hasSavedTarget:)`：只要存在已保存身份
   就启用 20 秒扫描窗口，不再用「缓存直连可用」豁免。
3. 窗口到期改为**原地重新发现**：先重查 `retrievePeripherals` 与系统已连接候选，再重新扫描；
   不进入退避、不重建 central。真正离线的设备只是继续扫描；首次发现（没有已保存身份）
   仍保持持续扫描。

## 验证

- `swift test --disable-keychain --filter BluetoothLifecycleTests`：26 项通过（含
  `scanTimeoutStartsForEverySavedTarget`）。
- 全量 `swift test --disable-keychain`：1248 项中 10 项失败，全部是本机沙箱环境限制
  （废纸篓、`~/Library/Application Support` 写入、`codesign` 子进程），没有蓝牙相关失败。
- 真机（2.0.0 候选构建，rc003）：让 Mac 睡到蓝牙断电（`BLE CENTRAL state=4`，唤醒时
  `ready_bridges=0`），唤醒后日志：

```text
22:19:41.114 SYSTEM AUDIO event=system_did_wake ... ready_bridges=0
22:19:41.115 BLE RECOVERY phase=begin trigger=system_wake ... ready_bridges=0
22:19:41.256 BLE CENTRAL state=5 lifecycle=scanning(3) generation=3
22:19:41.265 BLE CONNECTING source=target_identifier
22:19:41.291 BLE CONNECTED
22:19:41.304 BLE SYSTEM CONNECTED CANDIDATES count=1
22:19:42.681 BLE READY
```

  唤醒到 `BLE READY` 共 1.57 秒，随后 `ATVV STREAM` 正常；无人工干预。
- 第二次真机（用户复验，2026-11-07 本地时间 22:44）：睡眠 16 秒后蓝牙 `state=4`；
  唤醒 `14:44:27.628`（`ready_bridges=0`）→ `BLE CONNECTING` `14:44:27.791` →
  `BLE READY` `14:44:30.657`（约 3.0 秒）；随后连续 5 段 `ATVV STREAM accepted`
  （`31.041` / `33.602` / `45.392` / `54.363` / `59.597`），用户确认 Fn 与语音输入正常。
- 对照：修复前同机日志在同类唤醒下静默 13 分钟以上。

## 验证边界

- 本机共两次真机睡眠验证（22:19、22:44）均恢复；该故障是间歇性的（`Bugs/2026-10-11-ble-scan-stall-after-cached-target-bypass.md`
  记录「不是每次重连失败都会卡死」），仍需要在维护者真实 rc003 上多次复验：
  唤醒瞬间 target 查询为空时，是否由系统已连接候选或 20 秒窗口接回。
- 遥控器完全离线且不广播时会保持「持续扫描 + 每 20 秒重查系统已连接候选」；
  这条路径没有单独做长时间真机验证。

## 明确不做

- 不改 ATVV 协议、配对信息、按键映射和退避时长/抖动；
- 不改变首次发现（没有已保存身份）时的持续扫描语义。
