# 开发记录

## 精确接入点

- `Sources/RemoteMic/OnboardingFlow.swift`：步骤、阶段、语音工具选择、实时能力和下一页门禁。
- `Sources/RemoteMic/AppSettings.swift`：流程版本、当前位置、语音工具及完成/重新运行操作的持久化。
- `Sources/RemoteMic/RemoteMicRootView.swift`：在向导和既有设置页之间切换，并在进入硬件步骤时启动运行时。
- `Sources/RemoteMic/OnboardingView.swift`：双栏页面、权限操作、设备与按键状态、真实语音文字测试和固定底部导航。
- `Sources/RemoteMic/OnboardingScreenshotRenderer.swift`：通过离屏 AppKit 窗口渲染生产向导，支持浅色、深色和系统外观，使用隔离偏好域。
- `Sources/RemoteMic/RemoteMicApp.swift`：未完成时强制显示主窗口并延迟完整运行时启动；专用环境变量存在时进入无界面截图模式。
- `Sources/RemoteMic/BridgeAppModel.swift`：在现有蓝牙语音开始与 PCM 解码回调旁公开当前会话样本计数；允许截图模式注入隔离设置，不保存音频。
- `Sources/RemoteMic/SettingsView.swift`：关于页增加“重新运行设置向导”。
- `Resources/*/Localizable.strings`：中英文向导文案。
- `Tests/RemoteMicTests/OnboardingFlowTests.swift`：步骤、门禁、持久化、完成版本和重新运行测试。

## 关键设计

1. 访问过页面不能代表成功。三项权限、连接、实体按键、兼容麦克风、真实音频样本、会话停止、文字出现和三个不同按键均使用当前实时状态。
2. 欢迎与语音工具选择阶段不启动蓝牙和音频，避免页面出现前主动触发系统权限；进入权限页后由根视图一次启动现有运行时。
3. Typeless 分支在权限通过后启用现有 Fn 点按模式；豆包和其他工具关闭该模式。所有分支都使用 MiRemoteV 2ch 完成兼容链路检查。
4. 权限通过后启用现有自定义按键监控，以便向导接收真实 HID 按键；没有新建第二套按键监听器。
5. 关闭窗口不是旁路。未完成时下次启动仍强制显示保存的当前页，主设置页只在写入当前流程版本后出现。
6. 已安装用户可从“关于”页重新运行设置向导；该操作只重置向导完成版本、当前位置和语音工具选择，兼容麦克风、连接、按键映射及其他应用设置保持不变。

## 影响与回归边界

共享蓝牙协议、HID 报告解析、音频格式、设备选择规则和设置页容器尺寸均未改变。已完成用户启动时仍按原逻辑启动服务并根据偏好显示窗口；重新运行向导会暂时用向导替换同一主窗口内容。

## 自动化验证

- `swift test --filter OnboardingFlowTests`：4 项通过，覆盖步骤、阶段、能力门禁、启动门禁、持久化、重新运行及现有用户配置保留。
- `swift test --filter SettingsPageRegressionTests`：5 项通过。
- `swift test --filter LocalizationTests`：5 项通过，中英文 key 和格式一致。
- `swift test --skip productionModelRejectsTestToneWithoutAReadyDevice`：179 项、21 个 suite 全部通过。未运行的单一既有用例会在 `BridgeAppModel` 初始化时阻塞于本机系统钥匙串 `SecItemCopyMatching`，进程采样已确认与 Onboarding 无关。
- `swift build -c release`：通过；只有仓库既有 Keychain API 弃用警告。
- `scripts/build-app.sh`：通过；`codesign --verify --deep --strict` 通过。
- 最终测试 App 使用 `/usr/bin/open -n` 启动成功，进程检查通过；验证后已正常结束测试进程。
- 测试 App：`dist/Remote Mic.app`。
- 实现截图：已完成。锁屏状态下直接实例化生产 `OnboardingView`，通过离屏 AppKit 窗口缓存生成浅色、深色各 8 张真实实现截图，逐页确认原生窗口、实际 App 图标、RC003 图片、底部导航和实时检查区域无裁切；未使用设计稿替代实现证据。截图保存在本地忽略目录 `.codex-screenshots/onboarding-real-20260811-consistent/`。
- 深色模式右侧改为深蓝语义画布和自适应检查卡，与左侧同属深色体系；浅色继续使用浅蓝画布。两种外观均不存在黑白分栏。
- App 内保留隐藏截图入口：设置 `REMOTE_MIC_ONBOARDING_SCREENSHOT_DIR` 后离屏输出全部页面，可用 `REMOTE_MIC_ONBOARDING_SCREENSHOT_APPEARANCE=light|dark|system` 指定外观；正常启动路径不显示入口。
- 本机 Skill：`~/.codex/skills/remote-mic-onboarding-screenshots/`，默认一次生成并校验浅色和深色两套截图。

## 已知限制

自动化无法证明系统权限弹窗、真实 RC003、MiRemoteV 2ch 驱动、第三方语音工具或文字上屏链路在用户机器上可用。完成页只有在运行时检测通过后才可到达，但正式验收仍需执行 `Testing/FirstRunOnboarding.md`。
