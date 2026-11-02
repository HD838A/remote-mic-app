---
title: 按键页出现两张相同的苹果遥控器卡片
template: doc
---
## 状态与范围
时间：2026-11-02。状态：已修复，等待真机复验与配发构建。
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
