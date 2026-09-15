# Siri Remote A2540 无响应、Magic Mouse 变慢与安装器选择状态

## 复现与日志证据

- 当前测试机同时连接 Siri Remote A2540 与 Magic Mouse；启动无线麦SayAll.app 后 Magic Mouse 明显变慢，退出 App 后立即恢复。系统鼠标与滚动速度偏好在前后没有变化。
- IORegistry 显示 A2540 的 Apple Product ID 为 `0x0314`，Magic Mouse 为 `0x0269`；既有 A2854 为 `0x0315`。
- A2540 已由 macOS 识别并连接，但旧适配器的 HID 与语音匹配只接受 `0x0315`，因此没有按键、触摸或语音事件。
- 安装器 Distribution 把 Siri Remote 可选组件的 `start_selected` 固定为 `false`，即使 receipt、Helper 与 LaunchDaemon 已存在也不会自动选中。

日志和文档只记录稳定型号与 Product ID，不记录设备名称、地址、序列号或设备 UUID。

## 根因

私有触摸桥旧逻辑从 `MultitouchSupport` 设备中选取第一个外接小尺寸设备，没有核对对应 IOKit service 的 Product ID，因此可能对 Magic Mouse 调用 `MTDeviceStart`。A2540 同时被运行时能力、HID manager 和语音控制器的 A2854-only 条件过滤。安装器则没有读取既有安装状态。

## 修复

- 触摸桥通过 `MTDeviceGetService` 取得 IOKit service，只允许 `0x0314` 与 `0x0315`，并要求与当前遥控器型号一致；Magic Mouse `0x0269` 必须拒绝。
- A2540 进入候选运行时，HID 与语音接口同时匹配 `0x0314/0x0315`；完整实机矩阵完成前仍保持 `awaitingRealHardware`，不提前标记为已验证。
- A2540 的连接页图片、比例与锚点复用 A2854 资源。
- Apple Silicon 与 Intel Distribution 在首次安装时仍默认不选；检测到 Siri Remote receipt、Helper 或 LaunchDaemon 时自动选中。最终 PKG 校验会通过 `installer -showChoicesXML` 验证当前机器的实际选择结果。

## 验证

- 私有 Siri Remote Package：49 项 Swift 测试通过，覆盖 A2540/A2854 匹配、Magic Mouse 拒绝及图片复用。
- 公开安装器静态门禁通过；最终 PKG 还必须完成既有安装自动勾选、签名、公证、staple、Gatekeeper 与远端下载回验。
- 当前测试机仍需用最终签名包验证：App 运行期间 Magic Mouse 速度不变；A2540 普通键与触摸有事件；语音必须在 `MiRemoteV 2ch` 和目标输入法产生非零电平与最终文字。自动化、构建和设备枚举不能替代这些真实流程。
