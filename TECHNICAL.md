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
| `BridgeAppModel.swift` | 蓝牙、音频、HID、语音键映射和 UI 状态的协调层 |
| `XiaomiBluetoothBridge.swift` | CoreBluetooth 扫描、连接、能力协商、语音会话和自动重连 |
| `ATVVProtocol.swift` | ATVV 命令、能力解析、IMA/DVI ADPCM 解码、帧累积与 PCM 后处理 |
| `AudioOutput.swift` | CoreAudio 输出设备枚举和 16 kHz 单声道语音写入 |
| `HIDRemoteMonitor.swift` | RC003 原始 HID 报告、独占/兼容模式、按键重复和活动状态 |
| `KeyboardEventSuppressor.swift` | 兼容模式下对同一遥控器原生系统事件的短时抑制 |
| `KeyboardInjector.swift` | 键盘、媒体键和预置应用启动动作 |
| `RemoteVoiceFunctionMapper.swift` | RC003 语音键 F5 的 Fn 映射或 Command 模式中和，并在退出时恢复 |
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

## 语音键触发方式与 Fn 映射

RC003 的语音键以键盘 F5（usage page `0x07`、usage `0x3E`）出现。`RemoteVoiceFunctionMapper` 只匹配 RC003 的 Vendor ID/Product ID；默认把该 usage 映射为 Apple vendor top-case Fn/Globe（usage page `0xFF`、usage `0x03`）。自定义按键映射启用时，同一组件还会把 RC003 的 Keyboard Power（usage `0x66`）映射为 F20（usage `0x6F`）。

默认关闭的 Typeless 兼容模式会先确认辅助功能权限，再以事务方式把所有匹配 RC003 服务的 F5 映射为 usage `0`；任一目标失败或目标不完整时立即回滚、关闭设置并恢复默认 Fn 映射。开启后，`VoiceFnTapSessionController` 在物理语音流开始时缓存 pre-roll，Fn 开始点按成功后再写入回环设备；松开时等待 `VirtualAudioOutput.endSessionAfterDraining` 排空队列，再发送配对的 Fn 结束点按。generation 和可取消任务隔离快速连续会话，并在开关关闭、断连、重连或 App 退出时完成或取消对应会话；开始点按失败时不会发送结束点按。

该兼容模式只转换目标应用看到的触发语义，RC003 仍然必须按住语音键才会采集音频，不提供持续录音或独立语音输入。设置导入导出包含可选的 `voiceKeyMode`、`voiceFnTapModeEnabled` 和 `voiceShortTapFocusEnabled`；旧配置缺少新字段时保持默认关闭。Fn 点按与短按聚焦互斥。应用退出、断连或模式切换时会释放尚未释放的 Command 按键，并恢复启动前对应 source usage 的映射，同时保留运行期间其他来源的映射变化。

语音键模式由统一的语音会话状态机驱动：`fn`（默认）、`left_command`、`right_command`。Command 模式在 RC003、iPhone、Apple Watch 和网页版语音开始时发送所选 Command 的 keyDown，在结束时发送配对的 keyUp。普通键盘 Command 不会触发输入源切换；只有真实语音会话才会显式开始和结束输入源会话。

`VoiceShortTapFocusPolicy` 复用 `HIDRemoteTiming.longPressMilliseconds`：开关启用且会话时长小于阈值时，松开后取消转写捕获、清空该次短音频，并异步调用 `KeyboardInjector.focusFrontmostComposer`。输入框排名拒绝搜索、设置、密码、Token、终端和代码编辑器等候选；Electron / Chromium 复用已有辅助功能树唤醒和有界重试。微信主聊天窗口不暴露输入框，所以仅对精确 Bundle ID 使用最小窗口尺寸门禁和窗口相对点击。

## 菜单栏与窗口

应用以 `LSUIElement` accessory 模式运行，不显示 Dock 图标。状态栏按钮同时接收左右鼠标抬起事件：

- 左键：创建或置前默认及最小尺寸为 1020×772 的可缩放设置窗口；
- 右键：显示连接、音频、HID 状态，以及重新连接、打开设置、日志、关于、版本号、检查更新、GitHub 和退出菜单。

设置窗口在 macOS 26 使用原生 `glassEffect`、glass button style 和滚动边缘效果；macOS 14/15 使用标准按钮、系统 Material 面板和兼容选中状态。两套样式共用相同功能与布局，并跟随系统浅色、深色、降低透明度与增强对比度设置。

## 数据与日志

- 语音 PCM 只存在于进程内存和用户选择的 CoreAudio 输出链路中，不落盘、不上传；
- 测试音只在内存生成；
- 持久化内容包括增益、音频设备 UID、自定义映射开关、按键绑定和 macOS 外设 UUID；
- 日志位于 `~/Library/Logs/RemoteMic/runtime.log`，每行包含无线麦自身 PID、版本与 Build；单文件达到 10 MiB 后滚动到 `.1`～`.3`，最旧归档只移入 macOS 废纸篓。日志记录状态和错误，不记录语音内容、蓝牙地址、外设 UUID、前台 App 或外部事件来源 PID。

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

预览版发布采用两阶段 main-based 流程。版本和 Build 先通过普通 PR 合入 main；随后 .github/workflows/mac-release-package.yml 在受保护 mac-release Environment 中从精确 main SHA 构建 Apple Silicon 与 Intel 两条 lane，完成 Developer ID 签名、公证、staple、ZIP/DMG/PKG/appcast 校验，并上传不可变 payload artifact 和 stage record。该 workflow 不创建 Tag、Release 或公开 appcast。

当前授权会话从公开稳定版 v1.8.3 下载真实归档，使用只替换 URL 前缀的本地固定 feed，让稳定 App 通过真实 Sparkle UI 完成检查、下载、安装、首次启动、退出和二次启动；未完成这一步不得发布 Preview。attestation 绑定 Run、attempt、artifact、manifest、appcast、版本/Build、Team ID、公证、Gatekeeper、Sparkle helper 权限和无新增崩溃。

.github/workflows/mac-preview-publication.yml 只在 main 上运行，不进入 Apple Environment，不读取 Apple/Match/Notary/Sparkle 私钥。它按 exact artifact ID/digest 恢复 staged bytes，创建或复用同一 source SHA 的轻量 Tag，上传 canonical manifest 的 11 项 payload 与 candidate-provenance.json，并从 GitHub fixed-tag URL 和 download.sayall.app 固定 Tag URL 逐项下载、比较字节。Preview 期间 releases/latest 必须保持 v1.8.3。

公开资产集合由 scripts/prepare-public-release-assets.sh 和 staged-assets.json 定义；两套安装 PKG 仍在对应 DMG 内，不作为独立公开资产重复上传。版本选择、staging 和首次 publication 创建 Tag 前都会检查 11 个 CDN 固定路径，只有 HTTP 404 才算可用，2xx/3xx 视为占用，认证、权限、5xx、超时或未知响应 fail closed。脚本和 verifier 不依赖最新 Run、候选分支或固定以外的隐式来源。Preview publication 和 Stable promotion 只允许写入 `HD838A/remote-mic-app`，并 checkout dispatch 事件的精确 SHA；基础设施失败只重试同一 SHA、版本、Build 和已成功 artifact；不升版本、不重签、不覆盖 Tag。

本地 scripts/stage-macos-preview.sh 只做无秘密预检和 dispatch，不在本机签名、公证、创建 Tag/Release 或上传资产。私有内部 Draft 继续走 private-draft-release skill 的 GetSayAll/SayAll 路径，不能误写入公开源码仓库。

只有用户明确指定已经发布并验证的 Pre-release，才可运行 stable promotion。该流程验证 provenance、精确 protected staging Run/attempt 及 payload/stage-record artifact 身份、Tag/main 祖先关系和资产摘要，然后只修改 Release 分类与 latest；不重新构建、签名、公证或上传。
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
