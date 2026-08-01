# SiriRemoteForge 与“无线麦”集成评估

- 研究日期：2026-07-30
- 研究对象：[HOLODATA-COM/SiriRemoteForge](https://github.com/HOLODATA-COM/SiriRemoteForge)
- SiriRemoteForge 研究提交：[`10581a960f0738e36516defb79db24b18df214d3`](https://github.com/HOLODATA-COM/SiriRemoteForge/tree/10581a960f0738e36516defb79db24b18df214d3)
- 研究时仓库基线：`Remote Mic 1.4.8 (32)`，macOS 26+，Apple Silicon；当前产品基线已降低为 macOS 14+、Apple Silicon

本文只做源码、安装包逻辑和公开项目的研究，没有修改应用代码、构建脚本、签名配置或安装包逻辑，也没有在当前项目中安装 SiriRemoteForge 的系统组件。

## 结论摘要

1. **可以支持第三代 Siri Remote（USB-C，常见型号 A2854）的按键、触摸板和麦克风，但不是直接替换 RC003 蓝牙后端。** RC003 使用 CoreBluetooth + ATVV + IMA/DVI ADPCM；Siri Remote 麦克风使用 HID-over-GATT 上的 Opus 语音，但 macOS 不把这条音频通道开放给普通 CoreBluetooth 应用。两者需要独立的设备后端。
2. **苹果遥控器触摸板可以实现页面滚动。** SiriRemoteForge 已实现双指线性滚动和单指外圈的 iPod 式圆周滚动，也能移动鼠标、轻点点击和拖拽。它依赖私有 `MultitouchSupport`，需要输入监控和辅助功能权限，并存在 macOS 版本、签名和公证兼容风险。
3. **麦克风是最重的部分。** SiriRemoteForge 已实机验证的 macOS 路径依赖 Apple PacketLogger、Bluetooth HCI 调试跟踪、root LaunchDaemon、Opus 路由器、共享内存和 CoreAudio HAL 插件。它不是普通应用内可完成的 CoreBluetooth/IOHID 功能。
4. **当前“无线麦”的大部分产品层功能可以保留，但不能视为 SiriRemoteForge 开箱即用地全部提供。** 设置界面、多语言、Sparkle、音频设备选择、测试音、增益、按键动作和 `MiRemoteV 2ch` 等可以继续存在；Apple Remote 的连接、按键、触摸、语音传输和编解码必须单独适配。
5. **完整接入会显著改变安装、权限、隐私和发布模型。** 最小的“按键 + 触摸”方案不需要新增 HAL 或 root 服务；完整麦克风方案则需要管理员安装、外部 PacketLogger、系统 LaunchDaemon、HCI 调试配置以及可靠卸载和回滚。
6. **不建议第一阶段直接合并 SiriRemoteForge 的完整系统级麦克风堆栈。** 建议先做 Apple Remote 按键支持，再验证触摸/滚动及正式签名，最后把 PacketLogger 麦克风作为独立、可选的高级组件评估。
7. **在继续深度比较 Wand、siri-remote-steamos 和 SiriRemoteVibe 后，总体首选仍是 SiriRemoteForge。** Wand 是最佳轻量触摸参考但没有麦克风；SteamOS 项目有直接 BLE 麦克风但无法用于 macOS；SiriRemoteVibe 是 Forge 的两提交衍生版，没有 Release，也没有衍生改动后的实机麦克风证据。详细选型见 [三项目深度对比与最终选型](candidate-comparison.md)。

## 证据等级

本文用以下标记区分结论的可靠程度：

- **已由源码确认**：可以从当前仓库或指定提交直接确认实现和安装行为。
- **上游已实机验证**：SiriRemoteForge 文档记录了指定硬件上的实际捕获或系统验证，但本项目尚未复现。
- **外部项目佐证**：其他公开项目独立得到相同协议或平台结论。
- **待本项目验证**：在当前签名、公证和目标 A2854 固件组合上，仍需覆盖 macOS 14 至 macOS 26 的受支持系统范围进行实机验证。

## 当前“无线麦”的基线

当前实现见 [TECHNICAL.md](../../TECHNICAL.md)、[XiaomiBluetoothBridge.swift](../../Sources/RemoteMic/XiaomiBluetoothBridge.swift)、[ATVVProtocol.swift](../../Sources/RemoteMic/ATVVProtocol.swift)、[AudioOutput.swift](../../Sources/RemoteMic/AudioOutput.swift) 和 [HIDRemoteMonitor.swift](../../Sources/RemoteMic/HIDRemoteMonitor.swift)。

### 数据路径

```text
小米 RC003
→ CoreBluetooth / ATVV
→ IMA/DVI ADPCM 解码
→ 16 kHz 单声道 PCM
→ AVAudioEngine
→ MiRemoteV 2ch 或用户选择的回环音频设备
→ 语音输入应用
```

### 当前权限与系统改动

- 蓝牙：连接 RC003 并收取 ATVV 语音；`Info.plist` 已有 `NSBluetoothAlwaysUsageDescription`。
- 输入监控：只在启用自定义普通按键时需要。
- 辅助功能：只在启用自定义按键并发送键盘、媒体或应用动作时需要。
- 推荐 PKG 已使用管理员权限安装 `/Applications/Remote Mic.app` 和 `/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver`，随后重启 `coreaudiod`。
- 没有 root 常驻服务，没有 PacketLogger，没有修改 Bluetooth HCI 调试配置。
- 正式版本使用 Developer ID、Hardened Runtime、公证和 staple；Sparkle 只更新应用本体，不更新 HAL 驱动。
- 应用不修改系统默认输入或输出，语音不落盘。

## SiriRemoteForge 的两条输入路径

### 按键与触摸

**已由源码确认。** SiriRemoteForge 使用 `IOHIDManager` 读取按键，使用私有 `MultitouchSupport` 读取触摸板，再通过 `CGEvent`、媒体键、AppleScript 等执行动作。上游功能说明见其 [README 的功能和架构部分](https://github.com/HOLODATA-COM/SiriRemoteForge/blob/10581a960f0738e36516defb79db24b18df214d3/README.md#L40-L119)。

```text
Siri Remote
→ macOS HID / 私有 MultitouchSupport
→ 按键与触摸手势识别
→ 映射引擎
→ 鼠标、滚动、键盘、媒体、窗口或应用动作
```

### 麦克风

**上游已实机验证，待本项目复现。** SiriRemoteForge 的工作路径见其 [麦克风说明](https://github.com/HOLODATA-COM/SiriRemoteForge/blob/10581a960f0738e36516defb79db24b18df214d3/README.md#L223-L262) 和 [`mic/README.md`](https://github.com/HOLODATA-COM/SiriRemoteForge/blob/10581a960f0738e36516defb79db24b18df214d3/mic/README.md)：

```text
第三代 Siri Remote
→ BLE / HCI
→ Apple PacketLogger 捕获
→ ACL / L2CAP / ATT 重组
→ 提取 Opus 语音帧
→ Opus 解码为 PCM
→ 共享内存环形缓冲
→ SiriRemoteMic HAL 插件
→ 系统级 “Siri Remote Mic” 输入设备
```

上游记录的协议事实：

- `0xFA`：麦克风音频；
- `0xFB`：系统按键；
- `0xFC`：触摸数据；
- 麦克风帧为 Opus，20 ms、单声道，通常以 48 kHz 解码为每帧 960 samples；
- 遥控器通常只在按住 Siri 键时发送真实音频；
- 上游一次实机捕获提取了 804 个语音帧并全部成功解码，用户确认回放清晰；
- macOS 不把遥控器公开为标准 CoreAudio 蓝牙麦克风。

Linux 项目 [`azais-corentin/siri-remote`](https://github.com/azais-corentin/siri-remote/tree/b165251ec50e7699064e586bc39957ec6702c52f) 独立确认了 `0xFA` / `0xFB` / `0xFC`、Opus 20 ms 帧和 PipeWire 麦克风输出，构成协议层外部佐证。

## 权限和系统要求变化

以下表格区分“用户可见的隐私权限”和“安装时的系统级能力”。并不是所有权限都必须在同一阶段引入。

| 权限或能力 | 当前无线麦 | 按键/触摸接入 | 完整麦克风接入 | 结论 |
| --- | --- | --- | --- | --- |
| 蓝牙 | 已需要 | 继续需要 | 继续需要 | 现有权限，但用途说明需覆盖 Apple Remote |
| 输入监控 | 自定义按键开启时需要 | 核心权限 | 核心权限 | 触摸/按键接入后会从可选能力变成主要能力 |
| 辅助功能 | 自定义动作开启时需要 | 鼠标、滚动、键盘、窗口动作需要 | 同左 | 页面滚动和鼠标控制依赖该权限 |
| 麦克风 TCC | 当前应用不需要 | 不需要 | **条件新增** | 远端语音经 HCI 捕获本身不要求应用的麦克风 TCC；只有保留上游“Mac 内建麦克风 fallback/crossfade”时，应用才需要 `NSMicrophoneUsageDescription` 和麦克风授权 |
| 自动化 / Apple Events | 当前不是核心要求 | **条件新增** | 条件新增 | 使用 System Events 切换 Spaces 或控制其他应用时会触发 Automation 授权；不用这些动作可不引入 |
| 管理员授权 | 推荐 PKG 安装 HAL 时已有 | App-only 不需要 | 必须 | 新增的不只是一次安装授权，而是安装 root LaunchDaemon、HCI 捕获组件和额外 HAL 的权限范围 |
| root LaunchDaemon | 无 | 无 | **新增** | 上游 `srm_captured` 以 root 常驻等待需求，只在虚拟设备被使用时启动 PacketLogger/router |
| Bluetooth HCI 调试配置 | 无 | 无 | **新增** | 修改 `/Library/Preferences/com.apple.MobileBluetooth.debug` 的 `HCITraces`，并通知 `bluetoothd` 重载；卸载必须恢复原值 |
| App Sandbox | 未启用 | 不能启用 | 不能启用 | 私有 `MultitouchSupport`、低层 HID、HAL 和系统服务均不适合 App Sandbox；不能走 Mac App Store 模型 |
| Hardened Runtime | 正式版本已启用 | **存在兼容风险** | 系统组件仍需逐个签名验证 | SiriRemoteForge 上游称 Hardened Runtime 会在触摸回调时杀死进程，因此其 beta 采用 ad-hoc/非 Hardened Runtime；不能直接沿用到当前发布链 |
| 私有框架 | 无 | **新增** | 触摸功能仍新增 | `MultitouchSupport` 和部分 Spaces 能力使用私有接口，Apple 可随系统版本改变 |
| PacketLogger | 无 | 无 | **新增外部依赖** | 必须由用户从 Apple Developer 的 Additional Tools for Xcode 获取；上游明确不在公开 Release 中捆绑，本项目也不能假定拥有再分发权 |

### 不需要的权限

按 SiriRemoteForge 当前选定的 PacketLogger + HAL 路径，不需要 DriverKit HID entitlement，也不需要安装 System Extension。它同样不需要屏幕录制或完全磁盘访问。早期 DriverKit 路径保留在上游仓库中，但已被当前 `mic/` 路径取代。

### 上游 entitlements 不能直接视为最终答案

SiriRemoteForge 当前 app entitlement 包含：

- `com.apple.security.device.bluetooth`；
- `com.apple.security.cs.disable-library-validation`；
- `com.apple.security.cs.allow-dyld-environment-variables`。

这些是上游当前构建的配置，不等于本项目正式分发时已证明的最小 entitlement 集合。若未来实施，必须从最终产物导出 entitlements，并分别验证主 App、helper、router、HAL 插件和安装包，不能只根据源码文件推断。

## 安装过程会如何变化

### 当前安装

```text
Install Remote Mic.pkg
→ /Applications/Remote Mic.app
→ /Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver
→ 验证签名
→ 重启 coreaudiod
→ 启动应用
```

### 只接入 Apple Remote 按键和触摸

理论上的安装变化较小：

```text
现有 App / PKG
→ 包含 Apple Remote HID 与触摸能力的应用
→ 首次运行授权输入监控与辅助功能
→ 在系统蓝牙中配对 Siri Remote
```

这一阶段不需要 PacketLogger、root daemon 或新的音频驱动，也不需要改变 `MiRemoteV 2ch`。真正的难点是私有触摸框架在当前 Developer ID + Hardened Runtime + 公证构建中的稳定性，而不是复制文件。

SiriRemoteForge 自己的文档选择了 ad-hoc、非 Hardened Runtime，并要求首次右键打开。与此同时，[Wand](https://github.com/wongsiufool/wand) `v0.2.0` 的公开 DMG 确实是 Developer ID 签名、Hardened Runtime 且已公证；本次只读检查确认其签名和 staple 有效。但 Wand 源码中的触摸处理仍留有“硬件上未实际跑到触摸帧”的注释，因此它只能证明“Apple 公证接受了该二进制”，不能证明 A2854 触摸在 Hardened Runtime 下长期稳定，也不能推翻 SiriRemoteForge 的运行时问题。该冲突必须在本项目目标机器上实测。

本次对 Wand `v0.2.0` 的只读产物核验记录：

- DMG SHA-256：`5efe52539bf4a42d0cbaf4c97b8ead1bbd42b70bf95a01902d2b57a9a445d95c`；
- `xcrun stapler validate`：通过；
- `spctl`：`accepted`，来源为 `Notarized Developer ID`；
- 签名主体：`Developer ID Application: Kaihong Chen (DBYWRB2S9S)`；
- App CodeDirectory flags 包含 `runtime`；
- 本次没有启动该 App，也没有用真实 Siri Remote 验证触摸数据。

### 按 SiriRemoteForge 原样接入完整麦克风

完整安装大致会变为：

```text
安装器 / Full Setup
→ 安装 Remote Mic.app
→ 保留 MiRemoteV 2ch，或另装 SiriRemoteMic.driver
→ 安装 srm_captured 与 srm_router
→ 安装 /Library/LaunchDaemons/au.holodata.SiriRemoteMic.captured.plist
→ 保存原 Bluetooth HCITraces 设置
→ 安装或检查 /Library/Audio/Plug-Ins/HAL/SiriRemoteMic.driver
→ 重启 coreaudiod
→ 监控 coreaudiod 25 秒，异常时回滚 HAL
→ 检查 /Applications/PacketLogger.app
→ 首次使用时完成 TCC 授权
```

上游安装脚本的明确系统落点：

- `/Library/Audio/Plug-Ins/HAL/SiriRemoteMic.driver`；
- `/Library/Application Support/SiriRemoteMic/srm_captured`；
- `/Library/Application Support/SiriRemoteMic/srm_router`；
- `/Library/LaunchDaemons/au.holodata.SiriRemoteMic.captured.plist`；
- `/var/log/srm_captured.log`；
- 对 `/Library/Preferences/com.apple.MobileBluetooth.debug` 中 `HCITraces` 的受控修改和恢复。

上游 [`dist/do_install.sh`](https://github.com/HOLODATA-COM/SiriRemoteForge/blob/10581a960f0738e36516defb79db24b18df214d3/dist/do_install.sh) 会在安装 HAL 后监控 `coreaudiod` 25 秒，连续 3 秒超过 85% CPU 时自动回滚。其 [`dist/do_uninstall.sh`](https://github.com/HOLODATA-COM/SiriRemoteForge/blob/10581a960f0738e36516defb79db24b18df214d3/dist/do_uninstall.sh) 会停止 daemon、删除 HAL/支持文件、恢复安装前的 HCITraces，并重启 CoreAudio、通知 `bluetoothd`。

截至本研究日期，SiriRemoteForge 的 GitHub Releases API 没有返回公开 Release 资产；README 中描述了 App-only 和 Full Setup 流程，但当前不能把它当成已经可供本项目直接下载集成的稳定二进制发布。

### 更适合当前项目的最小麦克风集成思路

如果目标只是“让 A2854 的声音进入现有无线麦产品”，不一定要同时安装第二个 `SiriRemoteMic.driver`。更小的产品边界是：

```text
PacketLogger/root capture helper
→ Apple Opus 解码
→ 受控 IPC 交给 Remote Mic.app
→ 继续写入现有 MiRemoteV 2ch / 用户选择的回环设备
```

这样可以保留当前音频设备选择、测试音、增益和豆包兼容路径，并避免系统里同时出现两个本项目管理的虚拟麦克风。代价是需要自行定义 helper 到 App 的 IPC、进程生命周期、断线恢复和隐私边界；SiriRemoteForge 的 built-in mic fallback、按 CoreAudio consumer 按需启动和 HAL crossfade 不能原样照搬。

这只是研究建议，尚未在当前仓库实现或验证。

### 更新和卸载

- Sparkle 仍只能安全更新主 App，不能替换 `/Library` 下的 HAL、LaunchDaemon 和 root helper。
- 系统组件升级仍需签名 PKG 或带授权的 Setup 应用。
- 必须提供独立卸载入口，并恢复 HCITraces 的安装前状态；只删除 App 会留下 root 服务和 HAL。
- 安装、升级和卸载必须分别验证 `coreaudiod`、`bluetoothd`、现有 `MiRemoteV 2ch`、其他蓝牙设备和系统音频不会受到持续影响。

## 当前无线麦功能兼容性

“支持”分为两层：产品能力可以保留，不代表 SiriRemoteForge 的现有代码可以直接复用。

| 当前功能 | Apple Remote 可否达到 | 说明 |
| --- | --- | --- |
| 按住语音键说话、松开结束 | 可以，但依赖完整语音链路 | A2854 通常只在按住 Siri 键时输出语音；PacketLogger 缺失时，按键/触摸仍可能可用，但遥控器麦克风不可用 |
| 输出到 `MiRemoteV 2ch` 或其他回环设备 | 可以保留，需适配 | SiriRemoteForge 默认发布自己的 `Siri Remote Mic` 输入设备；若保留当前输出选择，需要把 Apple PCM 接到现有 `VirtualAudioOutput` 路径 |
| 0–24 dB 增益 | 可以保留，需适配 | 可在解码后的 PCM 上使用现有增益策略；上游不是同一处理链 |
| 1 秒测试音 | 可以保留 | 与遥控器传输协议无关，但要继续避免与真实语音抢占输出 |
| 普通按键映射 | 可以 | Apple 的 `0xFB` 报告和按键集合不同，不能复用 RC003 的 usage 表 |
| 单击、双击、长按和重复 | 可以，而且上游更丰富 | SiriRemoteForge 支持单/双/三击和三段长按；与当前设置模型的映射方式不同 |
| 系统音量、播放暂停、快捷键、打开应用 | 可以 | 继续需要辅助功能；部分 AppleScript 动作可能需要 Automation |
| RC003 语音键映射为 Fn/Globe | 不能原样复用 | 当前实现只匹配小米 Vendor/Product 和 F5 usage；Apple Siri 键需要独立行为定义 |
| 蓝牙自动连接/重连 | 目标可以保留，机制不同 | RC003 由 CoreBluetooth 外设 UUID 管理；Siri Remote 主要由系统 HID 配对和 IOHID 设备出现/消失驱动 |
| 设置界面、菜单栏/Dock、多语言 | 可以保留 | 属于产品层，和底层设备协议解耦 |
| Sparkle 更新 | 可以保留主 App 更新 | 不能覆盖 root helper、LaunchDaemon 或 HAL 的升级 |
| 不修改默认输入/输出 | 应继续保持 | SiriRemoteForge 的文档也声明 built-in fallback 不改变默认设备；仍需防止 HAL 被系统记成 preferred/default 的异常情况 |
| 语音不落盘 | 需要重新定义 | 当前无线麦只在内存处理；PacketLogger 方案会生成临时 `.pklg` HCI 捕获文件，上游在 `/tmp` 使用该文件，必须明确生命周期、权限和清理策略 |

因此，答案不是“全部开箱即用”，而是：**现有功能目标大部分能够继续支持，但 Apple Remote 需要独立的 transport、codec、HID、触摸和安装实现；麦克风与隐私模型尤其不能直接复用 RC003 代码。**

## SiriRemoteForge 比当前无线麦多的功能

### 触摸和鼠标

- 触摸板移动鼠标；
- 轻点点击、实体按压点击；
- 按住拖拽和 sticky drag；
- 双指滚动；
- 单指外圈圆周滚动；
- 单指滑动手势、双指轻点；
- 指针速度、加速度、死区和 shake-to-find。

### 映射能力

- 每个应用独立 profile，并支持继承；
- momentary/sticky layers；
- 单击、双击、三击；
- 三段长按、release-to-select、hold-to-repeat；
- JSONC 配置和保存后热重载；
- 层级 HUD、长按 HUD、连接 HUD。

### 系统控制

- Spaces 动画切换；
- Mission Control/窗口最小化/全屏等动作；
- 径向应用启动器；
- focus-follows-cursor；
- 遥控器电池、固件和更多 HID 诊断。

### 麦克风扩展

- 独立的系统级 `Siri Remote Mic` 输入设备；
- Siri Remote 与 Mac 内建麦克风之间 crossfade；
- 根据虚拟设备是否被应用使用，按需启动/停止 PacketLogger 捕获流水线；
- HAL 安装 watchdog 和自动回滚。

## 当前无线麦相对更成熟的部分

- 已有 Developer ID 签名、公证、staple 和完整发布验证；
- 研究时已有面向 macOS 26、Apple Silicon 的产品化安装和卸载包；当前产品最低版本已降低为 macOS 14；
- 已有 Sparkle 更新、多语言、设置 UI 和日志隐私规则；
- 已有豆包兼容的 `MiRemoteV 2ch`；
- RC003 语音通过公开 CoreBluetooth ATVV 直接进入应用，不需要 root、PacketLogger 或 HCI 调试；
- 现有语音不落盘，系统改动范围更小。

## 苹果遥控器触摸滚动的明确结论

**能实现。** SiriRemoteForge 的 [`TouchHandler.swift`](https://github.com/HOLODATA-COM/SiriRemoteForge/blob/10581a960f0738e36516defb79db24b18df214d3/app/TouchHandler.swift) 明确实现了：

1. 两指在触摸板上移动时发送像素级滚轮事件；
2. 单指落在外圈并绕圈时，按旋转角度连续发送圆周滚动；
3. 单指普通移动时驱动鼠标；
4. 触摸结束时区分滚动、滑动、轻点和双指轻点，避免一次操作重复触发多个动作。

在浏览器、文档、代码编辑器等前台应用中，生成的 `CGEvent` 滚轮事件可以滚动页面。需要注意：

- 必须授权辅助功能；按键/HID 还需要输入监控；
- 依赖私有 `MultitouchSupport`，不是受 Apple 保证的公开 API；
- 只应承诺第三代 USB-C Siri Remote，其他代际需要单独硬件验证；
- 必须在本项目正式签名、公证的 macOS 14 至 macOS 26 构建矩阵上验证触摸回调不会被 Hardened Runtime 杀死；
- 需要实测触摸睡眠、唤醒、重连、点击环和触摸同时到达时的抑制策略。

## 其他 GitHub 项目研究

| 项目 | 平台与价值 | 麦克风结论 | 对本项目的意义 |
| --- | --- | --- | --- |
| [wongsiufool/wand](https://github.com/wongsiufool/wand/tree/e5bbbec5f5c25e7a443ed79b70e345cef4ed50c8) | macOS，按键、鼠标、点击、滚动、映射；MIT | 不支持遥控器麦克风 | 适合作为较小的触摸/按键实现参考。`v0.2.0` DMG 已验证 Developer ID + Hardened Runtime + 公证，但源码仍有触摸硬件验证不足的注释，必须自行实测 |
| [ahmedalqamzi/siri-remote-steamos](https://github.com/ahmedalqamzi/siri-remote-steamos/tree/2dbf7e7e7f503a52c88a4f3c4c193dc0b782f28d) | SteamOS 3 x86_64，Rust/BlueZ/PipeWire，虚拟 Xbox 控制器和 GTK 安装器 | 直接 BLE HID → Opus → PipeWire；Release 和校验和有效 | 协议参考价值高，但必须禁用 BlueZ `input`/`hog`，会影响其他蓝牙 HID；Linux 安装层不能用于 macOS |
| [mkliu/SiriRemoteVibe](https://github.com/mkliu/SiriRemoteVibe/tree/187e1eeeea5c8ae02c3e08a2b85040b0f3c9e6c8) | macOS，直接继承 SiriRemoteForge，再增加 Fn 和 Vibe Coding 配置 | 继承 Forge 的 PacketLogger/HAL 路径；衍生 HAL 改动只有离线测试，没有 Release 或新实机证据 | 不建议替代上游。绿色 CI 只测 core 和 App 编译，不覆盖麦克风组件；完整差异见 [候选项目对比](candidate-comparison.md) |
| [azais-corentin/siri-remote](https://github.com/azais-corentin/siri-remote/tree/b165251ec50e7699064e586bc39957ec6702c52f) | Linux + BlueZ + PipeWire；第三代遥控器协议最完整的公开参考之一 | 直接 BLE HID → Opus → PipeWire Audio/Source，支持按住 Siri 键录音 | 强协议佐证，但 Linux 能绕开 HOGP owner；不能直接推导 macOS 普通 App 也能访问同样 GATT 特征 |
| [Jakkumn/SiriRemoteESP](https://github.com/Jakkumn/SiriRemoteESP/tree/b0c6b132f7709c7060ad061ea0ddc1d5c97fb88b) | ESP32-S3 / ESPHome / Home Assistant，按钮、触摸、语音 | ESP32 直接 BLE，设备端 Opus 解码，已声称端到端验证 | 可作为绕开 macOS HID 所有权的硬件 sidecar 方案，但会增加外部硬件和网络链路，不适合当前一体化安装目标 |
| [henaxxx/a2854-siri-remote-linux](https://github.com/henaxxx/a2854-siri-remote-linux/tree/a1b1062075b325191abdd0532a6922e8b04e0767) | Linux 抓包、Opus、WAV/Whisper | `btmon`/HCI 数据提取后解码 | 再次证明 A2854 音频协议可解；对 macOS 的公开 API 限制没有直接帮助 |
| [Jack-R1/SiriRemoteVoiceDecoder](https://github.com/Jack-R1/SiriRemoteVoiceDecoder/tree/1b53f5e09ad4d8d0a031a554dbc9d3cce6b074b3) | 较早的 macOS PacketLogger 解码 PoC | 明确说明 macOS 保护 HID UUID，需要 PacketLogger + sudo，把语音解码为 WAV | 与 SiriRemoteForge 的 PacketLogger 方向互相佐证，但年代较早，不能直接作为现代 macOS 产品代码 |
| [mmmmmmarcus/VibeRemote](https://github.com/mmmmmmarcus/VibeRemote/tree/0f010d92ea7721fd8e10ff705b0524516f12841e) | macOS 菜单栏、按键映射，README 声称可直接读取 audio HID 并输出 BlackHole | 声称不需要 PacketLogger/root，但项目也标为 experimental | 该声称与 SiriRemoteForge 的完整实验记录及独立负面研究冲突；在没有可重复实机证据前不能作为产品可行性依据 |
| [NSEvent/xbox-controller-mapper 的研究记录](https://github.com/NSEvent/xbox-controller-mapper/blob/440517eeb142470bd8d2d80831d583e5fe4b88b3/XboxControllerMapper/Docs/apple-tv-remote-mic-research.md) | macOS IOHID/CoreBluetooth 实验 | 能写 `0xAF`，但 IOHID 收不到音频；CoreBluetooth 不暴露已被系统 HID 栈占用的 `0x1812` | 独立支持“普通 macOS App 不能可靠直读 A2854 麦克风”的判断 |
| [agg23/SiriHIDRemote](https://github.com/agg23/SiriHIDRemote/tree/c343912fb44c87daea9ae1649b3575189316d9be) | 早期 macOS 按键可视化 | 触摸和麦克风仍标为 in progress | 只能作为历史 HID 参考，不满足当前目标 |

注：`VibeRemote` 链接中的仓库所有者拼写为 `mmmmmmarcus`；其“直接 audio HID”路径需要单独硬件复现。研究时不应因为 README 声明了功能就认为该功能已被证明。

## 为什么普通 macOS App 不能直接照搬 Linux 麦克风实现

综合 SiriRemoteForge 的 [`docs/mic-reverse-engineering.md`](https://github.com/HOLODATA-COM/SiriRemoteForge/blob/10581a960f0738e36516defb79db24b18df214d3/docs/mic-reverse-engineering.md)、Linux 实现和独立 macOS 研究：

- macOS 的 `AppleEmbeddedBluetoothAudio` / `AppleBluetoothRemote` 已接管相关 HID 接口；
- CoreBluetooth 不向第三方应用公开系统接管的 HID-over-GATT `0x1812` 服务；
- IOHID 可以看到部分虚拟接口并执行某些 feature write，但成功返回不代表写到了 Linux 项目使用的原始 GATT Report characteristic；
- 已验证的 IOHID 实验中，按住 Siri 键仍没有音频报告到达用户态 callback；
- DriverKit 替换路径需要受限制的 HID transport entitlement 和合适签名，SiriRemoteForge 已放弃该产品路线；
- PacketLogger/HCI 捕获绕过的是“公开 API 不暴露原始 GATT”的边界，因此目前是公开项目中在纯 macOS 上有完整实机证据的路线。

所以，不能设计成：

```text
普通 Remote Mic.app
→ CoreBluetooth/IOHID
→ 直接收到 0xFA
→ Opus 解码
```

除非未来 macOS 改变公开 API，或者本项目取得普通开发者无法获得的受限 entitlement。

## 签名、公证和发布风险

### 已确认的冲突

- 当前无线麦要求主 App、嵌套 Sparkle 组件、HAL、PKG 和 DMG 通过 Developer ID、Hardened Runtime 和公证验证。
- SiriRemoteForge 明确记录：其 `MultitouchSupport` 回调在 Hardened Runtime 下会触发代码签名 enforcement，触摸时进程被杀，因此上游采用非 Hardened Runtime 和 ad-hoc/本地签名。
- 上游 Full Setup 还包含 root daemon、router 和 HAL；每个组件都必须有明确的签名和公证边界，不能只签主 App。
- SiriRemoteForge 明确不在公开 Release 中捆绑 PacketLogger；本项目不能假定拥有 Apple 工具的再分发权，应要求用户从 Apple 官方渠道单独安装。

### 仍需验证的机会

- Wand 的公开 `v0.2.0` 证明 Apple 公证服务能够接受一个链接 `MultitouchSupport`、带 Hardened Runtime 的应用；这说明“私有框架一定无法公证”不是绝对结论。
- 但公证成功不等于触摸回调在所有机器和系统版本上运行成功。SiriRemoteForge 和 Wand 的运行时结论不一致，应以本项目 macOS 14 与 macOS 26 + A2854 的签名产物实测为准。
- 若主 App 的 Hardened Runtime 与触摸回调确实冲突，可以评估把触摸采集隔离到独立进程，但这会新增 IPC、签名、TCC 归属和生命周期复杂度，不能在没有验证前承诺可行。

## 许可和再分发

- 当前项目是 `GPL-3.0-only`；SiriRemoteForge 的 `NOTICE` 明确采用 GPL v3 或后续版本。两者可以按 GPL v3 组合，但未来若复制或改造其代码，仍需要保留版权、许可证、NOTICE、其继承的 MIT 声明和对应源代码义务。
- Wand 是 MIT，可作为触摸实现的另一参考；使用其代码仍需保留 MIT 版权和许可文本。
- Opus 使用 BSD 许可；若静态链接，应像 SiriRemoteForge 一样保留二进制分发许可声明。
- Apple PacketLogger 由 Apple 单独分发；不能因为本项目和 SiriRemoteForge 是开源项目就推定可以把它复制进公开 Release。
- 私有框架、HCI 调试和逆向协议存在平台兼容与分发风险；以上不是法律意见，正式发布前仍应做许可证和 Apple 协议审查。

## 推荐实施顺序

### 阶段 1：只支持 Apple Remote 按键

- 仅识别第三代 USB-C Siri Remote；
- 复用现有上层动作执行和设置体验；
- 严格按 Vendor/Product/usage 过滤，避免 HID seize 影响其他 Apple 设备；
- 验证配对、睡眠、唤醒、断线、重连和系统原生媒体键冲突；
- 不引入 PacketLogger、私有触摸和麦克风组件。

### 阶段 2：触摸与页面滚动

- 在独立实验构建中验证 `MultitouchSupport` 触摸帧；
- 同时验证本地开发签名、Developer ID + Hardened Runtime、公证后三种产物；
- 先支持鼠标移动、双指滚动和点击，再决定是否加入圆周滚动、拖拽和手势；
- 只有通过 macOS 14 与 macOS 26 + A2854 实机稳定性测试后，才写入正式功能承诺。

### 阶段 3：独立评估麦克风

- 要求用户单独安装 PacketLogger；
- 先做有界、可清理的 HCI 捕获和 Opus 解码验证；
- 优先评估把 PCM 送入现有 `MiRemoteV 2ch`，避免立即安装第二个 HAL；
- 记录 HCI 临时文件的权限、大小、清理时间和崩溃恢复；
- 验证语音延迟、丢包、时钟漂移、重连和长时间运行；
- 验证 PacketLogger 缺失或 macOS 更新后，按键/触摸仍能正常降级。

### 阶段 4：产品化系统组件

- 决定继续复用 `MiRemoteV 2ch`，还是提供独立 `Siri Remote Mic`；
- 为 root helper、router、HAL、PKG、DMG 建立完整签名、公证和安装后验证；
- 提供 HCI 设置备份/恢复、卸载器、安装 watchdog 和失败回滚；
- 明确 Sparkle 只更新 App，系统组件由 PKG 版本管理；
- 在多台 Mac、覆盖 macOS 14 至 macOS 26 的代表性系统版本和多个 A2854 固件上完成硬件验收。

## 尚未解决的问题

1. SiriRemoteForge 的触摸回调为何在其 Hardened Runtime 构建中被杀，而 Wand 的公证产物仍启用了 Hardened Runtime；两者在编译、签名或调用方式上的差异尚未定位。
2. Wand 的触摸功能在公开源码中存在硬件验证不足的注释，不能用 README 或签名结果代替实机验收。
3. PacketLogger 和 `/Library/Preferences/com.apple.MobileBluetooth.debug` 的行为是否在 macOS 14 至 macOS 26 的受支持系统范围内一致。
4. HCI 捕获会包含同一蓝牙控制器上的其他通信；应如何最小化捕获、限制文件权限并及时删除。
5. Apple Remote 语音帧在不同固件、不同连接 handle 和断线重连后的识别稳定性。
6. 复用 `MiRemoteV 2ch` 时，root capture helper 与用户会话 App 之间的 IPC、安全和生命周期设计。
7. 若保留 built-in mic fallback，麦克风 TCC 的首次授权、拒绝、撤销和多用户行为。
8. 系统里同时存在 `MiRemoteV 2ch` 与 `Siri Remote Mic` 时，豆包、系统听写和其他语音应用的设备枚举体验。

## 最终建议

**最终选择：以 SiriRemoteForge 作为 Apple Remote 集成的总体源码基线。**

Wand、siri-remote-steamos 和 SiriRemoteVibe 的逐项源码、Release、测试和安装核验见 [三项目深度对比与最终选型](candidate-comparison.md)。可以把 SiriRemoteForge 视为：

- **Apple Remote 按键与触摸能力的重要实现参考；**
- **目前公开项目中纯 macOS A2854 麦克风链路最完整的实机证据之一；**
- **但不是可以无成本嵌入当前无线麦的普通 Swift 模块。**

产品决策上，建议把“支持苹果遥控器”拆成三个独立可交付能力：

1. Apple Remote 按键；
2. Apple Remote 触摸/滚动；
3. Apple Remote 麦克风高级组件。

前两项可以保持接近现有应用的用户体验；第三项必须明确标为高级、实验性、需要管理员和 Apple PacketLogger 的功能，直到安装、隐私、签名、公证和跨版本稳定性全部通过本项目实机验证。
