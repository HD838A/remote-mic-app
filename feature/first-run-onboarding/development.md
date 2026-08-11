# 开发记录

## 精确接入点

- `Sources/RemoteMic/OnboardingFlow.swift`：步骤、阶段、语音工具选择、实时能力和下一页门禁。
- `Sources/RemoteMic/AppSettings.swift`：流程版本、当前位置、语音工具及完成/重新运行操作的持久化。
- `Sources/RemoteMic/RemoteMicRootView.swift`：在向导和既有设置页之间切换，并在进入硬件步骤时启动运行时。
- `Sources/RemoteMic/OnboardingView.swift`：双栏页面、权限操作、设备与按键状态、真实语音文字测试和固定底部导航。
- `Sources/RemoteMic/OnboardingScreenshotRenderer.swift`：通过离屏 AppKit 窗口渲染生产向导，支持浅色、深色和系统外观，使用隔离偏好域。
- `Sources/RemoteMic/RemoteMicApp.swift`：未完成时强制显示主窗口并延迟完整运行时启动；专用环境变量存在时进入无界面截图模式。
- `Sources/RemoteMic/BridgeAppModel.swift`：在现有蓝牙语音开始与 PCM 解码回调旁公开当前会话样本计数；允许截图模式注入隔离设置，不保存音频；重连入口在 bridge 尚未创建时可启动蓝牙连接。
- `Sources/RemoteMic/SettingsView.swift`：关于页增加“重新运行设置向导”。
- `Resources/*/Localizable.strings`：中英文向导文案。
- `Tests/RemoteMicTests/OnboardingFlowTests.swift`：步骤、门禁、持久化、完成版本和重新运行测试。
- `scripts/test.sh`：把 Onboarding 流程类型加入项目自检的显式编译文件列表。
- `scripts/build-doubao-driver.sh`：驱动签名前移除调试符号，避免发布安装包包含本机构建路径。

## 关键设计

1. 访问过页面不能代表成功。三项权限、连接、实体按键、兼容麦克风、真实音频样本、会话停止、文字出现和三个不同按键均使用当前实时状态。
2. 欢迎与语音工具选择阶段不启动蓝牙和音频，避免页面出现前主动触发系统权限；进入权限页后由根视图一次启动现有运行时。
3. Typeless 分支在权限通过后启用现有 Fn 点按模式；豆包和其他工具关闭该模式。所有分支都使用 MiRemoteV 2ch 完成兼容链路检查。
4. 权限通过后启用现有自定义按键监控，以便向导接收真实 HID 按键；没有新建第二套按键监听器。
5. 关闭窗口不是旁路。未完成时下次启动仍强制显示保存的当前页，主设置页只在写入当前流程版本后出现。
6. 已安装用户可从“关于”页重新运行设置向导；该操作只重置向导完成版本、当前位置和语音工具选择，兼容麦克风、连接、按键映射及其他应用设置保持不变。
7. 升级首次启动若 HID 普通按键先于 BLE Ready 到达，遥控器页只请求一次连接恢复；`reconnect()` 会在 bridge 尚未创建时补启动蓝牙，避免状态只能通过重启解除。

## 设计、开发与测试复盘

### 设计

1. 先按编号顺序查看参考产品全部页面，提取信息节奏、导航层级和单页任务密度；只复用方法，不逐页照搬布局或文案。
2. 把安装问题拆成可观测的成功条件，而不是“用户看过说明”：权限必须实时有效，遥控器必须由 App 实际连接并收到实体按键，音频设备必须存在、被选择且输出就绪，语音必须同时收到会话、PCM、停止和文字。
3. 不显示“共几步”“完成全部才能使用”等压力文案。不可跳过由导航和能力门禁保证，界面只解释当前任务、用途、状态和下一步。
4. 双栏不是简单的白色内容区加深色插画区。浅色和深色分别使用完整的语义色体系，窗口、左栏、右栏、检查卡、按钮和原生控件必须属于同一外观。

### 开发

1. 使用独立的流程模型描述步骤、阶段和能力门禁，用版本化持久化保存完成状态和当前位置；视图只消费状态，不自行推断业务成功。
2. 欢迎和工具选择页不启动完整运行时，进入权限阶段后才启动既有蓝牙与音频服务，避免首次页面出现前连续触发系统权限。
3. 重新运行向导只重置向导自己的状态，不清除连接、按键映射、兼容麦克风、Dock、启动或更新偏好，确保它可以作为普通用户的自助排障入口。
4. 截图入口直接实例化生产 `OnboardingView`，使用隔离 `UserDefaults` 和离屏 AppKit 窗口；不依赖屏幕录制、窗口是否可见或机器是否锁屏。
5. 截图外观必须从 AppKit 窗口根部固定，再让 SwiftUI 环境继承；只修改某个子视图会出现左侧浅色、右侧深色或反向的分裂结果。

### 测试

1. 单元测试覆盖步骤顺序、前后导航、能力门禁、延迟运行时、退出续接、完成版本和重新运行，防止 UI 调整改变流程语义。
2. 静态 UI 验证必须生成浅色、深色各 8 张真实实现截图并逐张查看；文件存在、尺寸正确或接触表正常都不足以证明页面没有裁切或黑白分栏。
3. 发布验证覆盖 Release 构建、签名、公证、staple、锁屏启动、PKG/ZIP 等价、公开资产摘要和 Sparkle 候选更新发现；预览版必须是普通用户可选择检测的公开 Pre-release。
4. 系统权限弹窗、真实 RC003、MiRemoteV 2ch、豆包、Typeless 和其他工具仍属于真实环境验收，自动化和截图不得写成已经替代这些用例。

## 影响与回归边界

共享蓝牙协议、HID 报告解析、音频格式、设备选择规则和设置页容器尺寸均未改变。已完成用户启动时仍按原逻辑启动服务并根据偏好显示窗口；重新运行向导会暂时用向导替换同一主窗口内容。

2026-08-11 的升级恢复修复没有改变全局蓝牙与音频启动顺序，也不会在已连接、未收到实体按键或本页已经请求过恢复时重复重连。真实 Sparkle 升级首次启动和 RC003 仍需按测试手册验收。

## 自动化验证

- `swift test --filter OnboardingFlowTests`：6 项通过，新增覆盖 HID 已到达但 BLE 未连接时的一次性恢复策略，以及按键事件与空 bridge 启动分支的生产代码接线。
- `swift test --filter SettingsPageRegressionTests`：6 项通过。
- `swift test --filter LocalizationTests`：5 项通过，中英文 key 和格式一致。
- `swift test`：194 项、20 个 suite 全部通过，没有跳过用例。
- `scripts/test.sh`：42 项项目自检通过。
- `swift build -c release`：通过。
- `scripts/build-app.sh`：通过；`codesign --verify --deep --strict` 通过。
- 测试 App：`dist/Remote Mic.app`。
- 实现截图：已完成。无需屏幕解锁，直接实例化生产 `OnboardingView`，通过离屏 AppKit 窗口缓存生成浅色、深色各 8 张真实实现截图，逐页确认原生窗口、实际 App 图标、RC003 图片、底部导航和实时检查区域无裁切；未使用设计稿替代实现证据。
- 深色模式右侧改为深蓝语义画布和自适应检查卡，与左侧同属深色体系；浅色继续使用浅蓝画布。两种外观均不存在黑白分栏。
- App 内保留隐藏截图入口：设置 `REMOTE_MIC_ONBOARDING_SCREENSHOT_DIR` 后离屏输出全部页面，可用 `REMOTE_MIC_ONBOARDING_SCREENSHOT_APPEARANCE=light|dark|system` 指定外观；正常启动路径不显示入口。
- 本机 Skill：`~/.codex/skills/remote-mic-onboarding-screenshots/`，默认一次生成并校验浅色和深色两套截图。

## 已知限制

自动化无法证明系统权限弹窗、真实 RC003、MiRemoteV 2ch 驱动、第三方语音工具或文字上屏链路在用户机器上可用。完成页只有在运行时检测通过后才可到达，但正式验收仍需执行 `Testing/FirstRunOnboarding.md`。
