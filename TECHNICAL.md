# 无线麦技术文档

[English](TECHNICAL.en.md)

本文面向开发、审计和发布人员，描述 `1.3.0 (21)` 对应代码的实现、构建和发布约束。普通用户请阅读 [README.md](README.md)。

## 支持范围

- 运行系统：macOS 26 或更高版本；
- 架构：Apple Silicon `arm64`；
- 目标遥控器：小米蓝牙遥控器 2 Pro / RC003；
- HID 标识：Vendor ID `0x2717`、Product ID `0x32B8`；
- Swift 工具链：Swift 6.2，源码以 Swift 5 语言模式编译；
- 发布签名：应用默认使用带固定 designated requirement 的 ad-hoc 签名；仅在显式传入有效签名身份时使用该身份。驱动使用 ad-hoc 签名，PKG 未使用 Installer 证书签名，当前未公证。

`Package.swift`、`Resources/Info.plist`、构建脚本和验证脚本都把最低系统版本固定为 macOS 26，并验证发布二进制只有 `arm64` 架构。

## 模块结构

| 模块 | 主要职责 |
| --- | --- |
| `RemoteMicApp.swift` | AppKit 生命周期、菜单栏图标、左键设置窗口、右键菜单、关于与版本菜单项、Sparkle 手动更新入口 |
| `SettingsView.swift` | macOS 26 Liquid Glass 设置界面、状态展示、音频选择、按键映射和权限入口 |
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

- `/Applications/Remote Mic.app`；
- `/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver`。

安装脚本校验架构、最低系统版本和签名，重启 CoreAudio，并为当前桌面用户启动应用。卸载 PKG 只删除 `MiRemoteV2ch.driver` 并重启 CoreAudio，不删除应用或 BlackHole。

## HID 与按键映射

自定义按键映射默认关闭。启用后必须同时具备输入监控和辅助功能权限，否则 HID 处理失败关闭。

`HIDRemoteMonitor` 首先尝试独占打开 RC003。若 macOS 拒绝独占，则退回非独占监听，并由 `KeyboardEventSuppressor` 在收到 RC003 原始报告后的 180 毫秒窗口内抑制匹配的原生系统事件。合成事件带有独立标记，不会被再次抑制。

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

RC003 的语音键以键盘 F5（usage page `0x07`、usage `0x3E`）出现。`RemoteVoiceFunctionMapper` 只匹配 RC003 的 Vendor ID/Product ID，并把该 usage 映射为 Apple vendor top-case Fn/Globe（usage page `0xFF`、usage `0x03`）。

应用启动或蓝牙 ready 时应用映射；语音流开始和结束通过 `VoiceFunctionKeyLatch` 保证每个会话只产生一次按下和一次释放。应用退出时恢复启动前该 source usage 的映射，同时保留运行期间其他来源的映射变化。

## 菜单栏与窗口

应用以 `LSUIElement` accessory 模式运行，不显示 Dock 图标。状态栏按钮同时接收左右鼠标抬起事件：

- 左键：创建或置前 800×650 的可缩放设置窗口；
- 右键：显示连接、音频、HID 状态，以及重新连接、打开设置、日志、关于、版本号、检查更新、GitHub 和退出菜单。

设置窗口包含“连接”“按键”“权限”三个页面，使用 macOS 26 原生 `glassEffect` 和 glass button style，并跟随系统浅色、深色、降低透明度与增强对比度设置。

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

`scripts/test.sh` 运行 36 项协议/策略自检并编译完整应用。当前 Swift Testing 测试为 62 项，覆盖 ATVV、蓝牙生命周期、音频设备策略、按键、权限、语言选择持久化与即时 Locale 更新、Fn 映射和测试音。

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

- `dist/Remote Mic.app`；
- `dist/MiRemoteV2ch.driver`；
- `dist/Install Remote Mic.pkg`；
- `dist/Uninstall Remote Mic.pkg`；
- `dist/Remote-Mic-1.3.0.dmg`；
- `dist/Remote-Mic-1.3.0.dmg.sha256`。

DMG 根目录严格只有四项：

- `Install Remote Mic.pkg`；
- `Uninstall Remote Mic.pkg`；
- `Remote Mic.app`；
- 指向 `/Applications` 的 `Applications` 入口。

`verify-dmg.sh` 校验 SHA-256、HFS+ 镜像、根目录清单、应用 bundle 内容、PKG payload、版本号、`arm64` 架构、macOS 26 最低版本、有效代码签名和本地路径泄漏。

Sparkle `2.9.4` 通过 SwiftPM 嵌入应用。更新源和 EdDSA 公钥位于应用的 `Info.plist`；私钥仅存储在发布者本机的受限存储中，不进入项目或 Release。`SUEnableAutomaticChecks=false` 禁止启动时和定时检查，只有用户选择菜单中的“检查更新…”时才会访问更新源。Sparkle 仅更新应用 bundle，不安装或替换兼容麦克风驱动。

## 许可与来源

项目软件代码按 `GPL-3.0-only` 发布，App Logo 按独立的 [Logo 许可](LOGO-LICENSE.md) 管理。ATVV 与 RC003 行为参考 `xxb26553663-star/remote-bridge-hub`，豆包兼容驱动基于固定版本 BlackHole 构建；完整归属与限制见 [COPYRIGHT.md](COPYRIGHT.md) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
