# 重新配对后 HID 指纹与 BLE identifier 分裂，遥控器语音链路永久超时

- 时间：2026-11-21
- 状态：代码修复与自动化完成；真实遥控器待验证
- 影响范围：macOS；小米 RC001 / RC003 的 CoreBluetooth identifier 发生变化后仍选中原档案
- 功能点：遥控器档案身份同步、BLE 语音连接恢复、由 BLE Ready 派生的音频就绪状态
- 简单描述：普通按键 HID 正常，但语音 BLE 一直连接超时；已有档案的 HID 指纹已指向当前遥控器，BLE identifier 仍指向旧配对，形成自锁。

## 现场证据

本机 `runtime.log`：

```text
AUDIO READY target={name=MiRemoteV 2ch ...}
AUDIO RELEASE requested reason=bluetooth_not_ready ... ready_bridges=0
PUBLIC_EVENT ... component=remote action=connection phase=failed
             result=failed reason=bridge_failed ... remote_model_family=xiaomi
BLE CONNECTING ... source=target_identifier
BLE CONNECT TIMEOUT
...
ONBOARDING EVENT kind=blocked step=audio failure=audio.output_not_ready
```

档案与当前系统身份对照（不记录具体 identifier）：

- 当前 HID `PhysicalDeviceUniqueID` 的 SHA-256，等于选中档案的 `hidFingerprint`。
- 当前系统 BLE peripheral identifier，等于当前 HID `PhysicalDeviceUniqueID`。
- 选中档案保存的 `bluetoothIdentifier`，是另一个旧值。

因此这不是新设备产生新 identifier 的正常情况，而是同一物理遥控器的档案只更新了 HID 一半：

```text
选中档案
├─ HID 指纹 = 当前物理遥控器      ✅
└─ BLE identifier = 旧配对值      ❌
```

## 根因

1. HID 注册路径会把当前 HID 指纹绑定到已有档案。
2. BLE identifier 只在 bridge 真正 Ready 后写回档案。
3. 档案 bridge 持续使用旧 BLE identifier 连接并超时，因此永远不 Ready，新 identifier 也就永远没有机会写回。
4. 发现 bridge 能看到当前系统设备，但现有采纳逻辑没有用 HID 指纹把它和已有档案关联；它只能等待连接成功后注册新档案，或者创建一个新的 BLE-only 档案。

这是一个档案身份自锁，不是音频页、音频驱动或新设备应当产生不同 identifier 的问题。

## 修复

- 新增 `RemoteIdentityFingerprint`：用与 HID 指纹相同的 SHA-256 规则，把当前 BLE identifier 转成可与档案比较的指纹。
- 新增 `RemoteIdentityReconciliationPolicy`：只有同时满足以下条件才替换：
  - 当前 identifier 的指纹唯一命中一个档案的 HID 指纹；
  - 档案不是 Apple / Chromecast 私有适配器；
  - 档案已有旧 BLE identifier，且与当前 identifier 不同；
  - 当前 identifier 没有被其他档案占用。
- `AppSettings.replaceBluetoothIdentifier` 只替换 BLE 字段，保留档案 ID、HID 指纹、型号、名称、选中状态和全部按键映射；发现冲突时拒绝写入。
- 发现 bridge 在采纳候选前调用同一同步入口；命中后停止旧 identifier 的 bridge，移除旧恢复预算，按当前 identifier 建立新 bridge。
- 新设备没有 HID 指纹命中时保持原行为：连接成功后创建 / 选择新档案，不覆盖旧档案。
- 日志新增 `BLE IDENTITY phase=completed result=replaced reason=hid_fingerprint_match` 和 `SETTINGS REMOTE_IDENTITY ...`，只记录结果和型号，不记录 identifier。

## 影响范围

### 会受影响

- 小米 RC001 / RC003 的 BLE 语音连接：当当前系统 BLE identifier 与档案 HID 指纹证明是同一物理设备，而档案 BLE identifier 是旧值时，自动改用当前 identifier 重连。
- 上述档案的 BLE 恢复：旧 identifier 的重连会被停止，避免继续刷超时。
- 由 BLE Ready 派生的虚拟音频就绪、连接卡片状态和语音链路恢复。

### 不受影响

- 新设备连接：没有 HID 指纹命中时仍按原逻辑创建 / 选择新档案，不覆盖旧档案。
- Apple 遥控器和 Chromecast：使用私有适配器，策略明确排除。
- 普通按键 HID、按键映射、自定义名称、选中档案、音量、持久化格式：只改 `bluetoothIdentifier`，其他字段不动。
- Onboarding 页面元素、文案、`ready_required` 门禁：未修改。
- 手机 / 网页 / Watch 连接、音频编解码、第三方语音工具集成：未修改。
- 多设备同名：按 HID 指纹识别物理设备；指纹重复、identifier 已被占用或语音进行中都拒绝替换。

## 与 1.9.21 的对照

`v1.9.21` 的 Onboarding 音频页门禁同样是 `audioOutputSelected && (controlMethod.usesOnDemandAudioOutput || audioReady)`，`physicalRemote` 不在按需分支；桥断开也会释放输出。因此 1.9.21 没有单独的“音频页绕过”。

1.9.21 没有暴露，最可能是当时档案 BLE identifier 仍有效，桥能 Ready，输出没有被释放。不能据此断言 1.9.21 正确处理了 identifier 变化；当前判定以本机档案和日志为准。

## 验证

自动化结果：

- `swift test --disable-keychain --filter 'BluetoothLifecycleTests|RemoteDeviceNameIntegrationTests'`：50 项通过。
- `swift test --disable-keychain`：1,579 项、113 个 suite 通过。
- `./scripts/test.sh`：48 项自测通过。
- 公开模式 `swift build --disable-keychain` 与 `scripts/build-app.sh` Release App 构建通过；`scripts/verify-repository-governance.sh` 通过。

覆盖：

- `RemoteIdentityReconciliationPolicy`：唯一命中、identifier 冲突、重复 HID、私有适配器、已是当前值、无 BLE 字段。
- `AppSettings.replaceBluetoothIdentifier`：替换后档案 ID / HID / 型号 / 映射不变，重启后持久，冲突不写入。
- 发现 bridge 接线：候选采纳前调用同步入口。

真实设备待验证：

- 重新配对 RC003 使 CoreBluetooth identifier 改变，保留原档案映射和选中状态；
- 启动后确认出现 `BLE IDENTITY ... replaced`、`BLE CONNECTING` 使用当前 identifier、`BLE READY`，且没有重复档案；
- 新设备仍创建新档案，不覆盖旧档案；
- 两台同名遥控器不串台；
- 第一次普通按键、极速语音按下/释放、尾字完整和第三方文字上屏。

## 验证边界

- 自动化不能证明 CoreBluetooth 会接受当前 identifier 的 GATT 连接。若系统 / 遥控器链路本身拒绝连接，档案会更新到当前正确 identifier，但语音仍不可用；此时日志会显示当前 identifier 的连接超时，而不是继续尝试旧值。
- 本修复不改变音频处理、Onboarding 页面或任何用户可见功能。
