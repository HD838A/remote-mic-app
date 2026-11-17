# 快速连接时遥控器卡片闪现黄色状态

- 时间：2026-11-17
- 状态：候选修复完成，自动化与构建验证通过；待真实遥控器快速连接复验
- 影响范围：macOS 设置 → 按键映射，顶部当前连接的遥控器卡片
- 功能点：遥控器卡片状态展示与连接后的按键/语音就绪检查

## 复现条件

1. 保持一只已配对的 RC001/RC003 在附近，退出并重新打开 SayAll。
2. 打开“按键映射”，观察顶部遥控器卡片左下角状态。
3. 蓝牙连接很快完成。

错误行为：卡片出现时先短暂显示黄色“检查中”或“状态确认中”，随后变为绿色“已连接”。正常行为是快速连接并完成就绪确认时直接显示最终状态，不出现肉眼可见的黄色中间态。

## 证据与代码顺序

现场反馈只描述了可见现象。后续使用私有 `sayall-membership-ops` 仓库的 age identity 和统一密文中的 `DIAGNOSTIC_LOG_PRIVATE_KEY_BASE64` 在本地解密了 2.0.8 build 404 的 `.rmlog`；只读取 `REMOTE CARD_STATUS` 行，未输出设备名、身份或用户内容，解密临时文件已移入废纸篓。可用样本中的 `checking → connected` 持续时间如下（本机时间 2026-11-17）：

| `checking` 开始 | `connected` | 持续 |
| --- | --- | --- |
| 10:39:41.352 | 10:39:41.382 | 30 ms |
| 10:40:03.628 | 10:40:03.740 | 112 ms |
| 10:40:19.882 | 10:40:19.915 | 33 ms |
| 13:55:19.050 | 13:55:19.103 | 53 ms |
| 14:17:44.918 | 14:17:45.177 | 259 ms |
| 17:10:37.292 | 17:10:37.394 | 102 ms |
| 18:43:32.566 | 18:43:32.608 | 42 ms |

7 次样本中位数为 53 ms，最大为 259 ms；这些会话没有出现 `.confirming` 转换。先前用于估算的公开事件 `BLE connected → audio configure ready` 间隔（最长 2.37 秒）不是卡片 `.checking` 的可见窗口，音频恢复可以在卡片已经稳定后继续发生；不能用它推导卡片确认期。

代码顺序进一步确认：

- `BridgeAppModel.refreshBluetoothPresentation()` 先根据 BLE 状态写入 `connectedRemoteProfileIDs`，再由 `defer` 记录卡片状态。按键页顶部只渲染已连接档案，因此卡片出现的时刻正是 BLE 已连接、但按键/语音就绪尚未稳定的时刻。
- BLE `.ready` 分支在 `refreshBluetoothPresentation()` 之后才调用 `ensureVirtualAudioOutputReady(...)`；HID monitor 也可能仍在 `waiting_for_device`/`disabled` 状态。
- `remoteCardStatus(for:)` 在这些中间条件下分别返回 `.checking`（按钮或语音仍在检查）或 `.confirming`（音频/语音出口尚未确认）。`RemoteDeviceCardStatus.color` 对这两种状态都返回橙色，`RemoteDeviceCard` 直接按该状态渲染。
- 因此不存在“黄色状态是从持久化数据读出来的”问题；它是连接成功后、完整就绪前的真实中间态，只是展示窗口极短，形成了闪烁。

## 根因

遥控器卡片把“连接是否建立”和“连接后的功能就绪是否确认完成”放在同一个即时状态行中展示。快速连接时，后者的 `.checking`/`.confirming` 只持续几十到几百毫秒，却仍被立即渲染为橙色，形成用户可见的闪烁。

## 修复

- 新增 `RemoteCardStatusSettlingPolicy`，为 `.checking`/`.confirming` 增加 0.8 秒确认期；该值取解密日志最大 259 ms 的约 3 倍余量。
- 确认期内显示中性颜色的“已连接”，不再显示黄色；若确认在窗口内完成，卡片直接使用最终的绿色 `.connected`。
- 若状态持续超过 0.8 秒，仍显示黄色“检查中”/“状态确认中”，不隐藏真实的持续检查。
- 失败状态（按键异常、语音异常、设备异常）立即显示，不进入确认期。
- 已经确认过绿色或失败时，短暂复检保留上一个已确认状态；复检超过窗口后再显示黄色。
- 连接历史卡片与设置页截图夹具保持原有即时呈现，避免改变显式状态截图和恢复流程。
- 该策略只影响展示，不改变 `BridgeAppModel` 的就绪判定、连接流程或音频路径。

## 验证

- 新增 `fastReadinessSkipsTransientCheckingAndConfirming`：快速从 `checking → confirming → connected` 时不显示橙色。
- 新增 `observedCheckingWindowDoesNotFlashOrange`：覆盖解密日志中最长的 259 ms 检查窗口。
- 新增 `persistentVerificationAppearsAfterGracePeriod`：超过 0.8 秒的持续检查仍会显示黄色。
- 新增 `shortRecheckKeepsLastVerifiedStatus`：短暂复检不冲掉已确认状态；持续复检超过窗口后显示黄色。
- 新增 `failuresAndVerifyingStateStayTruthful`：失败立即显示，中性确认态仍以 `.connected` 文案表达。
- `swift test --disable-keychain --filter RemoteDeviceCardStatusTests` 通过（12 项）。
- `swift build --disable-keychain -c release` 与 `git diff --check` 通过。
- 生产 `SettingsView` 截图夹具新增 `verifying` 场景，用固定 `.verifyingConnection` 展示中性“已连接”；`checking` 场景仍展示黄色“检查中”。已在 1067 × 732 内容区、中英文、浅色/深色下生成实际运行截图，作为 PR 附件证据。截图夹具只证明静态呈现，不证明真实连接时序。

## 自动化与真机边界

单元测试只能证明状态收敛策略的输入/输出和时序边界；SwiftUI 实际渲染、真实 BLE/HID/音频就绪时序仍需要真实 RC001/RC003 快速重连验证。需要在应用冷启动、窗口已打开、遥控器靠近三种条件下确认卡片不出现肉眼可见的黄色中间态，同时确认超过 0.8 秒的真实检查仍会显示黄色，并且失败状态没有被延迟。解密样本来自 2.0.8 build 404 的 7 次 `.checking` 转换，均未出现 `.confirming`，不能替代修复后构建的真实设备矩阵。
