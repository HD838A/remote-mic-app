# 双传输档案旁多出默认 BLE 档案导致卡片常驻“状态确认中”

- 时间：2026-11-21
- 状态：候选修复；自动化通过，真实 RC003 与卡片状态验收待完成
- 影响范围：macOS；2.0.8 build 413 及同类构建；一只小米遥控器同时留下“HID+BLE”档案和“仅 BLE”档案时
- 功能点：`AppSettings.reconcileComplementaryRemoteProfiles`、连接页设备卡就绪状态

## 现场证据

2.0.8 build 413 的同一进程有 3 条档案：

- 一条 `rc001` 双传输档案；
- 一条 `rc003` 双传输档案，保存用户自定义动作、快捷键、App 绑定、次级绑定和快速连按；
- 一条 `rc003` 仅 BLE 档案，没有自定义名称、快捷键、App 绑定、次级绑定或快速连按，只有迁移产生的按住模式。

仅 BLE 档案的 CoreBluetooth identifier 按 HID 指纹同一规则计算 SHA-256 后，正好等于双传输档案保存的 `hidFingerprint`。这证明两条记录指向同一台物理遥控器，而不是仅凭型号和字段形状猜测。双传输档案自己的旧蓝牙标识哈希不同，说明它是重新配对前的旧值。

用户选中的是最后一条仅 BLE 档案。日志反复出现：

```text
SETTINGS REMOTE_PROFILE_PAIR phase=skipped result=not_merged model=rc003
reason=hid_only_count group_count=2 hid_only=0 ble_only=1 both=1
active_hid=false selected_hid=false connected_ble=true
```

同一时段卡片就绪状态分成两半：

```text
REMOTE CARD_READINESS ... state=confirming model=rc003 connected=true
profile_hid=false profile_bt=true hid_monitor=false
button_reason=hid_monitor_missing voice=ready ...
```

另一条 `rc003` 卡片记录：

```text
REMOTE CARD_READINESS ... model=rc003
profile_hid=true profile_bt=true hid_monitor=true
button_reason=not_connected ...
```

因此按键和语音实际可用，但被选中的 BLE 档案只看到蓝牙链路，看不到 HID 监视器，卡片一直停在“状态确认中”。

## 根因

现有互补合并只处理“恰好一条 HID-only + 一条 BLE-only”，并要求 `hidOnly.count == 1`。实际现场是“一条 HID+BLE + 一条 BLE-only”，所以：

- `hid_only=0`；
- 合并条件在 `reason=hid_only_count` 处直接跳过；
- 双传输档案继续持有 HID 和用户映射，BLE-only 档案继续持有当前蓝牙连接；
- 两张卡片各自只看到一半链路。

这不是连接失败，也不是语音链路失败。它是档案分裂后的卡片就绪判断问题。

## 修复

新增一条很窄的修复路径，仅在同一型号恰好两条档案时执行：

- 一条同时有 HID 指纹和蓝牙标识；
- 一条只有蓝牙标识且仍连接；
- 仅 BLE 档案的当前 identifier 按 HID 指纹同一规则计算 SHA-256，必须等于双传输档案的 `hidFingerprint`；
- 双传输档案被选中或持有活动 HID；
- BLE-only 档案没有任何用户可编辑内容：自定义名称、动作、快捷键、App 绑定、次级绑定、快速连按、自定义按住都必须为空或仅为旧迁移默认；
- 双传输档案没有同时处于 BLE 连接状态，避免把两只真实遥控器并成一只。

满足时保留双传输档案，把它的旧蓝牙标识替换为当前连接的标识，移除默认 BLE-only 档案，并把选中项和持久化选择迁移到保留档案。合并前写入既有恢复快照。

身份匹配使用与 HID `PhysicalDeviceUniqueID` 相同的 SHA-256 规则。若 HID 指纹来自序列号、设备地址或其他分支，匹配会安全失败，继续保留两条档案。

## 验证

自动化：

- `defaultBLEOnlyDuplicateBesideBothProfileIsMerged`：BLE identifier 哈希与 HID 指纹一致、默认 BLE-only 档案被选中时收敛为一条，保留自定义动作、快捷键、App 绑定、次级绑定、快速连按和按住，蓝牙标识更新，选中项迁移，恢复快照可还原。
- 拒绝用例覆盖身份哈希不一致、BLE-only 自定义名称、自定义动作、自定义按住，以及双传输档案不活跃、BLE 未连接、双传输档案自身也在 BLE 连接三种歧义。
- 公开宿主构建与目标测试通过，命令记录在交付说明中。

待现场验证：

- 使用真实 RC003，构造“双传输 + 默认 BLE-only”两条档案，确认卡片只出现一次、显示绿色“已连接”，按键页映射和语音都正常。
- 使用两条都有自定义数据的档案，确认不自动合并，用户配置不丢失。
- 断开、重连、冷启动、切换选中项和恢复快照。
- 日志确认出现 `kept=both reason=default_ble_duplicate`，不再反复 `reason=hid_only_count`。

## 边界

- 身份证明只覆盖 HID `PhysicalDeviceUniqueID` 分支；来自序列号、设备地址或 LocationID 的 HID 指纹不会误配，继续保留两条档案。
- 不要求用户重新配对；修复在已有档案上执行，并保留恢复快照。
- 自动化不能替代真实 CoreBluetooth、HID、系统蓝牙名称和卡片视觉状态验收。
- 若现场仍出现两张卡片，优先检查 BLE identifier 哈希是否等于双传输档案的 HID 指纹、BLE-only 是否有任一自定义字段，以及双传输档案是否被判定为不活跃；不要通过重复配对制造新档案。
