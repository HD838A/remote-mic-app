# 遥控器档案未沿用导致自定义配置丢失

- 时间：2026-11-22
- 状态：候选修复，自动化通过；真实设备待验收
- 影响范围：macOS；1.9.21、2.0.6、2.0.8、2.0.9 之间的升级和回退；遥控器档案、基础映射、设备级绑定
- 用户现象：从 2.0.6 升级到 2.0.9 后，自定义按键、快捷键、App 配置、双击/长按和连发设置显示为默认值。

## 现场证据

只读检查本机偏好和日志，没有修改用户配置。

本机安装：

- 官方 2.0.9 (424)，`SayAllSourceCommit=cd099c96`，`SayAllBuildChannel=release`。
- 本地 2.0.8 (415)，`SayAllSourceCommit=2bac8fe1`，`SayAllBuildChannel=local`。
- `runtime.log` 显示 2026-11-21 16:59–17:03 运行过 1.9.21 (174)。

当前活动数据：

- `remoteDeviceProfiles` 有 4 条档案，映射均为默认值。
- `selectedRemoteProfileID` 指向当前 rc001 档案，映射为默认值。
- `buttonBindings` 为 14 个默认动作。
- `customApplicationProfiles` 的 7 条 App 配置仍在。
- 常用语归档仍在。

历史数据：

- `remoteDeviceProfilesMergeBackup` 有 3 条旧档案。旧 rc001 和 rc003 各有 2 个自定义快捷键、3 个 App 配置、6 组双击/长按、2 个连发开关。
- `unifiedBaseBindings` 有 33 条档案作用域绑定，全部指向当前活动数组以外的旧档案 ID。
- 可高置信重映射的旧绑定有 10 条，分属旧 rc001/rc003。
- 其余 23 条绑定分属 4 个旧档案 ID。这些旧档案不在任何本机快照中，不能猜测归属。
- `remoteDeviceProfiles.corrupt` 有 6 条旧档案；`buttonInteractionMigrationBackup` 有 6 条旧档案；`buttonBindings.corrupt` 保存旧自定义单击动作。

同一硬件的证据：

- 旧 rc001 与当前 rc001 的蓝牙标识和 HID 指纹一致，但档案 UUID 不同。
- 旧 rc003 与当前 rc003 的蓝牙标识和 HID 指纹一致，但档案 UUID 不同。
- 旧 rc003 的蓝牙标识同时出现在当前一条 BLE-only 档案上，HID 指纹出现在另一条当前档案上。这证明同一台设备被拆成了新档案。

## 根因

### 1. 档案 UUID 没有跨版本保持稳定

1.9.21 在无法解码较新档案时会用一条新 UUID 的 fallback 档案覆盖整组数据。2.0.6 的注册路径还会把新 HID 指纹写到任意选中或未绑定档案上。两条路径都会让同一台物理设备换到新档案。

### 2. 作用域绑定和档案映射分开存储

自定义基础动作保存在 `unifiedBaseBindings`，按 `remoteProfileID` 索引。快捷键、App 配置、双击/长按和连发设置保存在 `RemoteDeviceMappings`。档案被替换或合并后，如果只迁移 `mappings`，`unifiedBaseBindings` 仍指向旧档案 ID。

按键页按当前档案 ID 读取。读不到旧 ID 时回落到默认 `buttonBindings`，用户看到的就是“自定义配置全没了”。

### 3. 当前加载路径不恢复孤儿绑定

2.0.9 已经增加以下保护：

- 加载期禁止写回。
- 无法解码时保留原始字节。
- 合并前保存快照。
- 合并时保护被 `unifiedBaseBindings` 引用的档案。

这些保护只能防止新的覆盖，不能修复已经存在的孤儿绑定。设置页也没有恢复合并快照的入口。

## 修复

- 加载设置后执行一次保守恢复：
  - 从 `remoteDeviceProfilesMergeBackup`、`remoteDeviceProfilesLatestMergeBackup`、`buttonInteractionMigrationBackup`、`remoteDeviceProfiles.corrupt`、`remoteDeviceProfilesUnreadableBackup` 和 `unifiedRemoteProfilesMigrationBackup` 读取历史档案。
  - 两种情况触发恢复：`unifiedBaseBindings` 仍引用旧档案 ID；或者活动数组只有一条 1.9.21 形态的 fallback（未知型号、无 HID 指纹），且历史档案与它共享蓝牙标识或稳定身份。
  - 按稳定身份匹配当前档案。优先级为 `hardwareIdentity`、`hidFingerprint`、`bluetoothIdentifier`。
  - 只有最高优先级匹配唯一时才迁移。HID 指纹不匹配且当前档案已有不同指纹时视为身份矛盾；当前档案完全缺失 HID 时才允许按蓝牙标识回退。
  - 有历史档案但目标不唯一时保持原状并记录跳过日志；完全没有历史档案时保持静默，避免每次启动重复日志。
  - 恢复只补齐当前仍为默认的类别，不覆盖已有自定义值。显式停用和 `buttonRapidPressEnabled=false` 也会保留。
  - 把 `unifiedBaseBindings` 的旧 `remoteProfileID` 重映射到当前档案 ID。
  - 冲突作用域绑定不删除，归档到 `unifiedBaseBindingsRecoveryConflicts`；旧归档无法解码时先保存到 `.corrupt`。
  - 补入历史档案中唯一可用的 `hardwareIdentity`、HID 指纹和蓝牙标识，后续登记继续沿用当前档案 UUID；蓝牙标识与已有 HID 指纹矛盾时不写入。
  - 双击/长按时间在模型级默认值未被用户修改时补回，避免只恢复数据但运行时仍读默认。
  - 存在无法解码的档案或损坏的作用域绑定时不执行恢复，保持原始字节。
  - 恢复前把当前活动档案写入最新合并快照，保留可回滚证据。
  - 不因恢复删除或重建当前档案。
- 合并和恢复后统一重映射作用域绑定，避免 `unifiedBaseBindings` 继续指向被并掉的档案。
- 恢复日志只记录数量和结果，不记录设备 ID、名称、映射正文或用户内容。

## 严格回归测试

新增测试必须覆盖：

1. 1.9.21 格式档案在 2.0.9 加载后保留原 UUID 和全部自定义类别。
2. 连续两次重启后 UUID、选中项和自定义配置不变。
3. 1.9.21 fallback 覆盖后，2.0.9 能从迁移备份恢复自定义配置，且保留当前选中项。
4. 没有 `unifiedBaseBindings` 时，仅凭单条 fallback 与同蓝牙标识的旧档案也能恢复自定义类别。
5. 旧 rc001/rc003 与当前档案按 HID 优先匹配，作用域绑定重映射后可以执行。
6. 当前档案已有自定义值时，恢复不覆盖。
7. 没有硬件匹配的孤儿绑定保持原状，不猜测归属。
8. 两台同型号但标识不同的遥控器仍然隔离。
9. 同身份冲突档案仍按既有规则保留，不为了恢复而误合并。
10. 多条历史记录分别携带快捷键、App 配置、双击/长按和连发时，必须互补合并；显式停用必须保留。

首轮实现 `RemoteProfileContinuityTests`，共 21 项（历史结果），覆盖原 UUID 沿用、fallback 恢复、无作用域绑定的 fallback 恢复、多条历史记录互补合并、快照指纹合并、HID 优先与身份矛盾、不覆盖当前配置、显式停用保留、冲突绑定归档、无法解码档案保护、歧义不猜、无档案不猜和同型号隔离。

## 补充修复：2.0.8 已删除旧档案时的快捷键恢复

首轮修复依赖“旧档案仍在活动数组”或“存在指向旧 UUID 的作用域绑定”。补充调查确认还有一个窄分支：

- 2.0.8 去重时如果保留下来的档案已有任意自定义动作，就不会复制被并档案的整套映射。
- 被并掉的旧档案只留在 `buttonInteractionMigrationBackup`；快捷键也只在旧档案里。
- 当前档案是已知型号、映射为默认，且没有 `unifiedBaseBindings` 或 1.9.21 未知 fallback。
- 2.0.9 原有恢复条件因此不成立，`shortcut(for:)` 读出 `nil`。

临时回归用例已稳定复现：活动档案 rc001、默认映射，旧档案仅在 `buttonInteractionMigrationBackup`，两个快捷键断言失败。

补充修复：

- 新增第三触发：当前选中档案缺少快捷键，且历史快照中存在唯一硬件匹配的旧档案。
- 只恢复缺失的 `customShortcut` 动作和快捷键；当前动作已被用户改成其他值时跳过。
- 历史快照对同一按键给出不同快捷键时跳过，不猜测。
- 恢复成功或当前档案不需要恢复时，把档案 UUID 写入 `remoteProfileShortcutRecoveryEvaluated`。
- 只评估当前选中档案；用户切换档案时立即评估新选中项，不等下一次启动。
- “恢复默认”和导入配置会先写一次性标记，避免用户明确重置后又被旧快照覆盖。
- 一次性标记用于避免用户之后主动重置快捷键时，下次启动又从旧快照回放。
- 恢复前仍保存一次当前活动档案快照；日志只记录结果和数量。

新增回归：

- 已知型号的默认档案从迁移快照恢复快捷键，并在重启后保持。
- 用户重置快捷键后，不再从旧快照回放。
- 两份历史档案给出冲突快捷键时不恢复。
- 当前动作已是自定义值时，不覆盖动作。
- 动作已是 `.customShortcut`、只缺快捷键时也能恢复。
- 多设备切换档案时恢复新选中项，其他同型号档案保持默认。

`RemoteProfileContinuityTests` 从 21 项增加到 27 项。
补充验证：

- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'RemoteProfileContinuityTests'`：**27 tests passed**。
- 公开模式全量：**1643 tests / 114 suites passed**。
- `SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain`：通过。
- `scripts/verify-repository-governance.sh` 与 `git diff --check`：通过。


剩余边界：升级前已经主动重置为默认的用户无法与“升级丢配置”区分；首次运行可能补回一次旧快捷键，之后由一次性标记阻止重复回放。

## 代码位置

- `Sources/RemoteMic/AppSettings.swift`：`recoverRemoteProfileDataIfNeeded()`、`recoverMissingShortcutsFromHistoricalSnapshotsIfNeeded()`、`markShortcutRecoveryEvaluated(_:)`、`legacyFallbackProfileForRecovery(_:)`、`fallbackRecoveryCandidate(_:matches:)`、`mergingRecoveredProfile(_:with:)`、`mergingMissingRecoveredMappings(_:with:)`、`mergingRecoveredInteractionSettings(kept:discarded:)`、`fillUniqueRecoveredIdentifiers(...)`、`uniqueRecoveryTargetID(for:in:)`、`remapScopedBindings(_:)`。
- `Tests/RemoteMicTests/RemoteProfileContinuityTests.swift`：27 项跨版本连续性回归。

## 验证

首轮验证（历史）：

- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'RemoteProfileContinuityTests'`：**21 tests passed**。
- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'RemoteProfilePersistenceTests|SettingsCorruptionRecoveryTests|ButtonBindingConfigurationTests|CompleteConfigurationBackupTests'`：**93 tests / 5 suites passed**。
- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain`：**1637 tests / 114 suites passed**。
- `SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain`：通过。
- `scripts/verify-repository-governance.sh`：通过。


## 边界

- 1.9.21 的可执行文件不能修改。本修复只能让后续版本恢复已被旧版覆盖的数据。
- 未解密 2.0.9 的 `.rmlog`，因此不能把破坏动作唯一归到某个构建。现有证据足以确认当前活动档案丢失和备份中仍有旧数据。
- 23 条没有历史档案的孤儿绑定无法自动恢复。它们需要人工确认设备归属。
- 自动化不能替代真实 RC001/RC003 的升级、重新配对、重启和按键执行验收。
- “用户已重置为默认”与“从未配置”无法完全区分。已知身份的档案不会被重放；只有未知型号、无 HID 的单条 fallback 才会按旧版覆盖场景恢复。
- 冲突归档保留动作值，但不记录来源档案 UUID，也没有自动清理或上限。
