# 小米先收到 HID 后出现两条档案

## 证据和根因

在 `v2.0.8` 与 `d48f7795` 分别运行原档案登记逻辑。准备一条只有 HID 指纹的未知型号档案，再登记同一设备的 BLE 标识。预览版返回原档案，一共一条。原主线返回新档案，一共两条。旧互补合并按已识别型号分组，BLE 型号回调无法更新另一条 HID 档案。没有此顺序的现场日志，以上为代码与最小实验结果。

## 修复和验证

首次蓝牙登记用现有系统 UUID 指纹核对唯一 HID 档案。匹配时保留原档案 ID、选中项和映射。对已拆分档案，仅在当前 BLE 在线、HID 有使用证据、型号分组无歧义且配置无冲突时使用同一证据归并。归并前保存原档案快照。真实语音和卡片仍按原有就绪门禁判断。

公开自动化用 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'RemoteProfilePersistenceTests|OnboardingFlowTests|BluetoothLifecycleTests'` 验证。实机应从 RC001、RC003 的首次配对和旧档案升级分别检查第一枚普通按键、卡片、改名、电量、首次语音和重启后映射。
