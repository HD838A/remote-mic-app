# 无线麦技术文档

[English](TECHNICAL.en.md)

本文面向开发、审计和发布人员，描述当前代码的实现、构建和发布约束。普通用户请阅读 [README.md](README.md)。

## 支持范围

- Apple Silicon 发行线：`arm64`、macOS 14 或更高版本；
- Intel 发行线：`x86_64`、macOS 13 或更高版本；
- 目标遥控器：小米蓝牙遥控器 2 Pro / RC003；
- HID 标识：Vendor ID `0x2717`、Product ID `0x32B8`；
- Swift tools version：6.2；发布机当前使用 Swift 6.3，源码以 Swift 5 语言模式编译；
- 发布签名：本地开发构建保持带固定 designated requirement 的 ad-hoc 签名。自 v1.3.0 起的正式发布使用 Developer ID Application 与 Developer ID Installer 签名；应用和驱动启用 Hardened Runtime 与可信时间戳，应用、两个 PKG 和 DMG 都经过 Apple 公证并 stapled。

两条发行线保持独立产物与更新源：Apple Silicon 使用默认文件名和 `appcast.xml`，Intel 使用带 `Intel` 的文件名和 `appcast-intel.xml`。构建与验证脚本分别固定目标架构和最低系统版本，不生成 Universal 包。

## 模块结构

| 模块 | 主要职责 |
| --- | --- |
| `RemoteMicApp.swift` | AppKit 生命周期、菜单栏图标、左键设置窗口、右键菜单、关于与版本菜单项、Sparkle 手动更新入口 |
| `SettingsView.swift` | 设置界面、状态展示、音频选择、按键映射和权限入口；macOS 26 使用 Liquid Glass，macOS 14/15 使用兼容样式 |
| `BridgeAppModel.swift` | 蓝牙、音频、HID、Fn 映射和 UI 状态的协调层 |
| `XiaomiBluetoothBridge.swift` | CoreBluetooth 扫描、连接、能力协商、语音会话和自动重连 |
| `ATVVProtocol.swift` | ATVV 命令、能力解析、IMA/DVI ADPCM 解码、帧累积与 PCM 后处理 |
| `AudioOutput.swift` | CoreAudio 输出设备枚举和 16 kHz 单声道语音写入 |
| `HIDRemoteMonitor.swift` | RC003 原始 HID 报告、独占/兼容模式、按键重复和活动状态 |
| `KeyboardEventSuppressor.swift` | 兼容模式下对同一遥控器原生系统事件的短时抑制 |
| `KeyboardInjector.swift` | 键盘、媒体键和预置应用启动动作 |
| `RemoteVoiceFunctionMapper.swift` | 只对 RC003 把语音键的 F5 usage 映射为 Fn/Globe，并在退出时恢复 |
| `AppSettings.swift` | 音频设备、增益、HID 开关、按键映射和外设标识持久化 |

## 国际化

应用支持简体中文和英文。语言选择保存在 AppSettings 中；LocalizationStore 不修改 AppleLanguages，而是直接发布新的 Locale。SwiftUI 使用环境 Locale 刷新静态文案，AppKit 菜单栏边界重建菜单和窗口标题；动态状态保存为资源键与参数，因此语言切换后无需重启即可重新渲染。

应用包同时包含 en.lproj 和 zh-Hans.lproj 的 Localizable.strings、InfoPlist.strings 与内置帮助。系统权限提示与 Sparkle 等第三方界面仍由 macOS 或第三方组件在下次显示时决定语言。

## 蓝牙与 ATVV

应用只接受以下任一条件命中的候选设备：

- 系统名称去除首尾空白后等于 `MI RC`、`Xiaomi Bluetooth Remote 2 Pro` 或“小米蓝牙语音遥控器”；英文名称比较不区分大小写；
- 广播中包含 ATVV service UUID。

应用不会对所有名称中带有“小米”的蓝牙设备做模糊匹配。连接成功后会保存 macOS 提供的外设 UUID，以便下次优先恢复；初始化或连接失败后清除失效缓存，并在 3 秒后重新扫描。用户主动重新连接时使用约 0.1 秒延迟。

ATVV 通道为：

| 用途 | UUID |
| --- | --- |
| Service | `AB5E0001-5A21-4F05-BC7D-AF01F617B664` |
| Transmit | `AB5E0002-5A21-4F05-BC7D-AF01F617B664` |
| Audio | `AB5E0003-5A21-4F05-BC7D-AF01F617B664` |
| Control | `AB5E0004-5A21-4F05-BC7D-AF01F617B664` |

连接后必须完成特征发现、Audio/Control 通知订阅和能力确认，才会进入 ready 状态。初始化超时为 8 秒。当前只接受 16 kHz 编码；设备若只提供或切换到 8 kHz，连接会失败关闭并重新发现。

语音数据按遥控器声明的帧长累积，使用高半字节优先的 IMA/DVI ADPCM 顺序解码。同步包可重置 predictor 和 step index。解码后的 PCM 经过三点平滑与 `-24...24 dB` 安全限幅增益处理；设置界面当前允许用户选择 `0...24 dB`。

## 音频输出

`VirtualAudioOutput` 使用 `AVAudioEngine` 和 `AVAudioPlayerNode`，内部格式固定为 16 kHz、单声道、Float32。应用枚举所有具有输出声道的 CoreAudio 设备，并把语音直接写入用户选择的设备，不修改系统默认输入或输出。

测试音同样只在内存中生成。只有音频设备已经配置、RC003 未在传输语音且没有其他测试音播放时才允许发送；真实语音开始或设备重新配置时会取消测试音，避免阻塞语音缓冲。

## 豆包兼容驱动

`scripts/build-doubao-driver.sh` 固定从 BlackHole `v0.7.1`、提交 `e2b22aaaba4e507a097131704bf96dabc004d9cf` 构建 `MiRemoteV2ch.driver`。项目补丁只把实际 Audio Device transport 报告为 USB，并使用独立的 bundle identifier、设备 UID 和 CFPlugIn factory UUID。

发布设备名为 `MiRemoteV 2ch`，UID 为 `MiRemoteV2ch_UID`。它与 `BlackHole2ch.driver` 并存，不覆盖或删除 BlackHole。

安装 PKG 的 payload 包含：

- `/Applications/SayAll.app`；
- `/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver`。

安装脚本校验架构、最低系统版本和签名，重启 CoreAudio，并为当前桌面用户启动应用。新 `SayAll.app` 验证通过后，Bundle ID 匹配的旧 `Remote Mic.app` / `无线麦.app` 会使用防冲突名称移入目标卷对应的 macOS 废纸篓；Trash 不可用或移动失败时旧 App 保持原样。卸载 PKG 只删除 `MiRemoteV2ch.driver` 并重启 CoreAudio，不删除应用或 BlackHole。

## HID 与按键映射

自定义按键映射默认关闭。启用后必须同时具备输入监控和辅助功能权限，否则 HID 处理失败关闭。

`HIDRemoteMonitor` 首先尝试独占打开 RC003。若 macOS 拒绝独占，则退回非独占监听，并由 `KeyboardEventSuppressor` 在收到 RC003 原始报告后的 180 毫秒窗口内抑制匹配的原生系统事件。由于系统 Power 事件可能在 Session Event Tap 之前触发睡眠，自定义映射启用时会先对 RC003 单独应用 `Keyboard Power → F20` 的设备级映射；映射失败时 HID 处理失败关闭。合成事件带有独立标记，不会被再次抑制。

默认映射为：

| 遥控器按键 | 默认动作 |
| --- | --- |
| 方向 / 确定 | 方向键 / Return |
| 返回 | Delete（退格） |
| 主页 | 显示桌面（Fn-F11） |
| 菜单 | macOS 上下文菜单键 |
| TV | Command-Tab |
| 电源 | Escape |
| 音量 + / - | 系统音量增减 |

用户还可以选择系统静音、播放/暂停，或打开 Codex、Claude、cmux、微信、Cursor、Xcode、Slack、企业微信、网易云音乐、Chrome、Safari 和 Zed。选择器只显示当前已安装的预置应用，但会保留后来被卸载的已有映射；应用启动动作不会重复创建实例。

方向、返回和音量键支持长按重复；打开应用动作不重复。普通实体按键活动状态会发布到 SwiftUI，用于高亮遥控器示意图和定位映射行。

## 语音键 Fn 映射

RC003 的语音键以键盘 F5（usage page `0x07`、usage `0x3E`）出现。`RemoteVoiceFunctionMapper` 只匹配 RC003 的 Vendor ID/Product ID；默认把该 usage 映射为 Apple vendor top-case Fn/Globe（usage page `0xFF`、usage `0x03`）。自定义按键映射启用时，同一组件还会把 RC003 的 Keyboard Power（usage `0x66`）映射为 F20（usage `0x6F`）。

默认关闭的 Typeless 兼容模式会先确认辅助功能权限，再以事务方式把所有匹配 RC003 服务的 F5 映射为 usage `0`；任一目标失败或目标不完整时立即回滚、关闭设置并恢复默认 Fn 映射。开启后，`VoiceFnTapSessionController` 在物理语音流开始时缓存 pre-roll，Fn 开始点按成功后再写入回环设备；松开时等待 `VirtualAudioOutput.endSessionAfterDraining` 排空队列，再发送配对的 Fn 结束点按。generation 和可取消任务隔离快速连续会话，并在开关关闭、断连、重连或 App 退出时完成或取消对应会话；开始点按失败时不会发送结束点按。

该兼容模式只转换目标应用看到的触发语义，RC003 仍然必须按住语音键才会采集音频，不提供持续录音或独立语音输入。设置导入导出包含可选的 `voiceFnTapModeEnabled`；旧配置缺少字段时按关闭处理。应用退出时恢复启动前对应 source usage 的映射，同时保留运行期间其他来源的映射变化。

## 菜单栏与窗口

应用以 `LSUIElement` accessory 模式运行，不显示 Dock 图标。状态栏按钮同时接收左右鼠标抬起事件：

- 普通模式左键创建或置前设置窗口；同时关闭 Dock 图标和启动时主窗口后，左键直接展开状态菜单；
- 右键始终显示连接、音频、按键状态，以及重新连接、打开设置、日志、关于、版本号、检查更新、GitHub 和退出菜单；
- “按键快捷映射”根据当前设置即时生成，支持启停映射、切换已连接遥控器和修改单击动作；动作按基础按键、系统与媒体、自定义动作和应用分组，自定义快捷键或自定义 App 只有完成详细配置后才出现在快捷菜单中；
- 菜单修改直接写入当前遥控器配置，下一次按键读取新值，无需重启进程；缺少输入监控或辅助功能权限时转到权限页面。

设置窗口在 macOS 26 使用原生 `glassEffect`、glass button style 和滚动边缘效果；macOS 14/15 使用标准按钮、系统 Material 面板和兼容选中状态。两套样式共用相同功能与布局，并跟随系统浅色、深色、降低透明度与增强对比度设置。

## 数据与日志

- 语音 PCM 只存在于进程内存和用户选择的 CoreAudio 输出链路中，不落盘、不上传；
- 测试音只在内存生成；
- 持久化内容包括增益、音频设备 UID、自定义映射开关、按键绑定和 macOS 外设 UUID；
- 日志位于 `~/Library/Logs/RemoteMic/runtime.log`，记录状态和错误，不记录语音内容、蓝牙地址或外设 UUID。

## 构建与测试

开发构建：

```bash
./scripts/test.sh
xcrun swift test
./scripts/build-app.sh
./scripts/verify-app.sh
```

`scripts/test.sh` 运行协议/策略自检并编译完整应用；Swift Testing 继续覆盖 ATVV、蓝牙生命周期、音频设备策略、按键、权限、配置兼容、Fn 映射、Typeless 会话生命周期、pre-roll、音频排空和测试音。

构建并启动应用：

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

`--verify` 会构建、启动并确认 `RemoteMic` 进程存在；它不是遥控器或真实语音链路的硬件验收。

## 发布产物

完整发布构建：

```bash
./scripts/build-dmg.sh
./scripts/verify-dmg.sh
```

`build-dmg.sh` 会依次构建并验证应用、驱动、安装 PKG 和卸载 PKG，生成：

- `dist/SayAll.app`；
- `dist/MiRemoteV2ch.driver`；
- `dist/Install Remote Mic.pkg`；
- `dist/Uninstall Remote Mic.pkg`；
- `dist/Remote-Mic-<版本>.dmg`；
- `dist/Remote-Mic-<版本>.dmg.sha256`。

DMG 根目录严格只有 `Install Remote Mic.pkg`；App-only ZIP 与对应架构的卸载 PKG 继续作为同一 Release 的高级资产。安装 PKG 不再作为独立 Release 资产重复上传，但仍完整保留在 DMG 内，并继续接受签名、公证、Gatekeeper 和 payload 校验。安装 PKG 在内部暂存驱动，安装后仅在现有驱动缺失、损坏、架构不符、签名异常或版本不匹配时替换，健康同版本驱动保持原样。

`verify-dmg.sh` 校验 SHA-256、HFS+ 镜像、唯一根入口和安装 PKG payload。应用 bundle、卸载 PKG、版本号、架构、最低系统、签名与本地路径泄漏继续由各自产物校验器覆盖；正式模式还校验 Developer ID Team、Hardened Runtime、PKG/DMG 签名、stapled 公证票据与 Gatekeeper 评估。

Sparkle `2.9.4` 通过 SwiftPM 嵌入应用。更新源和 EdDSA 公钥位于应用的 `Info.plist`；私钥仅存储在发布者本机的受限存储中，不进入项目或 Release。`SUEnableAutomaticChecks=true` 与 `SUScheduledCheckInterval=86400` 启用每日自动检查；`SUAutomaticallyUpdate=false` 与 `SUAllowsAutomaticUpdates=false` 禁止静默下载或自动安装。用户仍可选择菜单中的“检查更新…”立即检查。Sparkle 仅更新应用 bundle，不安装或替换兼容麦克风驱动。

正式发布使用 `scripts/notarize-release.sh`：它只接受已同步到发布 Mac 的既有 Developer ID 身份、Keychain 中的本地公证 profile 和受限的 Sparkle 私钥文件引用。脚本按应用、两个 PKG、DMG 的顺序公证和 staple，最后从已 staple 的应用生成 Sparkle ZIP 与签名 appcast；不会把任何证书、P12、API 密钥或私钥写入仓库或 Release。

候选版本先以 GitHub pre-release 发布。`notarize-release.sh` 使用固定 `RELEASE_TAG` 生成 appcast 的 GitHub 发布页，并让 enclosure ZIP 和本地化更新说明使用 `download.sayall.app/mac/releases/<tag>/` 的不可变 Cloudflare CDN 地址；发布脚本在 GitHub 资产可用后从 CDN 重新下载并逐字节比较，同时验证 `HEAD` 与 `Range`。应用内的 `SUFeedURL` 仍固定为 GitHub `releases/latest/download/appcast.xml`，旧安装用户不需要迁移 feed。GitHub 的 latest release 排除 draft 和 pre-release，因此默认关闭预发布检查的用户继续取得正式版本 appcast。用户在“关于”页主动开启预发布检查后，应用通过 GitHub 公共 Release API 解析最新一个带 `appcast.xml` 的非草稿 Release，并把其不可变资产 URL 作为 Sparkle 动态 feed；手动检查前会刷新，常驻运行时也会定期刷新。

`scripts/publish-release.sh prerelease` 只接受干净、已推送且由同一远端 Tag 指向的源提交。公开矩阵固定为 12 项：两套 DMG、两套 Sparkle ZIP、两套 appcast、两套架构卸载 PKG、共享中英文更新说明、合并的 SHA-256 清单和候选 provenance。两套安装 PKG 只存在于对应 DMG 内，不再作为独立 Release 资产重复上传。脚本确认 pre-release 未改变 latest release，并从 GitHub 与 CDN 回下载全部 12 项逐字节比较；晋升逻辑继续兼容历史 15/17 项 Release。测试机应使用与架构一致的 Sparkle CLI 单次 `--feed-url <候选版本 appcast URL>` 覆盖完成候选探测或更新，不写入持久化的 `SUFeedURL` 偏好；实际安装候选版本时需要处于已解锁的图形会话。

仅修改本地化文案或内置文档的低风险版本，在 `release/pre-v<版本>` 候选分支完成版本号、发布历史、commit 和 push 后，可使用 `ALLOW_ISOLATED_RELEASE_KEYCHAIN=1 ./scripts/fast-release.sh`。它会运行完整 Swift 测试、使用一次性 Keychain 分别签名并公证 Apple Silicon 与 Intel 产物，再发布 pre-release 并逐字节校验公开资产。正式晋升仍是独立授权步骤，必须在同一候选提交进入 `main` 后复用原始候选字节。快速命令只允许明确的文档和资源白名单，且 `Info.plist` 只能改变显示版本与 build number；发现 Swift、蓝牙、音频、安装器或发布流水线改动时会拒绝执行，必须走完整候选验收流程。

候选版本通过干净安装、运行和 Sparkle 端到端更新测试后，运行 `scripts/publish-release.sh promote` 将相同 Tag 和相同资产晋升为正式版。晋升后必须再次确认 latest appcast 与候选版本 appcast 逐字节一致。失败的候选版本不得覆盖资产或晋升；应递增显示版本和 `CFBundleVersion`，重新构建、签名、公证并发布新的 pre-release。

### 发布故障复盘与强制检查

`1.4.5` 的安装 PKG 曾在 `postinstall` 中调用 `/usr/bin/lipo` 和 `/usr/bin/vtool` 检查架构与最低系统版本。这两个命令属于 Xcode Command Line Tools，不是普通 macOS 安装环境的组成部分；未安装开发工具的用户会在安装时被要求下载命令行开发者工具，并因 `set -e` 直接中止安装。该问题来自安装脚本，不是应用运行逻辑、Developer ID 签名或 Apple 公证。

安装脚本运行在最终用户机器上，只能依赖产品最低系统版本保证存在的系统命令。`lipo`、`vtool`、`xcrun`、`xcode-select`、`xcodebuild`、`swift`、`swiftc` 和 `clang` 等开发工具不得出现在 PKG 的 `preinstall`、`postinstall` 或其他安装脚本中。架构和最低系统版本必须在发布机上由 `verify-app.sh`、`verify-doubao-driver.sh` 等构建验证脚本检查，不能在用户机器重复检查。

`scripts/verify-doubao-driver-pkg.sh` 会展开最终 PKG 并拒绝包含上述开发工具调用的安装脚本。每次发布还必须对从 GitHub Release 回下载的最终 PKG 再执行同一检查；只检查仓库中的脚本源码不够，因为打包过程可能使用了不同或过期的脚本副本。

`1.4.2` / `1.4.3` 的安装 PKG 曾在 `postinstall` 中先把应用目录内的普通文件全部改为 `0644`，随后只把 `Contents/MacOS/RemoteMic` 恢复为 `0755`。这会在安装完成后移除 Sparkle、`Autoupdate`、Updater 及 XPC 服务的执行权限。原始 App、ZIP、PKG、DMG 的签名、公证和 Gatekeeper 检查仍可能全部通过，因为错误发生在安装后的文件权限改写阶段；因此只验证发布产物不足以发现该问题。

安装后的应用必须保持以下文件为 `0755`：

- `Contents/MacOS/RemoteMic`；
- `Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle`；
- `Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate`；
- `Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater`；
- `Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer`；
- `Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader`。

`packaging/doubao-driver/install/postinstall` 逐项恢复并检查这些权限，`scripts/verify-doubao-driver-pkg.sh` 会拒绝缺少相应规则的安装包。每次正式发布还必须：

1. 在隔离目标目录模拟 PKG 安装后的权限处理，而不是只检查 payload；
2. 对安装后的应用执行 `codesign --verify --deep --strict`，并通过 launchd 实际启动 `Autoupdate`、Updater 与相关 XPC/Mach 服务；
3. 从已发布 Release 重新下载 appcast、ZIP、DMG 和两个 PKG，核对 GitHub digest、本地 SHA-256、签名、公证票据和 Gatekeeper；
4. 仅在图形会话已解锁时声明完成了 Sparkle 端到端 UI 升级。锁屏下 appcast 返回 HTTP 200 只证明更新源可访问；
5. 明确区分旧安装与新安装：已被旧 PKG 改坏的更新器不能自我更新，必须先运行新版 Installer.pkg 或通过远程终端恢复权限。

发布签名还必须区分“证书可列出”和“私钥可使用”。登录 Keychain 锁定时，`security find-identity` 可能仍能列出证书，但 `codesign` 会因无法访问私钥而返回 `errSecInternalComponent`。在用户明确授权时，可沿用 readonly Match/P12，把既有证书同步到仅用于本次发布的一次性空密码 Keychain；不得创建、撤销或更改证书。发布结束必须删除一次性 Keychain、P8、Match 密码和临时 clone，并确认用户 Keychain 搜索列表只保留原有登录 Keychain。

## 许可与来源

本仓库中的 macOS App、驱动及相关软件代码按 `GPL-3.0-only` 发布；iOS App 已由独立私有仓库维护。macOS App 的 Logo 与 App Icon 按独立的 [Logo 许可](LOGO-LICENSE.md) 管理。ATVV 与 RC003 行为参考 `xxb26553663-star/remote-bridge-hub`，豆包兼容驱动基于固定版本 BlackHole 构建；完整归属与限制见 [COPYRIGHT.md](COPYRIGHT.md) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
