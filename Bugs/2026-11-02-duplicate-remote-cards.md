---
title: 按键页出现两张相同的苹果遥控器卡片
template: doc
---
## 状态与范围
时间：2026-11-02。状态：A2854 已修复，等待真机复验与配发构建；A2540 的档案级去重不成立，改为卡片区展示层去重，见文末 2026-11-05 补充。
范围：按键页页头右侧的遥控器卡片行，以及支撑它的设备档案去重逻辑。不涉及按键映射、键位方案、语音链路或会员判定。

## 现象
按键页顶部并排出现两张完全相同的卡片：同一型号（苹果遥控器第 7 代）、同一序列号、都是「未连接」，操作入口也相同（`点击开通会员功能` / `重试`）。用户此前已反馈过一次，2026-10-25 的 `9c182147 fix(mac): deduplicate persisted Siri Remote profiles`（PR #748）声称已修，但同一现象再次出现。

## 证据
现场数据取自本机 `com.hd838a.RemoteMic` 的 `remoteDeviceProfiles`（共 6 条档案）。其中两条是同一台 A2854：

| 档案 | 型号 | 设备名（脱敏） | `hidFingerprint` |
| --- | --- | --- | --- |
| A（旧） | `apple_siri_remote_a2854` | `C08…330` | `b22deb…` |
| B（新） | `apple_siri_remote_a2854` | `C08…330` | `0f0f3d…` |

两条档案的 `customName` 完全相同（就是这台遥控器的序列号——A2854 首次配对会上报序列号作为蓝牙名），只有 `hidFingerprint` 不同。`selectedRemoteProfileID` 指向其中一条，另一条只是历史残留。

## 根因
1. **去重键错了。** 上一次修复只按 `hidFingerprint` 去重。指纹是「物理唯一 ID → 序列号 → 设备地址 → 位置」这条回退链里第一个可用属性的 SHA-256（私有包 `SiriRemotePlatformSupport.fingerprint`，宿主 `HIDRemoteMonitor.fingerprint` 同构）。链路一变——换接口、重新配对、系统少报一个属性，或指纹算法本身改过——同一台遥控器就会算出第二个指纹，而按指纹去重永远认不出这两条是同一台设备。
2. **只在启动时去重。** `deduplicateRemoteProfiles` 只在 `AppSettings` 初始化加载时跑一次。运行期新产生的重复档案要等下次启动才可能被合并，用户在这期间一直看到两张卡片。

这两点叠加，`9c182147` 对「指纹稳定、重复项在启动时已存在」这一种形状有效，对现场这种「指纹变了」的形状无效，所以现象复活。

## 修复
- **稳定身份。** 新增 `RemoteDeviceIdentity`：序列号是这台设备真正的稳定身份，但序列号本身不得落盘或写日志（`RemoteDeviceNameReader` 里已有这条硬规则），因此只保存 `SHA-256("sayall.remote.serial.v1:" + 大写序列号)`，字段为 `RemoteDeviceProfile.hardwareIdentity`。
- **历史迁移。** 旧档案把序列号存成了设备名。`customName` 形如序列号（8–32 位、全大写字母或数字、含数字）时，用同一个摘要参与身份比较，于是新旧两条档案算出同一个 key，启动时即可并回一条。用户起的普通名字不参与，避免把两台同名遥控器并成一台。
- **运行期收敛。** `AppSettings.collapseDuplicateRemoteProfiles(preferring:)` 在启动、每次连接、每次系统名/序列号刷新后都跑一次，返回「被并掉的 ID → 保留的 ID」，由 `BridgeAppModel` 迁移运行时映射（显示名、电量、电源状态、设备→档案）。
- **保留正在用的那条。** 去重时优先保留 `connectedRemoteProfileIDs ∪ connectedAppleRemoteProfileIDs ∪ connectedChromecastRemoteProfileIDs` 里的档案，否则连接状态和编辑目标会指向一条被删掉的档案。被并掉的一条若有用户配置（非默认映射），映射随合并带到保留的那条。
- **不把身份当标题。** 合并时不再把「像序列号的名字」复制成显示名，卡片标题仍然是型号名。

## 验证
- 新增 4 项单元测试（`RemoteProfilePersistenceTests`）：同序列号跨指纹合并、不同序列号不合并、运行期合并保留在用档案并迁移选中项、合并后不把序列号当显示名。该套 8 项全部通过。
- 离屏渲染生产 `SettingsView`（1067 × 771，中文浅色）：按键页、连接、设置、键位方案、组合动作页均正常渲染，卡片行只有一张苹果遥控器卡片。
- 截图证据保存在仓库外 `~/Develop/ReleaseArtifacts/ui-tweaks-20261102/`：`after-paid/mapping-1067x771.png`（改动后按键页）、`before/mapping-1067x771.png`（改动前，安装版渲染）。
- 另需真机复验：插入历史重复档案后启动，卡片应只剩一张；重新配对后不再新增第二张。

## 边界
- 历史档案如果连「序列号形态的设备名」都没有（早期版本直接把出厂名清成了空串），仍然认不出与它重复的新档案，只能按指纹处理。这类档案的映射已无法与任何设备对应，属于独立的数据清理工作项。
- 去重不会合并两台真实存在、序列号不同的同型号遥控器。

## 2026-11-05 补充：A2540 的硬件序列号与蓝牙名不是同一串

同一现象在苹果第 6 代（A2540）上再次出现，两条档案如下：

| 档案 | 型号 | `customName` | `hardwareIdentity` | `hidFingerprint` |
| --- | --- | --- | --- | --- |
| A（旧） | `apple_siri_remote_a2540` | `DL1…7FC` | 无 | `3e028c…`（已不在线） |
| B（新） | `apple_siri_remote_a2540` | `DL1…7FC` | `5cf510…` | `87ddcd…`（当前连接） |

本机 IOHID 枚举只存在 `87ddcd…` 这一台，A 是历史残留。两条仍然并存，因为
`hardwareIdentity` 是 **HID 序列号**的摘要（`5cf510…`），而历史迁移算的是
**蓝牙名里的产品序列号**的摘要（`3a5018…`）——上面「历史迁移」一节的隐含假设是
「设备上报的 HID 序列号与蓝牙名里的序列号是同一串」，A2540 不成立。

### 为什么不合并档案

- `shouldKeepRemoteProfile` 在两档案评分相同时保留数组里靠前的一条；A 的映射不是全默认，
  `mergingRemoteProfile` 也就不会把 B 的映射带过来，定制过的按键会丢；
- 键位方案与组合动作由私有模块按**设备 UUID** 存储（`buttonProfilesFeature.profiles(for:)`），
  宿主没有随档案合并迁移这些记录的入口，并档会让它们变成孤儿。

### 现在的做法

卡片区展示层去重（`RemoteDeviceNamePolicy.cardsWithoutRepeatedSerial`）：
「同型号 + 同一个像序列号的名字」只展示一条，优先正在连接的那条；正在编辑的那条不参与去重，
避免页面在编辑一台卡片上看不到的设备。只影响渲染，不写 `selectedRemoteProfileID`、
不合并、不删除档案。

### 仍然存在的风险

指纹再次变化（重新配对、系统不再上报 `PhysicalDeviceUniqueID`、或指纹算法升级）时，
会再产生一条默认配置的新档案；页面会显示这条新的，看起来像配置丢失。
根治需要把重复档案真正合并，并把私有模块里按设备 ID 存的键位方案一起迁移，属于独立工作项。

### 验证

`RemoteDeviceNamePolicyTests` 新增 4 项：重复序列号只留一张且优先在用、不同序列号各留一张、
非序列号同名不合并、正在编辑的那条不会被藏。真机 1020 / 1067 / 1129 pt 三种宽度截图复核。
