# 唤醒后 BLE 语音链路静默停死：跳过系统已连接候选且扫描无窗口

- 时间：2026-11-07
- 状态：RC003 短时系统睡眠、扫描超时重试、离线返回及恢复后首次完整语音已复验；待 PR #921 最终检查与合入。系统候选实际采纳、缓存空返回和 RC001 实机边界见文末。
- 影响范围：macOS `1.9.21 (174)`（`main` 同逻辑）、小米蓝牙遥控器 2（RC001）与 2 Pro（RC003）共用发现代码；现有现场反馈来自 RC003
- 功能点：CoreBluetooth 睡眠唤醒恢复、连接发现、ATVV 语音链路
- 简单描述：睡眠唤醒后 BLE central 断电重连；唤醒瞬间 `retrievePeripherals(withIdentifiers:)` 可能返回空，而旧发现策略在「有已保存身份且缓存直连可重试」时跳过 `retrieveConnectedPeripherals`；扫描又没有窗口，重连循环静默终止。HID 按键继续工作，语音完全无响应，只能手动点「立即重新连接」或重启 App。

## 原作者现场证据（1.9.21，2026-11-07）

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
- 21:23–21:36 期间 `HID REPORT accepted` 持续出现，证明当时 HID 按键链路仍能工作；语音链路状态和电量无法由这些事件确认；
- 同一台机器重启 coreaudiod 并重启 App 后，`BLE CONNECTING source=target_identifier` → `BLE READY` 约 50 ms，语音恢复。

已观察到的结果为唤醒后扫描长期没有进展，HID 按键同期仍可用。现有节选没有直接记录缓存查询返回值、系统候选结果或设备是否广播，现场触发条件仍待确认。

## 已确认的代码缺口与现场假设

1. `XiaomiBluetoothBridge.discoverOrScan` 的 connected-candidate 查询被
   `VoiceRemoteDiscoveryPolicy.shouldQuerySystemConnectedCandidates` 门控：
   `hasSavedTarget && allowsCachedTargetRetrieval` 时返回 false。唤醒恢复走
   `recoverVoiceLink → reconnectNow`，后者把 `allowsCachedTargetRetrieval` 重置为 true，
   于是这条唯一能发现「系统已连接、但不广播」设备的路径被跳过。
2. `BluetoothScanRecoveryPolicy.shouldStartScanTimeout` 只在
   `hasSavedTarget && !allowsCachedTargetRetrieval` 时开窗口；本场景下扫描永远停在
   `.scanning`，不会产生下一次 attempt。
3. 可重现的代码条件为缓存未采纳目标 → 跳过系统已连接候选 → 进入无窗口扫描。
   没有扫描结果时，本轮没有超时重试出口。现场恰好由缓存返回空触发仍是假设，原日志没有记录该返回值。

## 最小修复

1. `discoverOrScan` 在缓存候选未采纳目标时查询 `retrieveConnectedPeripherals(withServices: [ATVV])`；
   是否采纳仍由 `VoiceRemoteAdmission` 统一判定，非目标 UUID 不会误收。
2. `BluetoothScanRecoveryPolicy.shouldStartScanTimeout(hasSavedTarget:)`：只要存在已保存身份
   就启用 20 秒扫描窗口，不再用「缓存直连可用」豁免。
3. 窗口到期沿用 `scheduleReconnect()` 的退避与 central 重建，后续发现重新查询缓存与系统候选；首次发现（没有已保存身份）仍保持持续扫描。2026-11-12 按逐行评审收窄了原候选的原地重发现策略。

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

- 作者共两次真机睡眠验证（22:19、22:44）均恢复；该故障是间歇性的（`Bugs/2026-10-11-ble-scan-stall-after-cached-target-bypass.md`
  记录「不是每次重连失败都会卡死」），仍需要在维护者真实 rc003 上多次复验：
  唤醒瞬间 target 查询为空时，是否由系统已连接候选或 20 秒窗口接回。
- 遥控器完全离线且不广播时会在扫描窗口结束后退避并重建 central；
  这条路径没有单独做长时间真机验证。

## 明确不做

- 不改 ATVV 协议、配对信息、按键映射和退避时长/抖动；
- 不改变首次发现（没有已保存身份）时的持续扫描语义。

## 2026-11-12 主线集成复核

- 基线 `9f384bf93185007cead692b6f1f02004e5842ca1`，原 PR Head `39548095fbb90a3f466faa2cbd626af38631f495`。
- 冲突包含 Bug 索引与蓝牙生命周期测试。保留主线缓存冷却探测回归，调用适配为新的扫描窗口接口；发现代码保留 `shouldRetrieveCachedTarget(at:)`，不会恢复旧的永久禁用缓存行为。
- 同步 `Testing/BluetoothDisconnectAudioRelease.md` 用例 9 和唤醒发现补充验证，保留扫描超时与连接失败的既有退避和 central 重建。
- 新增源码接线回归检查候选查询、超时重新发现及蓝牙未开启时退避入口。系统候选查询门控断言在当前主线失败、集成候选通过，只证明源码结构。
- 2026-11-07 两次真机结果属于作者历史证据；当前集成候选的扫描恢复、离线恢复、首次语音及首尾完整性仍须 RC003 实机复验。当前未提供本机真实设备验收结果。

### PR 新增反馈的覆盖边界

评论 https://github.com/HD838A/remote-mic-app/pull/921#issuecomment-6816946349 报告已就绪链路长期无 BLE 事件、重启后恢复，并提到屏幕唤醒事件。

代码复核确认 `discoverOrScan` 仅处理 `.scanning(generation)`，本 PR 的扫描窗口无法自行触发仍被记录为 ready 的链路恢复。宿主已有独立恢复入口：`BridgeAppModel` 在系统唤醒时调用 `recoverBluetoothVoiceLink`，屏幕唤醒等恢复事件仅在没有 ready 桥且没有活跃语音时恢复；`XiaomiBluetoothBridge.recoverVoiceLink` 再调用 `reconnectNow`。这些入口未在本 PR 修改。

该反馈缺少完整系统生命周期与恢复入口事件序列，无法确认是未触发入口、提前返回、内部状态不一致还是异步断连未完成。对“本 PR 不覆盖未进入发现阶段”的判断置信度高，对现场具体根因保持未知。需要在现场补齐系统/屏幕睡眠与唤醒、挂起原因、BLE RECOVERY、连接状态与首个语音结果后独立定位。不得仅凭闲置时间阈值强制重连，避免打断健康语音。

逐行评审处理结果为保留扫描超时退避和 central 重建；历史两次唤醒均未证明新增兜底分支命中，实机缺口继续保留。发现顺序为缓存成功即返回，缓存未采纳才查询系统候选；周期缓存探测仍遵守当前主线冷却策略。

### 当前集成候选自动化结果

- 公开模式 `swift test --disable-keychain`，Swift Testing 1,383 项 / 100 suites 通过，另有 XCTest 4 项通过（2026-11-12）。包括扫描窗口、缓存冷却探测、旧代次拒绝、系统挂起、唤醒恢复策略及新增源码接线检查。
- `scripts/verify-repository-governance.sh`、`zsh scripts/check-repository-boundaries.sh`、`git diff --check` 通过；修改文件均低于 5 MB。
- 蓝牙生命周期首轮定向 29 项通过；新增源码接线检查已由上述最终全量运行覆盖。
- 本轮没有 RC003 现场设备与目标语音工具完整流程的实测结果，不把这些自动化结果作为真实链路验收。

## 2026-11-12 行为回归补强

- 生产发现流程与回归共用 `VoiceRemoteDiscovery.run`，执行真实的缓存查询、系统候选回退、统一准入和扫描选择顺序。测试注入候选，不连接真实 CoreBluetooth。
- 超时回调共用 `BluetoothScanRecoveryPolicy.handleTimeout`。回放覆盖超时、既有递增退避、下一轮发现，以及连接后、停止、挂起和旧 generation 的回调失效。
- 新增 `BLE DISCOVERY` 有界诊断字段，区分缓存 `empty` / `found` / `skipped`、候选 `adopted` / `not_adopted`，并记录同一 generation 的系统候选数量。采用候选只代表进入连接尝试，最终恢复仍以 `BLE READY` 和第一次完整语音为准。
- RC001、RC003 共用上述生产实现。两个型号的新增兜底、离线返回及恢复后首次语音均需分别记录实机结果。当前新增自动化无法替代 CoreBluetooth 回调、无线链路和文字上屏验收。

- 本轮公开蓝牙生命周期 35 项通过。去除系统候选回退的单行反向实验使新增回归产生 4 个失败断言，恢复实现后公开全量 Swift Testing 1,388 项 / 100 suites、XCTest 4 项通过。仓库治理、边界与 diff 检查通过。

- Build 335 本机启动产生了新增分支日志，同时观察到两个桥的 generation 都为 1。新增每轮 `operation_id`，复用现有公开诊断操作号生成器，将发现、连接、Ready、扫描超时与重试关联起来。操作号为进程内随机短标记，不来自设备身份；generation 继续判断旧回调。该启动记录走缓存采纳，未证明系统候选兜底和扫描超时恢复。
- 操作号补强后蓝牙与公开诊断定向 41 项通过，其余全量 Swift Testing 1,387 项及 XCTest 4 项通过；本次跳过此前已通过的发布控制面夹具。

## 2026-11-14 主线同步与关联反馈范围

本轮基线为 `db4e7b1e3e4ff1934df87d40febf99788ab9432f`。按仓库保留贡献者提交历史的规则合并最新 main，保留原 PR 提交。主线已经包含远端超时收尾、虚拟麦克风尾音排空后松键和附近空闲服务睡眠暂停，本轮检查其与发现恢复的接线交集。

| 反馈 | 与当前修复的关系 | 仍需确认 |
| --- | --- | --- |
| [#914](https://github.com/HD838A/remote-mic-app/issues/914) | 睡眠唤醒后按键正常、语音无响应，与本 PR 的扫描恢复缺口相符 | 新增反馈缺少完整发现与唤醒入口事件，扫描恢复是否实际触发待确认 |
| [#356](https://github.com/HD838A/remote-mic-app/issues/356) | 同一故障链中存在长期扫描停滞，本 PR 覆盖进入发现后的候选与超时恢复 | 恢复入口早退、音频重绑失败、HID 映射等环节需分别验证 |
| [#924](https://github.com/HD838A/remote-mic-app/issues/924) | 开机后须手动重连，小米遥控器 2 Pro，可能经过同一发现路径 | 当前无日志证明同源，冷启动与开机恢复独立验收 |

本轮用户明确选择先推进代码和 CI，暂不配合实机操作。自动化完成后继续保留 Draft，RC003 睡眠唤醒、新增兜底路径及第一次完整语音验收保持待完成。三个 issue 的关闭须以各自错误用例的验证结果为准。

本轮公开模式定向 48 项通过。公开全量 Swift Testing 1,421 项 / 104 suites、XCTest 4 项通过，包含发布控制面夹具。仓库治理、边界和 `git diff --check` 通过。所有 SwiftPM 命令带 `--disable-keychain`。本轮未执行真实睡眠和语音操作。

## 2026-11-14 RC003 现场复验

本节更新此前“待实机复验”的状态；前文日期记录保留为历史证据。测试源码固定为 `007c155af1d0d7201440720132a30e5cf7ef4a2c`，公开本地候选 Build 356，dirty=false，Developer ID / Team `L3QHLDRPAY` 签名及包校验通过。以下时间均为北京时间，不记录设备身份或语音内容。

### 系统睡眠和恢复

- 用户手动发起两次短时整机睡眠，OS 记录实际睡眠约 3 秒和 31 秒。候选收到系统与屏幕睡眠/唤醒通知；两次通知顺序相反，都在最后一个挂起原因解除后恢复连接和音频，App 唤醒通知到 `AUDIO READY` 约 2.01 秒和 0.84 秒。
- 第一轮受到测试唤醒设置影响，不能用于证明正常睡眠时长。两轮均不构成长时间或整夜睡眠验证。
- 第二轮后第一次与第二次真实语音均正常结束，播放样本为 44,400 / 84,000；用户确认两次文字上屏、首尾完整。
- 另外完成三次 App 冷启动、三次主动重连、三轮约 8 秒熄屏恢复，以及已有真实虚拟麦克风回环回归。App 冷启动不等于系统开机自启；回环使用合成信号，不替代真实语音。

### 离线、扫描窗口与自动返回

1. 11:25:33.798 记录已就绪 RC003 断连。用户将遥控器带离蓝牙范围，11:30:44 检查时仍未就绪，已确认连续离线超过五分钟。
2. 首轮缓存直连超时后，日志显示 `cached_identifier_bypassed=true`；冷却期查询系统候选，数量为 0，进入扫描。
3. 11:26:12、11:26:45、11:28:33、11:30:57 四次真实 `BLE SCAN TIMEOUT` 都进入退避并重建 central，后续发现持续推进。失败计数增长至 9，重试延迟达到 60 秒；缓存冷却探测没有清零失败计数。
4. 用户带回遥控器后曾报告没有恢复。日志确认 11:33:04 自动探测缓存目标，操作号 `d874384d6cf5`，随后 11:33:04.726 `BLE READY`、11:33:04.773 `AUDIO READY`。没有重启 App 或手动重连。实体返回时间未精确记录，不能据此给出“返回到恢复”的时延或判定即时恢复通过。
5. 恢复后 11:35:00 起记录 8 次真实语音，第一段即正常。播放样本依次为 19,680、20,160、21,600、22,560、38,640、35,520、33,840、29,760；全部 `completion=normal`，`enqueue_failures`、`dropped_samples`、`interrupted_samples`、`pending_samples` 均为 0。用户按“至少五次连续短语音”步骤确认全部文字正常、首尾完整。
6. 第一段软件会话开始到首 PCM 为 44 ms，8 段范围 35–180 ms。该计时没有观察实体按键和首字呈现，不能当作端到端耗时；较短语音也不等于极速按下/释放测试。

本轮已覆盖原评审所列“窗口到期后重新发现并接回，再验证首次语音”这一替代验收路径。缓存冷却期的扫描超时在旧主线也有窗口；现场未复现 `retrievePeripherals` 返回空，因此不把这轮结果说成新条件真机复现。缓存空返回/拒绝后的系统候选采纳由生产共用行为回归和反向实验覆盖，实际系统候选采纳未命中。RC001、极速按下/释放、整夜睡眠、#356 长期静默链路及 #924 系统开机自启仍未完成现场验证，不据此宣称全部型号兼容或关闭关联 issue。
