# macOS 27 HID device 回调注册后不投递，显示已连接但遥控器无响应

- 时间：2026-11-15
- 状态：候选修复，自动化、完整测试、Release 构建和项目自检通过；等待 macOS 27 + RC001/RC003 真机断连重连验收
- 影响范围：macOS 27 上的小米 RC001 / RC003；包含 #1037 的 2.0.2 构建
- 功能点：IOHIDManager / IOHIDDevice 输入报告、HID 指纹路由、BLE 状态与 HID 状态的独立性
- 简单描述：连接页和菜单栏显示“已连接”，但遥控器普通按键和语音键没有反应；点击“立即重新连接”后恢复
- 原始记录：2026-11-15 build 392 现场会话 `749B29F5`，用户口述与解密日志

## 现场证据

日志时间均为 UTC；本地时间为 UTC+8。

- 18:50:25.760：`PUBLIC_EVENT ... component=remote action=connection phase=completed result=connected reason=ready source=bluetooth remote_model_family=xiaomi`。BLE/ATVV 语音链路已就绪，UI 显示“已连接”。
- 18:50:25.811–813：BLE ready 后出现三行 `HID START`。App 启动时已经启动过一次 HID 监视器，这是 1.3 秒内的第二次启动。
- 18:50:25.880：`HID REPORT device_callback registered path=device`。
- 18:50:25.886：`HID CONNECTED mode=monitored`。
- 19:16:38.761–19:16:50.249：用户第一次按键。日志出现 50 组、共 100 条 `HID REPORT rejected`，其中 50 条 `excluded_fingerprint`、50 条 `target_fingerprint_mismatch`。同一时间段 `HID REPORT accepted = 0`。
- 19:16:56.131：用户点击“立即重新连接”，出现 `reason=reconnecting`。
- 19:16:56.154：`UI STATUS_ITEM ... from=connected to=disconnected`，同时 `BLE DISCONNECTED phase=disconnecting(1) error_domain=none error_code=0`。
- 19:16:56.337：`BLE CONNECTED`。
- 19:16:56.831：`ATVV CAPS version=256 codec=2 frame=120`，随后 `remote.connection phase=completed result=connected reason=ready`。
- 19:16:56.933：`UI STATUS_ITEM ... from=disconnected to=connected`。
- 19:16:57.808：第一条 `HID REPORT accepted ... buttons=down`。随后方向键、菜单键动作正常执行。

结论：`已连接` 反映的是 BLE/ATVV 状态，不代表 HID 输入报告可用。重连恢复的是 HID 设备绑定，不是 BLE 连接。

## 根因

### 已确认的代码行为

#1037 为 macOS 27 增加了 device 级报告回调，并用下面的规则丢弃 manager 级重复报告：

```swift
path == .device || !hasDeviceCallback
```

这条规则把“device callback 已注册”当成“device callback 正在投递”。注册和投递不是同一件事。

失败现场的结构：

1. 拥有设备的监视器已记录 `device_callback registered` 和 `HID CONNECTED`。
2. 该监视器没有收到任何可接受的报告。
3. 另外两个监视器仍通过 manager 回调收到同一批物理报告，所以每条报告产生两条拒绝记录。
4. 拥有设备的监视器因为 `hasDeviceCallback == true`，会把自己的 manager 回调主动丢弃；如果它的 manager 回调仍在投递，这条可用路径也会被丢弃。
5. 结果：device 路径静默；manager 路径即使仍在投递也不被使用；所有按键都丢失，BLE 状态仍然显示已连接。

### 高置信度触发条件

- App 启动后 1.3 秒内启动了两次 HID 监视器：启动时一次，BLE 进入 ready 后一次。
- 第一次启动已经在同一个 `IOHIDDevice` 上注册 device 回调；第二次启动在同一个设备上停止并重新注册。
- 之后 device 回调不再投递。
- 手动重连会先断开 BLE，macOS 重新创建 HID 设备，新的 device 回调正常投递。

这是间歇性问题。同一代码的 build 390 会话也出现双启动，但 device 回调继续投递。日志无法区分具体是重复注册、run loop 失效还是系统 HID 重绑定；需要回调计数和路径字段才能继续收窄。

### 与 #1037 的关系

- #1037 修的是“写完 native key mapping 后 manager 回调停止投递”。这个方向是正确的，不能直接回滚。
- #1037 的 PR 正文已记录风险：“去重依赖设备指针集合，需关注设备快速重连时的缓冲区生命周期”；未覆盖边界包括“睡眠唤醒后重新附着”。
- 本次失败正好落在“启动 + BLE ready 双重启 / 断连重连”边界。
- 失败原因是兜底与去重判据过强，不是 macOS 27 device 回调方向错误。

## 修复

- 不再按“回调已注册”丢弃 manager 报告。
- manager 与 device 两条路径都处理；按实际到达的 `device pointer + reportID + payload` 在 50 ms 窗口内去重。同一份物理报告只执行一次。
- 只对已经为该设备注册 device 回调的监视器启用双路径去重和健康诊断；其他监视器继续只走 manager 路径，不误报 `device_silent`。
- device 连续两个 10 秒窗口没有报告、manager 仍有报告时，重挂一次 device 回调。60 秒内最多一次，每个 HID 监视器实例最多 3 次；即使重挂失败，manager 路径仍继续处理。
- 日志新增 `path=manager|device|simulated` 到现有 accepted/rejected/deferred/parse_failed/callback_rejected 行。不新增逐报告日志。
- 新增状态日志：`HID REPORT PATH device_delivery=confirmed|recovered`、`fallback=manager reason=device_silent`、`watchdog result=...`。
- 新增每 10 秒最多一行的汇总：`HID REPORT PATH WINDOW window_ms=<actual> device_reports=... manager_reports=... duplicates=... manager_fallback=... device_healthy=...`。只在有报告活动时输出，避免日志爆炸。
- 每个 HID 监视器实例最多 3 次 device 回调重挂，避免退役缓冲区无限增长。

## 验证

- 定向自动化：`swift test --disable-keychain --filter RemoteButtonsTests`，180 项通过。
- 新增回归：
  - 同一 device/report/payload 在 50 ms 内只处理一次；
  - 同一按键的按下与松开 payload 不同，不能被去重；
  - 超过窗口后同一报告重新处理；
  - 不同设备或不同 reportID 不得互相去重；
  - 去重缓存最多保留 8 条。
- 完整测试：`swift test --disable-keychain`，1456 tests / 105 suites 通过。
- Release 构建：`swift build -c release --disable-keychain` 通过。
- 项目自检：`scripts/test.sh` 48/48 通过；`scripts/check-repository-boundaries.sh` 和 `scripts/verify-repository-governance.sh` 通过。
- 真机边界：尚未在 macOS 27 + RC001/RC003 上复测。必须覆盖：
  - 启动后立即按键；
  - 启动后等待再由 BLE ready 触发第二次 HID 监视器启动；
  - 手动“立即重新连接”；
  - 睡眠唤醒后重新附着；
  - 快速连续按下和松开；
  - 语音键按下/释放与尾字完整。

## 2026-11-15 当前会话 FAF36134 复核

- `23:03:36.889` App 启动；`23:03:39.216` 第一次 BLE READY。启动后约 1.8 秒内第二组 HID monitor 启动，持有设备的 monitor 在 `23:03:39.266` 再次注册 device callback。
- `23:07:01.885`–`23:12:38.850`：共 328 条 `HID REPORT rejected`，其中 164 条 `target_fingerprint_mismatch`、164 条 `excluded_fingerprint`；`HID REPORT accepted` 为 **0**。
- `23:12:31` 点击“立即重新连接”后 BLE READY，HID monitor 再次重启；之后仍有 20 条 rejected，accepted 仍为 0。说明重连只重建 BLE，没有恢复持有设备 monitor 的 device 报告。
- 持有设备 monitor 的 `HID CONNECTED` 和状态菜单“按键功能已连接”只证明设备已打开，不证明报告仍在投递。

## 路径健康回归测试

- 将路径窗口、manager fallback、watchdog 退避与上限提取为 `HIDReportPathHealth`，由 HID 报告线程按实际到达的报告更新。
- 新增测试覆盖：
  - device 回调静默、manager 有报告时，必须记录 manager fallback，并在连续两个 manager-only 窗口后请求重挂 device 回调；
  - device 报告恢复后必须记录 `device_delivery=recovered`，并停止 manager fallback；
  - 重复 manager 报告不得计为 fallback；
  - 重挂请求必须遵守 60 秒退避、每个 monitor 最多 3 次，耗尽后只记录一次 exhausted；
  - 源码守卫禁止恢复 `path == .device || !hasDeviceCallback` 的旧判据。

## 2026-11-16 01:20 Build 322 discovery 提升复核

- 会话 `9E9EB1D0`，Build 322，源提交 `50fcdb23`，已包含 #1070/#1077。01:18 的 `49B48964` 会话 device 路径正常（26 条 accepted），但 01:20 会话再次失败。
- `17:21:21` 配置变化后只剩一个 discovery monitor（`HID START ... target_bound=false`），没有 profile monitor。
- `17:21:38.946` 出现 `HID REPORT PATH fallback=manager reason=device_silent`；`17:21:38.977` discovery monitor 探测并提升为 profile monitor（`HID CONNECTED mode=probed`），随后通过 `path=manager` 接受了一次 `volume_up`。
- 提升后该 monitor 的 device 与 manager 回调同时静默；新启动的 discovery monitor 收到 73 条后续报告，全部以 `excluded_fingerprint path=manager` 拒绝。按钮因此再次无响应，语音键仍可用。
- 结论：不能复用处于 probing 状态、刚被提升的 discovery monitor；它的回调生命周期已经失效。必须在提升后重建全新的 profile monitor。

## discovery 提升重建

- `HIDMonitorRebuildPolicy` 决定何时重建：必须已启动、自定义映射开启且不在语音会话中；语音中只记 `HID MONITOR REBUILD phase=deferred reason=voice_active`，语音结束后重试。
- discovery monitor 提升为新 HID profile 后，持久化 profile，异步停止并重建全部 HID monitor；当前这次按键仍先执行，后续报告由全新的 `IOHIDManager`/device callback 接管。
- 日志新增 `HID MONITOR REBUILD phase=started|completed|cancelled|deferred reason=...`，不记录 fingerprint 或原始 payload。
- 回归测试：`HIDMonitorRebuildPolicyTests` 覆盖调度条件、语音中延迟与语音结束后重试，以及源码守卫禁止恢复“提升后只启动 discovery monitor”的旧路径。

## 日志判读

- `HID MONITOR REBUILD phase=started reason=discovery_adoption`：discovery 提升后已开始重建 profile monitor。
- `HID MONITOR REBUILD phase=completed reason=discovery_adoption`：重建完成，后续报告应进入新的 `HID START ... target_bound=true` monitor。
- `HID REPORT accepted ... path=device`：device 路径正常。
- `HID REPORT accepted ... path=manager`：device 路径静默，manager 兜底在工作。
- `HID REPORT PATH fallback=manager reason=device_silent`：device 路径曾经或当前没有投递。
- `HID REPORT PATH device_delivery=recovered`：device 路径恢复。
- `HID REPORT PATH WINDOW ... device_reports=0 manager_reports=N`：确认 device 路径静默而 manager 路径仍在工作。
- `HID REPORT PATH watchdog result=callback_reregistered`：已尝试重挂 device 回调。
- `HID REPORT PATH watchdog result=exhausted`：本监视器实例 3 次重挂均未恢复，manager 兜底继续工作。

## 验证边界

自动化只证明去重策略和既有按键行为没有回归，不能证明 macOS IOHID 的设备回调生命周期。真实结论必须来自 macOS 27 真机日志和实际按键结果。日志不记录原始 payload、设备 UUID、HID 指纹或用户内容。

剩余风险：如果 owning monitor 的 manager 回调也被系统阻断，本修复只能记录 device 路径静默，无法恢复按键；届时需要跨 monitor 回退。下一次现场日志用 `HID REPORT accepted ... path=manager` 与 `HID REPORT PATH fallback=manager reason=device_silent` 区分钟路径是否仍在工作。
