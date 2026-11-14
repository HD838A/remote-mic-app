# 断连后设备不再被接管，语音键的 F5→Fn 映射没有写回

- 时间：2026-11-13
- 状态：修复已合入 main（PR #1036，merge commit `3576e649`）；自动化通过，真实 Intel 机器复测待完成
- 影响范围：小米 RC001/RC003 重连后的 HID 接管、语音键映射、系统听写被反复触发
- 功能点：bluetooth_remote、hid_mapping、voice key

## 问题

Intel 用户（macOS 15.8.3，SayAll 2.0.0 build 320，`cpu_architecture=x86_64`）反馈：按住语音键说话，识别不出内容；并且「按了一下语音键，然后它会 F5 无限重复，电脑就完全无法使用」。

语音识别不出的直接原因是音频到达率只有 36%～37%，属于链路问题，见下方「边界」；本记录只处理 F5 进入系统这一条。

## 现场证据

解密后的会话日志 `sayall.app-2026-11-13-session-8DD4E9BE`（`ver=2.0.0 build=320`）：

```
16:04–16:08  VOICE FN MAPPING applied=true … matched=1 applied=1      （映射写入成功，语音可用）
16:09:36.069 BLE DISCONNECTED phase=ready(1) error_domain=CBErrorDomain error_code=6
16:09:39.096 HID NATIVE MAPPING phase=prepare result=pending reason=no_service family=xiaomi
16:09:39.106 HID DEVICE rejected reason=native_mapping_not_verified
16:09:39.107 HID DEVICE rejected reason=excluded_fingerprint
16:09:40 → 16:14:25  HID REPORT rejected reason=excluded_fingerprint ×13，accepted ×0
```

断连前：`HID REPORT accepted` 38 次、被拒 49 次（被拒的是发现监视器按设计让位）；断连后 5 分钟：**接受 0 次、拒绝 13 次**。

同一时段**没有一次成功的** BLE 重连，也没有任何 `HID MAPPING RECOVERY` 记录。但 BLE 侧并非没有动作（以下为同一份日志的 UTC 时间，本地时间 = UTC+8）：

```text
08:09:36.070  BLE RECONNECT scheduled failure_count=1 delay_ms=2805 cached_identifier_bypassed=false
08:09:39.064  BLE CENTRAL state=5 lifecycle=scanning(2) generation=2
08:09:39.064  BLE SYSTEM CONNECTED CANDIDATES count=1
08:09:39.069  BLE SCANNING
              ← 到 08:14:25 零 BLE 事件：无 READY、无 SCAN TIMEOUT、无下一次 RECONNECT
```

即：排过退避重连、central 重建过、系统已连接候选也查到 1 台，之后完全停死。这段属于 BLE 重连层，见下方「与 BLE 重连层的关系」；本记录只处理 HID 接管层。

## 根因

1. 重连时设备先于 HID 服务出现。`HID NATIVE MAPPING phase=prepare result=pending reason=no_service` 就是 `RemoteNativeKeyMapper.prepare()` 的 `services()` 为空，该函数注释已写明要「每次设备激活重新枚举」。
2. 但 `HIDRemoteMonitor.prepareNativeKeyMapping()` 只在设备匹配时同步校验一次，失败就 `IOHIDDeviceClose` 并 return（`probeDevice`、`promoteProbedDevice`、`activateDevice` 三条路径都是），**没有任何重试**。
3. 于是设备永久不被接管，`nativeKeysNeutralized` 保持 `false`，`voiceFunctionMapper.apply()` 也没有再被调用，**F5→Fn 的 `UserKeyMapping` 从未写回**。
4. 语音键不在 `RemoteButton` 体系里（`RemoteButtons.swift` 的 `usageMap` 没有 0x3E），App 只监听 Fn 的 `flagsChanged`。映射缺失时按下语音键，系统收到的是原生 F5，App 侧既收不到 Fn，也不存在任何按 `RemoteButton` 登记的事件级拦截。
5. F5 在 macOS 默认绑定听写，反复触发即表现为「整机无法使用」。

既有的 `HIDMappingRecoveryPolicy`（0.5/1/2/4/8 秒退避）已存在，但 `retryDelay` 要求 `readyBridgeCount > 0`，而这一次 BLE 桥恰好在断连后没有回到 ready；且唯一调用点在 fn_tap 分支，这条路径走不到。

## 修复

- `HIDRemoteMonitor` 新增 `onNativeMappingVerificationFailed`：校验失败时回报给上层，监视器自己不排程。
- `BridgeAppModel` 在 `makeHIDMonitor` 里接上该回调，按现有退避间隔排一次有界重试（最多 5 次，累计约 15.5 秒），重试动作复用 `applyHIDSettings`（重建 HID 监视 → 重新枚举服务 → 重新校验并写回映射）。
- 新增 `HIDMappingRecoveryPolicy.deviceVerificationRetryDelay`：同一组间隔，但**不要求蓝牙桥 ready**——设备已经匹配本身就是它在位的证据，而重连时蓝牙桥恰好可能还没回到 ready。
- `scheduleHIDMappingRecoveryIfNeeded` 增加 `requiresReadyBridge`（默认 `true`，既有调用点行为不变），并在 `scheduled`/`applying`/`exhausted` 三个日志追加 `trigger=bridge_ready|device_verification`，现场可以直接判断是哪条路径在重试。

本次不改变音频投递、不改变 ATVV 协商、不改变语音键的按键语义；映射恢复后语音键回到原有的 Fn 长按路径。

## 验证

- 全量 `swift test --disable-keychain --disable-sandbox`：基线 `f4c17229` 上 1401 项 / 103 suites 通过；rebase 到 `822014ac` 后 1424 项 / 104 suites 通过。
- 新增 `BluetoothLifecycleTests.deviceVerificationRetryDoesNotRequireAReadyBridge`：锁定间隔序列、`started=false` 与「服务已就绪不重试」。
- 新增 `KeyboardEventSuppressorTests.nativeMappingVerificationFailureIsReportedOncePerAttempt`：校验失败回报一次，服务就绪后不再回报。
- 反向验证：临时移除 `onNativeMappingVerificationFailed?()` 后该用例在 `failures == 1` 两处变红，恢复后通过。
- 合入：PR #1036，merge commit `3576e649`，双架构 CI 通过。
- 待完成：真实 Intel 机器复测——重连后确认出现 `HID MAPPING RECOVERY … trigger=device_verification`、`HID CONNECTED`、`VOICE FN MAPPING applied=true`，以及 `HID VOICE_USAGE source_kind=f5` 恢复到 Fn 路径。

## 与 BLE 重连层的关系（2026-11-14 补记）

本次现场同时涉及两个独立的层，修一个不能解决另一个：

| 层 | 缺口 | 用户看到 |
| --- | --- | --- |
| BLE 发现/重连（`XiaomiBluetoothBridge`、`BluetoothLifecycle`） | 首次重连失败后停死：旧策略只在 `hasSavedTarget && !allowsCachedTargetRetrieval` 时开 20 秒扫描窗口，本机 `cached_identifier_bypassed=false` 意味着窗口不开，于是没有超时、也没有下一次尝试 | 语音完全不可用，普通按键仍可用 |
| HID 接管（`HIDRemoteMonitor`、`BridgeAppModel`） | 校验失败即 `IOHIDDeviceClose` 且不重试 | 语音键变裸 F5，反复触发系统听写 |

- BLE 侧的同族问题与建议见 #631（已关闭）；它建议的两条（每轮都查系统已连接候选、给扫描加窗口）已由 #921 合入。本机 build 320 早于 #921，因此仍会停死。
- 但 #921 没有覆盖「候选查到了却没采纳」这一段：本次日志 `count=1` 之后既无 `BLE CONNECTING` 也无 `BLE REJECTED`。该缺口另立 #1041。
- 因此本记录的修复只消除「F5 进系统」。**语音能否恢复取决于 BLE 侧**，两者必须分别验收，不能互相代替。

## 边界

- 自动化只证明「失败会回报、退避序列有界、不依赖蓝牙桥」，不能证明重连时服务在第几次重试后变得可枚举。5 次 / 约 15.5 秒是经验参数，现场若仍不够，需要按真实日志调整。
- 本记录不涉及音频到达率。同一份日志里四段语音的 `coverage_pct` 为 35.7%～37.4%，平均回调间隔 41.3 ms、355 个间隔中 354 个 ≥20 ms，指向连接间隔而非主机处理；macOS 没有公开 API 设置连接间隔，需链路层抓包才能定性，属于独立工作项。
- 另一份同日明文日志 `runtime.log` 来自 `ver=1.9.21 build=174`，该构建缺少诊断公钥才会写明文兜底（`AppLogger.swift` 的 `usesPlaintextFallback`），因此不包含 build 320 的会话，也不能用来判断本 Bug 是否在旧版存在。
