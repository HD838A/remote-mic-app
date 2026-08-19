# Onboarding 未同步 Typeless Fn 点按且 HID 已可用仍显示遥控器未连接

- 时间：2026-08-19
- 状态：候选修复完成，等待真实 Typeless 与 RC001 / RC003 验收
- 影响范围：macOS Onboarding；Typeless、实体遥控器连接页

## 复现

### Typeless

1. 在 Onboarding 选择 Typeless。
2. 选择 iPhone App 或网页版并完成权限页。
3. 查看“语音键模拟 Fn 点按”设置。

旧结果：只有实体遥控器路径离开权限页时才同步该设置；iPhone 与网页路径保持关闭。重新选择豆包、微信或其他工具时也可能保留旧的 Typeless 偏好。

正确结果：选择 Typeless 后偏好应为开启，并在所有控制方式通过权限页时应用到运行时；选择其他工具时关闭。

### 实体遥控器

1. 遥控器已与 macOS 配对，CoreBluetooth 语音 bridge 尚未进入 Ready。
2. 按下一个能够通过生产 `HIDRemoteMonitor` 设备匹配和报告解析的普通遥控器按键。

旧结果：页面已显示“收到控制按键”，但 `selectedControlConnected` 仍只读取 `model.isConnected`，所以连接状态与继续门禁仍可能显示未连接，直到语音 bridge Ready 或 App 重启。

正确结果：经过生产 HID 链路验证的遥控器按键也能证明实体控制已被识别；后台仍继续恢复语音 bridge，后续真实语音页仍必须收到开始、PCM 和停止事件。

## 日志与证据

本轮用户反馈没有附带新的现场日志，因此不把 CoreBluetooth 为何延迟 Ready 写成新的已确认上游根因。已有缺陷记录 `2026-08-11-onboarding-upgrade-hid-before-ble.md` 已确认 HID 与语音 CoreBluetooth 是独立链路，并记录过“按键已到达、BLE 尚未 Ready”的稳定代码边界；`2026-08-11-onboarding-new-remote-ble-hid-refresh.md` 记录了新配对时 discovery 与 HID 刷新问题。

本轮在正式修改前增加回归测试：旧代码因缺少 `isPhysicalRemoteRecognized` 无法编译；Typeless 偏好测试在旧 setter 下也会失败。该复现只证明确定性的状态聚合与偏好同步缺口，不能代替用户现场时序日志。

## 根因

1. `AppSettings.setOnboardingVoiceTool` 只保存工具选择，没有同步 `voiceFnTapModeEnabled`。
2. `OnboardingView.continueFlow` 又把 Fn 点按运行时同步限制在实体遥控器路径，导致 iPhone 与网页路径遗漏。
3. 实体遥控器的连接门禁只接受 ATVV/CoreBluetooth bridge Ready，没有接受已经由小米遥控器 HID 设备匹配与报告解析链路验证的普通按键证据。

## 修复

1. 保存 Onboarding 语音工具时同步持久化 Fn 点按偏好：Typeless 开启，其他工具关闭。
2. 三种控制方式通过权限页时都把当前工具对应的 Fn 点按偏好应用到运行时；只有实体遥控器仍额外启用自定义按键映射。
3. 实体遥控器连接页的识别状态改为“语音 bridge Ready，或已收到经过生产 HID 链路验证的普通遥控器按键”。后者命中时页面显示“已识别实体遥控器”，并保留既有一次性语音 bridge 恢复；完成页仍要求当前语音 bridge Ready。
4. 不接受任意键盘事件或仅系统蓝牙列表中的文字状态；完整 Onboarding 仍由后续真实语音和三个普通按键门禁兜底。

## 验证

- 修复前：`swift test --filter OnboardingFlowTests` 因缺少实体遥控器识别策略失败。
- 修复后：同一命令 26 项通过。
- `swift test`：312 项、31 个 suite 全部通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：42 项项目自检通过。
- Apple Silicon Release App 构建、`codesign --verify --deep --strict` 与 `scripts/verify-app.sh` 通过。
- `swift build -c release --triple x86_64-apple-macosx13.0`：通过。
- 生产 Onboarding 实体路径浅色、深色各 9 张均为 `2040 × 1608` PNG；遥控器页与语音工具页无内部滚动、裁切或黑白分栏。隐藏渲染入口没有注入真实 HID 按键，因此“已识别实体遥控器”的新运行时状态仍归入真机验收。

## 验证边界

自动化证明偏好持久化、三种控制方式的应用接线和 BLE/HID 状态聚合策略；尚未真实操作 Typeless 开关，也未用 RC001 / RC003 复现“系统已连接、HID 按键到达、语音 bridge 尚未 Ready”的现场时序。真实遥控器语音仍需执行 `STREAM_START → AUDIO → STREAM_STOP` 基线。
