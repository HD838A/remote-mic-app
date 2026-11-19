# 遥控器 HID/BLE 档案分裂导致“状态确认中”并跨型号复制映射

- 时间：2026-11-16
- 状态：候选修复；2026-11-20 已取消同型号映射继承并要求稳定身份，等待真实 RC001/RC003 验收
- 影响范围：小米 RC001/RC003；整体状态卡片、按键映射隔离、设备选中、档案合并与运行时引用
- 简单描述：同一台遥控器分别以 HID 和 BLE 登记成两条档案。连接卡片读 BLE 档案，按键监视器挂在 HID 档案上，于是按键和语音实际可用但卡片长期显示“状态确认中”。新遥控器创建时又会复制当前选中档案的完整映射，导致 RC001 复制 RC003 配置。

## 现象与证据

用户现场：小米蓝牙遥控器 2 Pro 已连接，普通按键和语音键均有反应，但卡片显示“状态确认中”；96% 电量来自 BLE 档案。

只读检查本机偏好域（未解密任何加密日志）：

- 同一型号存在两条 `rc003` 档案：一条只有 HID 指纹且当前选中，另一条只有蓝牙标识、名称和连接状态。
- 另有 `rc001` 档案的六组映射字段与 `rc003` 蓝牙档案逐字段相同，证明其创建时复制了另一型号的完整映射。
- 连接卡片由 BLE 档案绘制；HID 监视器绑定在 HID 档案上，`remoteButtonReadiness` 也只记录 HID 档案 ID。

## 根因

### 1. 互补档案未收敛

`RemoteDeviceIdentity.key(for:)` 只按硬件身份或 HID 指纹去重。只有蓝牙标识的档案既没有指纹也没有硬件身份，只能按自身 UUID 独占，永远不会与同一台设备的 HID 档案合并。

`BridgeAppModel.remoteCardStatus(for:)` 使用**当前档案 ID**查询按键就绪：

```swift
buttons = remoteButtonReadiness[profile.id]
    ?? .buttons(statusKey: hidMonitors.values.first(where: { $0.profileID == profile.id })?.status.key)
```

BLE 档案没有对应的 HID 监视器，得到 `.unknown`；语音链路为 `.ready`。`RemoteDeviceCardStatus.resolve` 对任一 `.unknown` 返回 `.confirming`，即“状态确认中”。

同时，按键页的编辑目标与 HID 实际执行映射也可能落在不同档案上，导致“改了配置但按键不生效”的潜在问题。

### 2. 新档案复制选中档案的映射，未检查型号

`AppSettings.mappingsForNewRemote()` 原实现直接返回 `selectedRemoteProfile?.mappings`。创建新档案时型号通常还是 `.unknown`，于是不同型号的 RC001 也复制了 RC003 的完整映射。

## 修复

- `AppSettings.reconcileComplementaryRemoteProfiles(connectedProfileIDs:activeHIDProfileIDs:)`：仅在同一小米型号只有两条档案、一条 HID-only、一条 BLE-only，且 HID 侧在线/选中、BLE 侧已连接时合并。双方已有不同硬件身份、蓝牙名称或自定义名称时不合并，避免把两只已命名遥控器并成一台。保留 HID 档案的 ID、监视器、选中状态和执行映射，补入蓝牙标识、名称、电量与连接状态。
- `BridgeAppModel.collapseDuplicateRemoteProfiles()`：在原有同身份去重后调用互补配对，并把被并档案的按键就绪、恢复状态、电量、电源、名称、待处理型号、最后记录状态等运行时引用迁到保留档案。
- `AppSettings.mappingsForNewRemote()`：不再复制任何已存在档案的映射。只有首个档案创建前才接收旧版单设备内存配置；只要已有档案，新遥控器一律使用默认映射，同型号也不例外。
- 删除 `AppSettings.inheritMappingsIfCompatible(for:model:)` 及型号识别后的继承调用，确保第二台同型号遥控器首次出现时与第一台隔离。
- 日志：新增脱敏 `SETTINGS REMOTE_PROFILE_PAIR ... result=merged` 与 `SETTINGS REMOTE_PROFILES ... result=merge_skipped`，不含设备 ID、名称或映射正文。

## 2026-11-20 用户数据完整性复核

用户明确要求以下三条为不可绕过边界：已保存的选中设备不能被自动显示覆盖；同型号的两只遥控器不能共享或继承映射；档案去重、互补合并和版本升级不能静默丢失自定义配置。

只读审计确认了三处风险：

- `selectedRemoteProfileID` 的 `didSet` 无条件写回偏好。连接事件造成的自动回退会把临时显示目标持久化，重启后无法恢复用户上次手动选择的设备。
- `mappingsForNewRemote(model:)` 与 `inheritMappingsIfCompatible` 都会在型号匹配时复制选中档案的完整映射，第二只同型号遥控器因此继承第一只的自定义动作。
- `deduplicateRemoteProfiles` 与 `reconcileComplementaryRemoteProfiles` 在相同稳定身份或互补身份下直接合并；双方存在不同自定义映射时，`mergingRemoteProfile` 只保留其中一侧，另一侧会在没有快照的情况下消失。

修复：

- `AppSettings.selectRemoteProfile(_:persistSelection:)` 区分手动选择和自动显示。手动选择始终写回；自动回退只有在本机从未保存过首选设备时才写回。临时显示状态会继续跟随后续去重/合并迁移，但不会写回偏好。日志新增 `REMOTE MAPPING_DEFAULT ... persisted=<bool>`。
- `BridgeAppModel` 在自动回退前读取 `settings.selectedRemoteProfileID == nil`，并将结果传给选择 API；当前画布仍可临时显示已连接设备，但不会覆盖重启后的首选设备。
- 合并前按类别比较自定义动作载荷、快捷键、APP 档案、次级绑定、连发开关和交互设置；交互设置只把用户实际保存的内容视为自定义，非 nil 的默认值和迁移生成的重复模式都不计入冲突。动作和交互设置分别补齐，不能因为一侧已有另一类自定义配置就丢掉整组映射。冲突时保留两条独立档案并记录 `merge_skipped`。
- 互补合并要求双方共享非空稳定身份（`hardwareIdentity` 或旧序列号名摘要）。仅凭 HID-only/BLE-only 形状和在线状态不再合并，避免把两只同型号遥控器并成一台。当前公开源码中只有苹果 HID 路径写入稳定序列号；RC001/RC003 没有小米序列号写入点，因此不会自动互补合并，原“状态确认中”修复对这些设备暂时不生效，需后续稳定身份或非合并状态方案。
- 同身份冲突档案保留多条时，`profileID(forHIDFingerprint:)` 与 `profileID(forBluetoothIdentifier:)` 优先当前选中档案，避免按键继续路由到第一条。
- 合并后立即重新加载当前选中档案的映射和交互设置，防止下一次编辑用旧内存态覆盖刚补入的用户配置。
- 去重或互补合并前，把合并前档案和选中项写入第一份快照和最新快照。`restoreMergedRemoteProfilesBackup(latest:)` 可从任一快照恢复；当前没有设置页入口。
- `registerBluetoothRemote` 和 `registerHIDRemote` 不再把新标识写入已有另一种传输标识的临时档案，降低握手顺序把两只同型号设备绑到一起的风险。
- 新增 `Testing/RemoteProfileUpgrade.md` 的用户数据完整性回归和对应自动化用例。

验证：

- 定向 `swift test --disable-keychain --filter 'RemoteButtonsTests|RemoteDeviceNameIntegrationTests|RemoteProfilePersistenceTests|SettingsPageRegressionTests'`：**319 tests / 4 suites passed**。
- 公开模式全量 `swift test --disable-keychain`：**1567 tests / 113 suites passed**。
- `scripts/verify-repository-governance.sh` 通过。
- 新增回归：同型号新设备使用默认映射；自动回退不覆盖持久化首选；临时显示档案合并后仍不写回偏好；持久化偏好指向被并档案时重映射；合并后当前执行内存态立即刷新；冲突档案不合并；第一份和最新合并快照可恢复；单侧自定义动作与交互设置分别保留；迁移生成的按住模式不被自定义时间覆盖；非 nil 默认交互设置不阻止安全合并；无稳定身份的互补档案保持独立；冲突同指纹档案按当前选中项路由；部分默认按键字典不被误判为冲突；BLE 注册不收养另一台设备的 HID 档案；缺失可选字段的旧档案升级后保留映射。
- 待执行：真实 RC001/RC003 双设备切换、自动回退后重启恢复、旧配置升级后的按键实际执行。

## 验证（2026-11-16）

- 定向 `swift test --disable-keychain -j 4 --filter 'RemoteProfilePersistenceTests|RemoteDeviceCardStatusTests|RemoteButtonsTests'`：**209 tests / 3 suites passed**。
- 公开模式全量 `swift test --disable-keychain -j 4`：**1503 tests / 111 suites passed**。
- 公开 `swift build --disable-keychain -j 4` 通过；`scripts/verify-repository-governance.sh` 通过。
- 新增回归：互补档案唯一配对合并；不同型号不合并；同型号多组候选不合并；两侧不在线不合并；不同型号不继承映射。
- 待执行：真实 RC001/RC003 连接、按键、语音与卡片状态验收。

## 边界与已知限制

- 只合并“同型号恰好两条互补档案、双方共享稳定身份”的无歧义组合。存在多条同型号候选或任一方没有稳定身份时不自动合并；此时卡片可能继续显示两条，优先保证不把两台物理遥控器并成一台。RC001/RC003 当前生产路径没有稳定身份写入点，因此不会自动合并，原状态卡片问题需后续方案。
- 合并前快照保留第一份原始数据和每次合并前的最新数据；`restoreMergedRemoteProfilesBackup(latest:)` 提供代码级恢复，但当前没有设置页入口，不能据此声称用户可自助恢复。
- 注册期握手顺序仍可能先创建临时未知档案；本次收紧了 BLE/HID 收养条件，但无法在没有稳定身份的窗口内证明两只设备，需真实 RC001/RC003 验证。
- 已在旧版本中复制了其他型号映射的**现有**档案不会被自动清空，因为无法可靠区分“历史误复制”和“用户主动配置”。用户可在按键页选中该设备后使用“恢复默认”，再按需配置。
- 旧档案完全没有稳定身份且蓝牙标识变化时，新连接会创建默认映射档案；旧档案仍保留在列表中，但实际按键可能走新档案。该升级边界需要真实现场确认和独立迁移方案。
- `RemoteDeviceMappings` 使用合成 `Codable`，旧版本读写新版本档案仍可能丢弃未知字段。本次只保证可解码字段和整组解码失败时的原始字节保留，未知字段的无损迁移不在本次范围。
- `unifiedBaseBindings` 和私有按键方案数据仍按旧 profile ID 存储；档案合并后这些跨存储引用可能成为孤儿。公开 `mappings` 已能保留动作，私有方案存储无法在公开仓库验证，需后续独立迁移或真机确认。
- 本记录不证明第三方语音工具已收音或文字已上屏；真实硬件与第三方流程仍按 `Testing/ConnectedRemoteCards.md` 用例 3C 和稳定功能回归执行。
