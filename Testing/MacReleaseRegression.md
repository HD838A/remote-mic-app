# macOS 重大发布回归用例总表

## 用途与唯一性

本文件是无线麦 SayAll macOS 公开仓库在每次重大发布前必须执行的回归用例索引。

- 本文件只定义“发布阻断结果、唯一权威步骤和自动化边界”，不复制各手册的操作步骤、日志字段或失败判定。详细步骤以“唯一权威步骤”列指向的手册为准。
- 每个场景只有一个权威手册。功能手册可以保留自身专项步骤，但不得再另建一份发布级稳定回归清单；需要跨功能执行时引用本表。现有标题为“稳定功能回归”的段落如果与本表冲突，发布执行以本表为准；修改该段落时必须同步收敛为引用本表或删除重复项。
- 自动化不另建第二套命令清单。发布前以 `.github/workflows/mac-ci.yml` 的 required contexts 和 `scripts/verify-release-ready-main-ci.sh <精确 SHA> main` 为唯一自动证明；发布 staging、publication 和 promotion 的自动门禁以 `.github/workflows/mac-release-package.yml`、`mac-preview-publication.yml` 和 `mac-stable-promote.yml` 为准。
- 表中任一行未通过即阻断发布。确因硬件、会员服务或第三方工具不可用而无法执行时，必须逐项标记“未验收”，不得写成通过，也不得用单元测试、构建、签名或截图替代。

## 执行前读取的当前值

以下值会随代码变化。执行时以源码或脚本为准，不把本表数字当成独立配置：

| 项目 | 当前值 | 权威来源 |
| --- | --- | --- |
| 设置窗口默认/最小尺寸 | 整窗 `1067 × 760`，窗口内容区 `1067 × 732`；SwiftUI 内容下限为 `980 × 732` | `Sources/RemoteMic/RemoteMicApp.swift` 的 `settingsWindowFrameSize`；`Sources/RemoteMic/SettingsView.swift` 的 `minimumContentSize` |
| Onboarding 画布 | `1020 × 772` | `Sources/RemoteMic/OnboardingScreenshotRenderer.swift` |
| 公开 Preview payload | 10 项 payload 加 `candidate-provenance.json`，不发布 DMG | `config/release-assets.json`；`Testing/MacReleaseAssetMatrix.md` |
| manifest / provenance schema | manifest `2`；新 publication 生成 provenance `6` | `config/release-assets.json`；`scripts/publish-preview-release.sh` |
| staging 超时 | supervisor `1200` 秒；单架构 lane `1140` 秒；公证阶段 `600` 秒；签名 step `30` 分钟 | `.github/workflows/mac-release-package.yml`；`scripts/notarize-release.sh` |
| 加密日志 | 单段 `10,000,000` 字节；目录目标 `32 MiB`、保留 7 天、最多 16 段 | `Sources/RemoteMic/AppLogger.swift` |
| 当前私有平台清单 | 以 `config/release-dependencies.json` 为准，不在本表固定 Tag | `config/release-dependencies.json` |
| 公开资产下载 | ZIP、Install/Uninstall PKG、appcast、中英文说明、provenance；无 DMG、无 `.sha256` 资产 | `Testing/MacReleaseAssetMatrix.md`；`config/release-assets.json` |

历史手册中的固定版本号、固定 Build、固定 Tag、DMG 路径和旧窗口尺寸只属于当时的证据，不得作为本次发布门槛。

## A. 发布、安装与更新

| ID | 必须通过的用户结果 | 唯一权威步骤 | 自动化证据 / 人工边界 |
| --- | --- | --- | --- |
| REL-01 | 发布源码是精确 `origin/main` 或合法 `origin/hotfix/vX.Y.Z`；版本、Build、中英文说明只改允许文件；精确 SHA 的源码分支 CI 成功。 | `Testing/MacReleaseBranchLifecycle.md` 用例 1–3；`RELEASING.md` 发布前准备 | CI + `verify-public-release-source.sh`、`verify-release-ready-main-ci.sh`；发布运行的真实 SHA 和 CI 证明需人工核对 |
| REL-02 | 发布基线、Build 号递增和构建来源正确；产物的 `SayAllSourceCommit` 与构建树一致；发布说明中的 Commit 来源不得手写。 | `RELEASING.md` 发布基线门禁与构建来源；`Testing/MacReleaseBranchLifecycle.md` 用例 1 | `verify-release-baseline.sh`、`verify-release-asset-source.sh` 及 fixture；产物读回必须真实执行 |
| REL-03 | Apple Silicon 与 Intel 两个架构均完成 Developer ID 签名、公证、staple、Gatekeeper、Helper 权限和符号链接校验。 | `Testing/MacReleaseBranchLifecycle.md` 用例 4；`Testing/MacReleaseAssetMatrix.md` 用例 3 | 受保护 staging workflow；真实 Apple 服务和最终字节只能人工/发布运行验收 |
| REL-04 | manifest 恰好为当前资产集合；名称唯一且无路径；appcast 架构、URL、长度和签名正确；公开资产不含私有源码、XCFramework、dSYM、日志、凭据或本机路径。 | `Testing/MacReleaseAssetMatrix.md` 用例 1、2、6 | `prepare-public-release-assets.sh`、`verify-staged-release-assets.sh`、`verify-release-contents.py`、`test-private-platform.py ReleaseContentTests`；最终签名资产需读回复验 |
| REL-05 | CDN 合约与仓库发布契约一致；版本首次占用检查只接受 HTTP 404；2xx/3xx、认证、5xx、超时和未知响应均阻断。 | `Testing/MacReleaseAssetMatrix.md` 用例 8“发布前资产契约” | `verify-preview-cdn-availability.sh`、`release-assets.py`、发布控制面 fixture；真实域名和 Worker 需发布前探测 |
| REL-06 | 真实稳定版能通过 Sparkle UI 发现、下载、安装候选，首次启动、退出和二次启动成功；版本、Build、Team ID、公证、helper 权限和链接正确，无新增崩溃。 | `Testing/AboutUpdateCenter.md` 用例 6；`Testing/MacReleaseBranchLifecycle.md` 用例 5 | 只能真实 UI 和真实签名资产验收；CLI `--probe`、单元测试或静态解压不能替代 |
| REL-07 | Preview publication 只公开完整且逐字节匹配的资产；失败保留或收回 Draft；公开后 GitHub、CDN、两架构通道和 stable latest 均正确。 | `Testing/MacReleaseAssetMatrix.md` 用例 4、5；`Testing/MacReleaseBranchLifecycle.md` 用例 6 | `publish-preview-release.sh`、`test-private-platform.py PublicationFlowTests`；真实 GitHub/CDN 字节需发布运行验证 |
| REL-08 | Stable promotion 只把既有 Pre-release 改为正式版，不重建、不重签、不换资产；来源满足当前或历史 provenance schema。 | `Testing/MacReleaseBranchLifecycle.md` 用例 7；`Testing/MacReleaseSLO.md` 用例 2 | `promote-preview-release.sh`；晋升前后资产摘要和 `releases/latest` 必须人工/发布运行核对 |
| REL-09 | Preview 和 Stable 后四个固定 feed URL 正确；Preview 不改变 stable XML；同步失败时父工作流失败且不覆盖资产。 | `Testing/MacReleaseAssetMatrix.md` 用例 9；`Testing/CloudflareDownloadCDN.md` 用例 2 | `sync-update-feeds.mjs`、`test-update-feed-sync.mjs`；真实跨仓 dispatch 和线上 URL 需人工验收 |
| REL-10 | Install PKG 全新安装默认组件正确；Siri Remote 组件按收据选择；App 更新携带的 Apple Remote helper 静默升级、取消/重启和旧 Helper 兼容正确；升级、旧 App 迁移、同名保护和较新 Build 保护正确；升级后 TCC 权限身份连续；错误架构被拒绝。 | `Testing/MacInstallerUninstaller.md` 安装用例 1–3 与“2026-10-08 Siri 可选组件检测回归”；`Testing/MacPreviewPermissionContinuity.md` 用例一、一 A、二、三；`Testing/AppleRemoteHelperUpgrade.am.md` A 用户预期；`Testing/IntelVenturaCompatibility.md` | `test-installer-architecture-guard.sh`、`test-legacy-app-trash-migration.sh`；真实 Installer、管理员授权、Gatekeeper、helper 替换和升级后权限必须人工 |
| REL-11 | 卸载把 App、`MiRemoteV 2ch`、HCI helper、LaunchDaemon 和状态目录可恢复地移入废纸篓；清除 Siri Remote 收据并只移除 SayAll Dock 固定项；未知同名内容、碰撞、只读失败和 `--restore` 正确；设置、日志和用户数据保留。 | `Testing/MacInstallerUninstaller.md` 卸载用例 4–10 | `test-installer-architecture-guard.sh`、`test-uninstaller-cleanup.sh`、`BuildSigningTests.uninstallerCleanupFixturePasses`；真实废纸篓、`pkgutil`、Dock、LaunchDaemon 和 CoreAudio 刷新必须人工 |
| REL-12 | 安装器许可页中英文正文、日期与官网逐字一致；拒绝、同意、覆盖升级和命令行安装边界正确；政策漂移阻断发布。 | `Testing/InstallerPrivacyConsent.md` 用例 1–8 | `verify-installer-privacy-policy.py`、远程 `policy.json` 校验；真实 Installer GUI 必须人工 |
| UPD-01 | 版本中心、预发布开关、stable/preview 选更高版本、红点已读、更新说明本地化、请求预算和手动检查正确；预览候选不会在启动或定时刷新时弹出。 | `Testing/AboutUpdateCenter.md` 用例 2–5 及“更新检查请求预算” | `UpdateInformationTests`、`UpdateCheckCoordinatorTests`；真实设置页和网络状态需人工 |
| UPD-02 | 新硬件公告、过期/404/超时、受信 HTTPS 和默认浏览器打开正确；失败不阻塞设置页。 | `Testing/AboutUpdateCenter.md` 用例 7 | `HardwareAnnouncementTests`；真实公告源和默认浏览器需人工 |
| LOG-01 | 有公钥时创建独立加密 `.rmlog` 会话，权限、顺序、轮转和保留正确；公钥缺失时回退脱敏普通日志；普通日志不包含用户内容、路径、设备身份或凭据。 | `Testing/RuntimeLogging.md` 用例 1–4、6 | `AppLoggerTests`、`DiagnosticLogUploaderTests`；真实日志目录、解密回放和跨重启必须人工 |
| LOG-02 | 受控 Sentry 只接收白名单公开事件和类型化私有事件；失败/拒绝不标记成功；公开构建不初始化私有传输；生产公钥和私钥边界正确。 | `Testing/EncryptedDiagnosticLogs.md` 用例 A–H；`Testing/RuntimeLogging.md` 用例 5、7 | `DiagnosticLogUploaderTests`、`PublicDiagnosticEventStoreTests`；真实 Sentry 测试项目和私有 Package 必须人工 |

## B. 首次使用

| ID | 必须通过的用户结果 | 唯一权威步骤 | 自动化证据 / 人工边界 |
| --- | --- | --- | --- |
| ONB-01 | 首次进入不可跳过；退出后从正确步骤续接；完成后进入设置；关于页可重跑；旧用户升级不重复进入；重跑不覆盖正式配置。 | `Testing/FirstRunOnboarding.md` 用例 0、1；`Testing/FirstUseSuccess.md` 用例 3 | `OnboardingFlowTests` 的导航/门禁/迁移用例；真实首次启动、Sparkle 升级和偏好迁移需人工 |
| ONB-02 | 控制来源只显示当前包实际支持的入口；蓝牙、输入监控、辅助功能真实状态正确；实体遥控器、iPhone、Watch 或网页版按所选路径完成真实连接和普通按键。 | `Testing/FirstRunOnboarding.md` 用例 2B–4C | `OnboardingFlowTests` 的来源可见性/门禁；真实 TCC、BLE、第三方 HID 和 Installer 收据必须人工 |
| ONB-03 | 音频回环设备可用；真实语音测试产生首个 PCM、松键尾音排空、目标工具真实文字上屏；三个普通按键完成；不可手动输入冒充语音。 | `Testing/FirstRunOnboarding.md` 用例 5–7；`Testing/HardwareVoiceAudioContract.md` | `OnboardingFlowTests` 的音频/文字策略；真实权限、音频、遥控器和豆包/微信/Typeless/Vokie 必须人工 |
| ONB-04 | Onboarding `1020 × 772` 下中英文、浅色/深色页面、标题、导航、状态卡、右栏、底部按钮无裁切；中文最终字号不小于 12pt；生产截图清单与实际页面一致。 | `Testing/FirstRunOnboarding.md` 用例 8、9 及生产页面与场景清单 | `OnboardingScreenshotRenderer`、`LocalizationTests`、`verify-localizations.sh`；截图只证明静态 UI |

## C. 语音、音频与实体硬件

| ID | 必须通过的用户结果 | 唯一权威步骤 | 自动化证据 / 人工边界 |
| --- | --- | --- | --- |
| VOICE-01 | RC003 普通语音无需前置 `MIC_OPEN` 即完成 `STREAM_START → AUDIO → STREAM_STOP`；首字低延迟、松键尾字完整、正常路径不 flush。 | `Testing/VoiceKeyModes.md` 用例 2B；`Testing/HardwareVoiceAudioContract.md` | `ATVVProtocolTests`、`ATVVAudioDiagnosticsTests`、`HardwareSimulationIntegrationTests`（模拟环境，私有包门控）；真实 RC003 和第三方文字上屏必须人工 |
| VOICE-02 | 极速按下/释放、快速连续多句、第二段在上一段排空期间开始，均首字不丢、旧 generation 不串入、下一次按键不需第二次成功。 | `Testing/VoiceKeyModes.md` 用例 2A；`Testing/VoiceDrainInterruptionRecovery.md` 用例 5；`Testing/HardwareVoiceAudioContract.md` | `VoiceFunctionKeyLatchTests`、`VoiceKeyModeTests`、`CoreVoiceInputJourneyTests`；真实按键到首字耗时必须人工 |
| VOICE-03 | 默认 Fn、Fn 点按、左右 Command、左右 Option 五种模式侧别正确、成对释放、切换后不残留修饰键；Typeless Fn 点按在排空后发送配对 tap。 | `Testing/VoiceKeyModes.md` 用例 1、3、4、7 | `VoiceKeyModeTests`、`VoiceFnTapSessionControllerTests`、`PreferredInputSourceMonitorTests`；真实第三方 App 和 TCC 必须人工 |
| VOICE-04 | RC001/RC003、Siri Remote、Chromecast、iPhone、Watch、Web 多来源共享语音键时 owner 正确、互不取消；移动端停止中重启不返回 `voice_busy`；目标变化停止旧目标。 | `Testing/VoiceKeyModes.md` 用例 5、6；`Testing/AppleWatchDirectRemote.md` 用例四；`Testing/CloudPhoneRemote.md` 语音与稳定回归 | `VoiceFunctionKeyLatchTests`、`MobileVoiceLifecycleTests`、`WatchBluetoothVoiceJourneyTests`、`ChromecastIntegrationTests`；真实多硬件并存必须人工 |
| VOICE-05 | 打开或聚焦目标 App 后第一次语音就进入正确输入框；等待期缓存、提前松开、取消、超时、敏感字段阻断正确；不能第二次或第三次才成功。 | `Testing/VoiceInputDestinationReadiness.md` 用例 1–9 | `VoiceInputDestinationCoordinatorTests`、`CoreVoiceInputJourneyTests`、`FirstVoiceReflectionJourneyTests`；真实 AX、第三方 App 和文字上屏必须人工 |
| VOICE-06 | Mac 麦克风待命、按住、点按三个入口正确；设备只列当前可用物理输入；默认输入策略、AirPods/HFP 长准备、无 PCM 超时、设备断开和恢复正确；与遥控器语音互斥。 | `Testing/MacMicrophoneInput.md`；`feature/mac-microphone-input/PRODUCT_SPEC.md` | `MacMicrophoneInputTests`；真实权限、AirPods、第三方工具和互斥必须人工 |
| VOICE-07 | Siri Remote 识别/配对、实体键、语音、触摸光标/滚动/确认、App 切换器和断连恢复正确；语音路径不增加长按阈值，触摸在语音和尾音期间不误发。 | `Testing/AppleRemoteHardwareInterface.md` 用例一–七；`Testing/HardwareCompatibilityContract.md` C 节 | 私有 Siri Remote 组件测试与公开适配测试；A2854/A2540 真机、HCI helper 和最终文字必须人工 |
| VOICE-08 | Chromecast 连接/重连、toggle/hold、首字、尾字、断连、快速点按、8 kHz 拒绝和普通按键映射正确。 | `Testing/ChromecastHardwareInterface.md` 用例 1–11 | `ChromecastIntegrationTests`、`ChromecastCapabilityContractTests`；正品固件和真实 ATVV 流必须人工 |
| VOICE-09 | 尾音排空期间切换音频输出、断连、睡眠、手机语音介入或切换目标 App 后，正常尾音不丢，下一次语音无需第二次成功，旧 generation 不串入。 | `Testing/VoiceDrainInterruptionRecovery.md` 用例 1–7 | `VirtualAudioConnectionLifecycleTests`、`VoiceFnTapSessionControllerTests`；真实拔插、睡眠、手机介入和第三方文字必须人工 |
| VOICE-10 | RC003 接近 60 秒长会话：53 秒黄色提醒、57 秒红色提醒、固件自然结束边界正确；长尾字完整，提醒不被当作续流或成功证明。 | `Testing/ExtendedVoiceRecording.md` 用例一、二、五；`Testing/StatusBarConnectionAppearance.md` 用例 4 | `StatusItemPresentationTests` 只覆盖阈值；真实 RC003 长会话、提示音和尾字必须人工 |
| VOICE-11 | Karabiner 或其他第三方 HID 工具占用语音键时，诊断、权限提示、恢复路径和正常语音路径正确；不把其他 HID 故障误报为 App 失败。 | `Testing/KarabinerVoiceKeyCompatibility.md` 用例 1–4 | `HIDPrearmSessionTests`、`HIDPermissionPollTests`、`VoiceKeyModeTests`；真实 Karabiner、系统 HID 和其他工具必须人工 |
| AUDIO-01 | 新安装虚拟麦克风名称正确、无重复驱动；设备就绪、测试音、用户音量 0–1000% 和静音自愈正确；用户音量不改写设备属性。 | `Testing/VirtualMicrophoneNaming.md`；`Testing/VirtualAudioAudibilityRecovery.md` 用例一–六 | `VirtualAudioConnectionLifecycleTests`、`DriverNamingTests`、`TestToneTests`、`scripts/test-driver-naming.sh`；真实 HAL 和第三方文字必须人工 |
| AUDIO-02 | 最后一只遥控器断开后释放虚拟音频；系统默认输入按规则回退/恢复且尊重用户手动选择；重连后不绑定旧设备。 | `Testing/BluetoothDisconnectAudioRelease.md` 用例 1–8 | `VirtualAudioConnectionLifecycleTests`、`AudioSelectionRecoveryTests`、`BluetoothLifecycleTests`；真实 CoreAudio 和会议 App 必须人工 |
| AUDIO-03 | 屏幕休眠、自动休眠、10 分钟空闲和多账户切回后正确释放与恢复；休眠不截断正在进行的语音；恢复后第一次语音可用。 | `Testing/MacIdleSleepAudioRelease.md` 用例一–八 | `VirtualAudioConnectionLifecycleTests`、`BluetoothLifecycleTests`、`NearbyRemoteLifecycleTests`；`pmset`、真实睡眠和双账户必须人工 |
| AUDIO-04 | 音频配置变化去抖正确；空闲不自造重绑风暴；活跃语音、待播尾包和真实硬件变化恢复正确；失败按有界退避；启动选择丢失可恢复。 | `Testing/AudioConfigurationChangeRecovery.md` AC-01～AC-06；`Testing/MiRemoteVAudioStaleRecovery.md` 用例 1A–3 | `AudioConfigurationChangeRecoveryTests`、`AudioSelectionRecoveryTests`、`VirtualAudioConnectionLifecycleTests`；真实拔插、睡眠和 HAL 卡死必须人工 |
| HID-01 | 新配对、系统已连接采纳、扫描超时/退避/缓存探测、睡眠唤醒和多设备隔离正确；已连接设备卡显示真实型号、名称和电量，不伪报未知值；连接页未连接/查找文案跟随所选型号；未 Ready 外设不生成幽灵档案。 | `Testing/ConnectedRemoteCards.md` 用例 1–4；`Testing/ConnectionStatus.md`；`Testing/GhostRemoteProfileGate.md`；`Testing/BluetoothDisconnectAudioRelease.md` 用例 9、10；`Testing/BluetoothDeviceNames.md` | `BluetoothLifecycleTests`、`NearbyRemoteLifecycleTests`、`RemoteDeviceNamePolicyTests`、`VoiceRemoteCatalogTests`；真实射频、名称、电量和幽灵档案必须人工 |
| HID-02 | 全部物理键单击、双击、长按、按住连发、连续快速按、编辑捕获和多设备路由正确；左右键四种按住模式可用，其他键只显示适用模式；基础映射和方案内动作变化后均清除依赖的旧按住设置。 | `Testing/UnifiedButtonConfiguration.md` 场景与手势、2026-11-12 按住行为、2026-11-15 方案快捷键/focus 可编辑；`Testing/RapidRepeatedButtonPresses.md` 用例一–七 | `RemoteButtonGestureRecognizerTests`、`RemoteButtonInteractionTests`、`HoldExecutionTests`、`GestureLearningPersistenceTests`；真实遥控器和目标 App 必须人工 |
| HID-03 | App 切换器启动、前进、后退、确认、取消、超时、断连和权限撤销正确；Command 不残留。 | `Testing/AppSwitcherRemoteControl.md` 用例 1–14 | `RemoteButtonsTests`、`HardwareSimulationIntegrationTests`（模拟环境，私有包门控）；真实 WindowServer 和系统切换器必须人工 |
| HID-04 | 遥控器滚动和翻页方向、步长、区域定位、自然滚动、按住连发、指针不在区域和窗口/显示器布局正确；松键立即停止。 | `Testing/RemoteScrollActions.md` 用例一–七；`Testing/ScrollAreaPageActions.md` 用例 1–8 | `RemoteButtonsTests`、`ScrollRegionTests`；第三方 Electron/原生 App 和真实滚轮投递必须人工 |
| HID-05 | 自定义快捷键预设、标准键盘录入、左右修饰键、实体键盘捕获、实际投递、Fn 伪标志和事件过滤器禁用后的状态复位正确。 | `Testing/KeyboardShortcutPicker.md` 用例 0–5；`Testing/CustomShortcutLifecycle.md` | `ShortcutCaptureMonitorTests`、`ShortcutLifecycleTests`、`MacroShortcutDeliveryTests`；真实系统热键和第三方 App 必须人工 |
| HID-06 | 打开 App、聚焦输入框、恢复光标、Electron/原生 AX 树、SayAll 自身前台跳过、目标 App 退出和敏感字段阻断正确。 | `Testing/CustomApplicationFocus.md` 用例 0–4A | `ComposerFocusRequestTests`、`CustomApplicationProfileLifecycleTests`、`RemoteButtonsTests`；真实 AX 和第三方 App 必须人工 |
| HID-07 | 遥控器方向键按住、松开、断连和丢失 release 后，实体键盘方向键抑制与自愈正确；音量键按住、返回键和自定义快捷键不退化。 | `Testing/PhysicalArrowKeySuppression.md` 用例一–五 | `KeyboardEventSuppressorTests`、`RemoteNativeKeyMapperTests`、`RemoteButtonsTests`；真实遥控器、实体键盘和断连必须人工 |

## D. 设置、菜单栏与界面

| ID | 必须通过的用户结果 | 唯一权威步骤 | 自动化证据 / 人工边界 |
| --- | --- | --- | --- |
| UI-01 | 设置窗口默认/最小尺寸正确；全部侧边栏入口、页头、主要控件和纵向滚动在真实最小窗口无裁切；中英文、浅色/深色、增强对比度和降低透明度可读；中文最终字号不小于 12pt。 | `Testing/UnifiedButtonConfiguration.md` 2026-11-02 窗口尺寸与页头；`design-qa.md` | `SettingsPageRegressionTests`、`SettingsScreenshotRenderer`、`verify-localizations.sh`；真实窗口点击、鼠标和 VoiceOver 必须人工 |
| UI-02 | 菜单栏图标五态、左右键菜单、首项“打开主界面…”、重连/日志/语言/更新/退出、电量行和关闭菜单行为正确。 | `Testing/MenuBarVisibility.md` 用例 1–6；`Testing/StatusBarConnectionAppearance.md` 用例 1–5 | `StatusItemPresentationTests`、`SettingsPageRegressionTests`；真实 NSStatusBar、VoiceOver 和电量必须人工 |
| UI-03 | `⌘1`–`⌘9` 只切换可见页签；`⌘F` 只聚焦当前页搜索框；录入快捷键时不被菜单抢走；保存方案 Sheet 的 Escape/Return 正确。 | `Testing/SidebarShortcut.md` 用例 1–5；`Testing/SearchFieldShortcut.md` 用例 1–3 | `SettingsNavigationShortcutTests`、`SearchFocusTests`；真实键盘事件和私有页面必须人工 |
| UI-04 | 设置窗口可移动/缩放/全屏；关闭窗口不改变蓝牙、音频或映射；Dock 图标、关窗重开、菜单栏入口在关闭后仍可恢复主界面。 | `Testing/SettingsWindowFocus.md` 用例 1–3；`Testing/MenuBarVisibility.md` 用例 1–3 | `SettingsPageRegressionTests`；真实 Dock、Finder 遮挡、最小化和 Command-W 必须人工 |
| UI-05 | 共享提示条/气泡的放置、层级、对比度、自动消失、操作按钮和 VoiceOver 正确；不遮挡必需操作，不使用连续浮层。 | `design-qa.md`；`Tests/RemoteMicTests/NoticeCenterTests.swift`、`NoticePaletteTests.swift` | `NoticeCenterTests`、`NoticePaletteTests`；当前无专项 Testing 手册，真实窗口和 VoiceOver 仍须人工验收 |
| UI-06 | App 图标选择、经典鸭/几何鸭切换、运行时圆角 Logo、资源缺失回退，以及 Dock、Finder、Command-Tab、窗口缩略图和确认弹窗外观正确。 | `Testing/AboutUpdateCenter.md` 用例 1A、1B | `AppIconControllerTests`、`ApplicationIconResolverTests`、`SettingsPageRegressionTests`；真实 Dock/Finder/Command-Tab 缓存、Intel 和重启必须人工 |
| UI-07 | Dock 图标显隐在关窗后生效；系统音量摘要、上一首/下一首、标准窗口菜单和语言切换后的菜单文案正确。 | `Testing/DockMediaWindowRegression.md` 用例一–四 | `RemoteButtonsTests`、`SettingsPageRegressionTests`；真实 Dock、系统媒体状态、窗口菜单和系统语言必须人工 |
| UI-08 | 设置窗口只从顶部专用区域拖动；全部页面可纵向滚动且不显示滚动条；输出音量滑块轨道、点击和拖动正确；Onboarding 复用同一控件与数值。 | `Testing/WindowDragAndGainSlider.md` 用例 1–3 | `SettingsPageRegressionTests`、`VirtualAudioConnectionLifecycleTests`；真实鼠标命中、窗口移动和音频增益必须人工 |
| UI-09 | 共享权限轮询在只启用 HID、再启用 Siri、撤销输入监控、撤销辅助功能、停止全部适配器、快速重启和睡眠唤醒时正确；迟到回调不改变新代次。 | `Testing/RuntimePermissionPolling.md` | `PermissionStatusProbeTests`、`HIDPermissionPollTests`、`HIDPermissionRevocationTests`；真实 TCC、Siri Remote 和睡眠唤醒必须人工 |

## E. 配置、数据与本地集成

| ID | 必须通过的用户结果 | 唯一权威步骤 | 自动化证据 / 人工边界 |
| --- | --- | --- | --- |
| DATA-01 | 完整配置备份包含本格式支持的全部设备、方案、嵌套动作、App 规则、未引用对象、音频/语音键/回眸偏好和可迁移私有组件对象；取消、替换、重启恢复和失败回滚正确；账号、凭据、配对和历史不导出；常用语使用专用备份。 | `Testing/CompleteConfigurationBackup.md` 准备、完整往返、不兼容与失败路径 | `CompleteConfigurationBackupTests`、`PortableConfigurationCompatibilityTests`；真实系统文件面板、旧配置升级和跨 Mac 必须人工 |
| DATA-02 | 外部个人配置逐条校验；目标 Mac 缺 App 保留绑定；篡改路径、冒名 Bundle、越界键码只丢该项；旧版缺字段仍可导入；录音中危险语音键变更被阻止。 | `Testing/ConfigurationImportValidation.md` 用例 1–6；`Testing/VoiceKeyModes.md` 用例 1 第 10 步 | `ConfigurationImportValidationTests`；真实旧文件和跨 Mac 必须人工 |
| DATA-03 | 对象级分享/导入导出和 Finder 双击分流正确；完整备份、`sayall-transfer` 的 `personalBackup`、社区键位方案进入正确页面；只有 `formatVersion` 的旧文件按实际识别结果记录，不假定成功；预览取消不写入，重复打开请求不丢失。 | `Testing/PortableConfigurationTransfer.html`；`Testing/CompleteConfigurationBackup.md` 双击分流 | `PortableConfigurationCompatibilityTests`、`ButtonProfileFileOpeningTests`；真实 Finder、旧 personalBackup 格式和私有组件必须人工 |
| DATA-04 | 旧遥控器型号值解码不告警；设备、选中项和映射保留；损坏 JSON 保留 `.corrupt` 并显示可读告警；告警不遮住健康配置。 | `Testing/RemoteProfileUpgrade.md` 准备与操作；`Testing/CompleteConfigurationBackup.md` 不兼容与失败路径 | `SettingsCorruptionRecoveryTests`、`VoiceRemoteCatalogTests`；真实旧配置和重启必须人工 |
| DATA-05 | 回眸默认关闭；只保存本次新增文字；RC003、Nearby iOS、Web 来源正确；快速发送、连续语音、焦点切换、敏感字段、日期/时区和删除恢复正确。 | `Testing/LocalTranscriptHistory.md` 用例 1–9 | `TranscriptCaptureCoordinatorTests`、`TranscriptArchiveStoreTests`；真实 AX、第三方输入法和硬件必须人工 |
| DATA-06 | 原始录音默认关闭且与文字开关独立；仅录音、文字加录音、无输入框回退、播放/暂停/停止/导出/删除、损坏文件和磁盘失败正确。 | `Testing/LocalRecordingAssets.md` 核心用例 | `RecordingAssetStoreTests`；真实音频、磁盘和废纸篓必须人工 |
| DATA-07 | 本地 Agent 默认关闭；授权、令牌哈希、四客户端配置、查询分页/时间/App 过滤、撤销、总开关、损坏/符号链接、`v1` 兼容和 stdout 协议纯净正确。 | `Testing/SayAllMCPIntegration.md` 用例 1–9；`Testing/WorkBuddyConnector.md` | `SayAllMCPAuthorizationStoreTests`、`SayAllMCPHistoryStoreTests`、`MCPClientIntegrationServiceTests`；真实四客户端和 stdio 必须人工 |
| DATA-08 | 登录时自动启动默认关闭；系统要求批准、注销/登录、更新后仍有效；单实例/多版本互斥和 Sparkle 交接正确。 | `Testing/LoginAtLogin.md` 用例 1–5 | `LoginItemServiceTests`、`ApplicationInstanceGuardTests`；真实登录项和 Finder/`open -n` 必须人工 |
| DATA-09 | 个人中心统计的今日/本周/全部、语音次数/时长、上海时区跨午夜拆分、旧累计值兼容、异常中断计数和布局正确。 | `Testing/ProfileStatistics.md` 统计数据与兼容性、个人中心布局 | `LocalUsageLedgerTests`、`SettingsPageRegressionTests` 的统计页用例；真实长期使用历史和极端数据必须人工 |

## F. 会员与私有功能

| ID | 必须通过的用户结果 | 唯一权威步骤 | 自动化证据 / 人工边界 |
| --- | --- | --- | --- |
| MEM-01 | 无私有组件的公开构建可编译、启动和完成稳定功能；不显示私有页面/入口/资格申请；不创建会员会话；显式私有路径缺失时构建失败而非静默回退。 | `Testing/PrivateFeatureHostBoundary.md` 用例 A、B、D | `SettingsPageRegressionTests` 的公开回退、`scripts/build-app.sh`、`scripts/verify-app.sh`；真实公开包启动必须人工 |
| MEM-02 | 会员账号、验证码登录、刷新、退出、Free/Plus、离线租约和撤销补偿正确；侧栏账号名按当前私有适配器返回值显示，截断规则见下方已知缺口；日志不含邮箱、验证码、Token、安装标识或服务响应正文。 | `Testing/MembershipAndButtonProfiles.md` 用例二–四；`Testing/CompanionMembership.md` | `MembershipSupportCodeTests`、`SettingsPageRegressionTests` 的会员接线；真实登录、支付、退款和租约必须人工 |
| MEM-03 | Plus 键位方案创建/复制/保存/重启/删除；Free 只读，页头按默认/已选方案显示“开通会员”及对应说明；权益撤销回退；实体 HID、Nearby iPhone/Watch、Web Remote 三入口一致。 | `Testing/MembershipAndButtonProfiles.md` 用例五、五 B、六；`Testing/UnifiedButtonConfiguration.md` 方案作用域 | `ButtonProfileScopeIntegrationTests`、`ButtonProfileBindingTextTests`、`SettingsPageRegressionTests`；真实会员和实体设备必须人工 |
| MEM-04 | 手机、手表、小程序和 Web 的会员门禁、环境切换、退出、过期租约、Web 二次授权和权益开通后自动重试正确；Onboarding 使用同一会员入口。 | `Testing/CompanionMembership.md` 用例 1–7；`Testing/CloudPhoneRemote.md` 连接与权益 | 公开宿主门禁与状态测试；真实会员服务、iPhone/Watch/Web 和支付必须人工 |
| MEM-05 | 常用语非会员只读/示例；会员五键分配、面板插入、剪贴板恢复、密码/无输入框拒绝、多来源隔离、编辑/排序/导入导出和失败恢复正确。 | `Testing/CommonPhrases.md` 核心流程、剪贴板、用户内容、来源矩阵 | 私有 `CommonPhraseTests`；公开宿主只验证适配边界，真实遥控器和第三方文本框必须人工 |
| MEM-06 | 免费组合动作公开回退、免邀请码、快捷指令、打开网址、嵌套/8 层、绑定提示、按键捕获模式、覆盖升级和旧包失败保护正确。 | `Testing/QuickCommandsPrivateIntegration.md` 用例一–七 | 私有宏包测试与公开宿主接线；真实遥控器、手机/Web 和快捷指令必须人工 |
| MEM-07 | Siri Remote 可选 PKG 安装、Helper/LaunchDaemon、键位集合、组合动作绑定和型号隔离正确；Free 的 Siri 语音被会员门禁阻止，Plus 可用。 | `Testing/MacInstallerUninstaller.md` 安装用例 2；`Testing/MembershipAndButtonProfiles.md` 用例八；`Testing/SiriRemoteMacroButtonProfilesLocalPackage.md` | PKG 静态检查和私有组件测试；真实安装、会员和 A2854 必须人工 |
| MEM-08 | 使用包含自动保存接口的当前固定构件时，非默认键位方案内的快捷键/focus 引用可编辑；动作摘要区分“默认、本方案、未设置、无动作”；单击或长按动作变化后清除依赖的旧按住设置，失败可重试，重启后保持。 | `Testing/UnifiedButtonConfiguration.md` 2026-11-15 方案快捷键/focus 可编辑；`Testing/MembershipAndButtonProfiles.md` 用例五、五 B | `ButtonBindingConfigurationTests`、`RemoteButtonInteractionTests`、`SettingsPageRegressionTests`；真实会员、旧安装包和实体遥控器动作必须人工 |
| MEM-09 | Supplemental 私有设置页的注册、顶部内容、导航、滚动和公开构建隐藏正确；缺失 Provider 时不显示空页或崩溃；手册当前只定义顶部区域，其余按实际注册页验收。 | `Testing/SupplementalSettingsPages.md` | `SupplementalSettingsIntegrationTests`；真实私有 Provider、真实窗口和 VoiceOver 必须人工 |
| MEM-10 | iPhone 二维码按需生成/失效、Bonjour/P2P 自动兜底、等待取消、Watch 零行为变化和 Web 邀请隔离正确；移动端连接后第一次按键/语音成功。 | `Testing/iPhoneQRDirectConnection.md` 用例一–五；`Testing/NearbyMobileWaitingCancellation.md` 用例一–八；`Testing/CloudPhoneRemote.md` 连接与权益 | `NearbyRemoteLifecycleTests`、`MobileVoiceLifecycleTests`、`WatchBluetoothVoiceJourneyTests`；真实 iPhone/Watch/Web 和局域网必须人工 |

## G. 分享与反馈

| ID | 必须通过的用户结果 | 唯一权威步骤 | 自动化证据 / 人工边界 |
| --- | --- | --- | --- |
| SHARE-01 | 个人中心分享标题、二维码、完整链接、复制链接、展开/收起、KPI 不变；设置页和侧边栏无重复入口；问题反馈从设置页打开默认浏览器且不要求额外权限。 | `Testing/MacAppSharing.md` 用例一–五；`Testing/IssueFeedbackLink.md` 用例一–三 | `AppSharingTests`、`FeedbackLinkTests`；真实扫码、剪贴板、默认浏览器和线上反馈必须人工 |

## 自动化执行顺序

1. 确认精确源码 SHA，并取得该 SHA 的成功 macOS CI。发布脚本必须用 `scripts/verify-release-ready-main-ci.sh <SHA> main`（Hotfix 使用对应分支）核对；不得只看最新 Run。
2. 按发布模式执行受保护 staging：`scripts/stage-macos-preview.sh preview`。自动化负责双架构签名、公证、staple、资产和内容检查；REL-03 至 REL-05 的失败在进入公开身份前阻断。
3. 执行 REL-06 真实 Sparkle UI 验收并生成 attestation。未完成时不得进入 publication。
4. 执行 publication 和 REL-07、REL-09；然后按用户指定执行 Stable promotion 和 REL-08。
5. 安装、升级、卸载、许可页、真实硬件、第三方工具、真实会员和真实窗口用例按上表人工执行。自动化结果、截图、代理实测和真机结果分别记录，不能互相替代。

## 用例所有权与去重规则

- 语音键模式、Fn 点按、多来源 owner、HID 中和/晚到恢复：`VoiceKeyModes.md`。
- 尾音排空被打断：`VoiceDrainInterruptionRecovery.md`；正常尾字门槛由 `HardwareVoiceAudioContract.md` 定义；60 秒长会话：`ExtendedVoiceRecording.md` 和 `StatusBarConnectionAppearance.md` 用例 4。
- 第三方 HID/键盘工具占用语音键：`KarabinerVoiceKeyCompatibility.md`。
- 目标 App 就绪：`VoiceInputDestinationReadiness.md`；Mac 麦克风：`MacMicrophoneInput.md`。
- 虚拟声卡静音/音量：`VirtualAudioAudibilityRecovery.md`；断连释放：`BluetoothDisconnectAudioRelease.md`；休眠/空闲：`MacIdleSleepAudioRelease.md`；引擎配置变化：`AudioConfigurationChangeRecovery.md`；启动选择恢复：`MiRemoteVAudioStaleRecovery.md`。
- 苹果遥控器：`AppleRemoteHardwareInterface.md`；Chromecast：`ChromecastHardwareInterface.md`。两者共同遵守 `HardwareCompatibilityContract.md` 和 `HardwareVoiceAudioContract.md`。连接页状态：`ConnectionStatus.md`；幽灵档案：`GhostRemoteProfileGate.md`；实体键盘抑制：`PhysicalArrowKeySuppression.md`。
- 按键、手势、按住、方案作用域：`UnifiedButtonConfiguration.md`；连续快按：`RapidRepeatedButtonPresses.md`；快捷键选择：`KeyboardShortcutPicker.md`；快捷键投递：`CustomShortcutLifecycle.md`；App 切换器：`AppSwitcherRemoteControl.md`；滚动：`RemoteScrollActions.md`；翻页：`ScrollAreaPageActions.md`；聚焦：`CustomApplicationFocus.md`。
- 设置窗口、页头、侧栏、最小尺寸：`UnifiedButtonConfiguration.md` 2026-11-02 和 `design-qa.md`；窗口焦点/Dock：`SettingsWindowFocus.md`；窗口拖动/音量滑块：`WindowDragAndGainSlider.md`；Dock/系统媒体/窗口菜单：`DockMediaWindowRegression.md`；菜单栏：`MenuBarVisibility.md`；状态栏：`StatusBarConnectionAppearance.md`；App 图标/品牌：`AboutUpdateCenter.md` 用例 1A、1B；运行时权限轮询：`RuntimePermissionPolling.md`。
- Onboarding：`FirstRunOnboarding.md`；首次成功恢复：`FirstUseSuccess.md` 只保留失败恢复、安装和升级。
- 配置：完整备份 `CompleteConfigurationBackup.md`；逐条导入 `ConfigurationImportValidation.md`；对象包 `PortableConfigurationTransfer.html`；设备档案升级 `RemoteProfileUpgrade.md`。
- 回眸文字：`LocalTranscriptHistory.md`；原始录音：`LocalRecordingAssets.md`；个人中心统计：`ProfileStatistics.md`。
- 会员/付费方案：`MembershipAndButtonProfiles.md`；手机/手表/Web 会员门禁：`CompanionMembership.md`；iPhone 二维码/Watch/Web 连接生命周期：`iPhoneQRDirectConnection.md` 和 `NearbyMobileWaitingCancellation.md`；常用语：`CommonPhrases.md`；宏包：`QuickCommandsPrivateIntegration.md`；Siri 安装/键位：`SiriRemoteMacroButtonProfilesLocalPackage.md`；Supplemental 私有页：`SupplementalSettingsPages.md`。
- MCP/Agent：`SayAllMCPIntegration.md`；WorkBuddy 平台包：`WorkBuddyConnector.md`。
- 发布：`RELEASING.md`；资产：`MacReleaseAssetMatrix.md`；生命周期：`MacReleaseBranchLifecycle.md`；SLO：`MacReleaseSLO.md`；超时/并发：`MacSignedReleaseTimeout.md`；安装：`MacInstallerUninstaller.md`；Apple Remote helper 升级：`AppleRemoteHelperUpgrade.am.md`；升级后权限：`MacPreviewPermissionContinuity.md`；许可：`InstallerPrivacyConsent.md`；更新：`AboutUpdateCenter.md`；CDN：`CloudflareDownloadCDN.md`。
- 诊断：`RuntimeLogging.md`；受控 Sentry/私有事件：`EncryptedDiagnosticLogs.md`。

以下文件不进入本表，避免被误当成当前发布门槛：

- `RC003VoiceExtensionPreview.md`：已移除的实验入口。
- `ChromecastVoicePitfalls.md`：历史踩坑和根因记录，不定义验收。
- `AgentAutomation.md`：仓库 Agent/Workshop 自动化，不是 Mac App 用户发布用例。
- `SiriRemoteOptionalPKGE2EPlan.md`、`SiriRemoteCommunityBuild.md`：计划或构建边界。
- `OnboardingConfigSummaryScreenshots.md`：截图证据，不是独立流程。
- `LocalTestApp.md`：本地测试包构建入口，不是分发验收。
- `MacReleaseSLO.md` 的 30 分钟目标：报告指标，不取消任何正确性门禁；晋升资格仍按 REL-08 和该手册的 Stable 用例执行。

## 已知待决策与自动化缺口

以下项目不能在本表里用“通过”掩盖；发布前必须单独记录结论：

1. **账号名截断合同**：`MembershipAndButtonProfiles.md` 要求邮箱前缀最多 6 个字符，`ProfileStatistics.md` 要求完整前缀；公开宿主只显示私有适配器提供的 `accountDisplayName`。两本手册在私有适配器合同确认前不得互相作为失败证据。
2. **提示条无专项手册**：Notice 只有 `NoticeCenterTests`、`NoticePaletteTests` 和 `design-qa.md`，真实窗口/ VoiceOver 仍需人工。
3. **MCP stdio 无仓库内真实进程测试**：公开测试覆盖存储、授权、历史和配置生成；`tools/list`、`invalid_arguments`、stdout 纯净度必须用真实客户端验收。
4. **市场合同默认不跑**：`PortableConfigurationCompatibilityTests` 的市场 `.sayall` 用例需要 `SAYALL_MARKET_CONTRACT_PATH`；发布前必须显式设置。
5. **旧 personalBackup 双击路由未确认**：当前 `ConfigurationImportDestination.detect` 只识别完整备份和 `sayall-transfer`；如果旧文件只有 `formatVersion`，Finder 双击可能不进入设置页，必须实测。
6. **英文文案和画布静态检查未全部接入 CI**：`scripts/verify-english-copy.py` 和 `scripts/verify-mapping-canvas-chrome.py` 仍需在受影响发布中手工执行。

## 发布记录模板

```text
候选 Commit：
版本 / Build：
架构：
自动化 CI Run / 结论：
staging Run / attempt / artifact：
Sparkle UI attestation：
公开 Release / CDN / feed 验证：
REL-01 至 REL-12：
UPD / LOG：
ONB：
VOICE / AUDIO / HID：
UI：
DATA / MEM / SHARE：
未执行项与原因：
最终结论：可发布 / 阻断
```
