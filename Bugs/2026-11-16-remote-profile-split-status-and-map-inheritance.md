# 遥控器 HID/BLE 档案分裂导致“状态确认中”并跨型号复制映射

- 时间：2026-11-16
- 状态：候选修复，等待真实 RC001/RC003 验收
- 影响范围：小米 RC001/RC003；整体状态卡片、按键映射继承、设备选中与运行时引用
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
- `AppSettings.mappingsForNewRemote(model:)`：只有型号已识别且与当前选中档案同型号时才继承映射；不同型号使用默认映射。无选中档案时保留首次配置的兼容行为。
- `AppSettings.inheritMappingsIfCompatible(for:model:)`：创建时型号未知的小米档案先使用默认映射，BLE 握手识别型号后，只有同型号且映射尚未编辑才继承。移除 `registerHIDRemote` 中跨型号复制“任意已配置档案”的旧路径。
- 日志：新增脱敏 `SETTINGS REMOTE_PROFILE_PAIR ... result=merged` 与 `SETTINGS REMOTE_PROFILE_MAPPINGS ... result=inherited`，不含设备 ID、名称或映射正文。

## 验证

- `swift test --disable-keychain -j 4 --filter 'RemoteProfilePersistenceTests|RemoteDeviceCardStatusTests|RemoteButtonsTests'`：**209 tests / 3 suites passed**。
- 公开模式全量 `swift test --disable-keychain -j 4`：**1503 tests / 111 suites passed**。
- 公开 `swift build --disable-keychain -j 4` 通过；`scripts/verify-repository-governance.sh` 通过。
- 新增回归：互补档案唯一配对合并；不同型号不合并；同型号多组候选不合并；两侧不在线不合并；不同型号不继承映射；同型号仍继承并可独立编辑。
- 待执行：真实 RC001/RC003 连接、按键、语音与卡片状态验收。

## 边界与已知限制

- 只合并“同型号恰好两条互补档案”的无歧义组合。存在多条同型号候选时不自动合并，避免把两台物理遥控器并成一台；此时卡片仍按既有未知状态显示。
- 已在旧版本中复制了其他型号映射的**现有**档案不会被自动清空，因为无法可靠区分“历史误复制”和“用户主动配置”。用户可在按键页选中该设备后使用“恢复默认”，再按需配置。
- 本记录不证明第三方语音工具已收音或文字已上屏；真实硬件与第三方流程仍按 `Testing/ConnectedRemoteCards.md` 用例 3C 和稳定功能回归执行。
