# Apple Siri Remote 的 Windows 路线

- 研究日期：2026-07-31
- 当前状态：**暂停，保留备用；不属于当前 Windows 版本实施范围**
- 目标硬件：第三代 Siri Remote，USB-C，型号 A2854
- 最重要目标：遥控器麦克风；次要目标：按键、触摸鼠标与页面滚动

本文延续 [SiriRemoteForge 与无线麦集成评估](../SiriRemoteForge/README.md)，只讨论 Windows 平台差异。

> 当前 Windows 版本只考虑小米 RC003。本文不删除，作为将来重新评估 Apple Remote Windows 支持时的资料存档；目前不安排代码接入、驱动实验、硬件验收或发布工作。

## 结论摘要

1. **目前没有找到可直接用于 A2854 的成熟 Windows 软件库。** macOS 的 SiriRemoteForge、Wand、SiriRemoteVibe 依赖 IOHID、私有 MultitouchSupport、PacketLogger 和 CoreAudio HAL；SteamOS/Linux 项目依赖 BlueZ、D-Bus、PipeWire、uinput 或 btmon，均不能直接移植到 Windows。
2. **Windows 上唯一直接相关的开源内核项目是 `Jack-R1/SiriRemoteDriver`，但它不是 A2854 方案。** 它针对 Apple TV 4th Gen 遥控器和 2022 年的 Windows 蓝牙栈，通过绑定特定 USB 蓝牙适配器的 KMDF lower filter 修改 HCI/L2CAP 数据。安装说明要求手工改硬件 ID，并可能开启 test signing mode 后重启。
3. **A2854 的协议本身已经被多条独立实现证明。** 按键、触摸和 Opus 麦克风都能在 Linux、macOS 和 ESP32 上解码；未知点不是协议格式，而是 Windows 是否允许普通应用访问由 HID-over-GATT 系统驱动占用的 Report 特征。
4. **触摸滚动功能可实现。** `mobe-dev/esp32-siri-remote-receiver` 已将 Siri Remote 的单指触摸转成 USB 鼠标、双指触摸转成水平/垂直滚轮，Windows 作为标准 USB HID 主机即可使用。纯 Windows BLE 直连仍需实机验证。
5. **麦克风存在两条潜在路线。** 用户态直连路线最好，但当前无 A2854 Windows 证据；ESP32 路线已有 `Jakkumn/SiriRemoteESP` 的真机 Opus 解码和 16 kHz PCM 证据，但要成为 Windows 麦克风仍需增加 USB Audio Class 或网络 PCM 接收端。
6. **不建议从老款 Windows filter driver 直接发展正式产品。** 内核蓝牙过滤驱动影响整个适配器，涉及驱动签名、系统稳定性和其他蓝牙设备；在确认用户态路径确实被 Windows 阻断前，不应先承担这一成本。

## 为什么现有四个主要项目不能直接用于 Windows

| 项目 | 平台绑定 | Windows 可复用部分 | 不能直接复用部分 |
| --- | --- | --- | --- |
| [`HOLODATA-COM/SiriRemoteForge`](https://github.com/HOLODATA-COM/SiriRemoteForge) | macOS | 报告格式、Opus、手势和产品交互 | IOHID、MultitouchSupport、PacketLogger、HAL、LaunchDaemon |
| [`wongsiufool/wand`](https://github.com/wongsiufool/wand) | macOS | 按键/触摸映射思路 | Swift/AppKit、IOKit、私有触摸框架 |
| [`ahmedalqamzi/siri-remote-steamos`](https://github.com/ahmedalqamzi/siri-remote-steamos) | Linux/SteamOS | `0xAF` 启动、`0xFA` Opus、`0xFB` 按键、`0xFC` 触摸 | BlueZ、D-Bus、PipeWire、systemd、uinput |
| [`mkliu/SiriRemoteVibe`](https://github.com/mkliu/SiriRemoteVibe) | macOS | Forge 衍生的配置和 HAL 研究 | 同 Forge，且没有新的 Windows 证据 |

Windows 需要新的设备访问层：

```text
BluetoothLEDevice / GATT 或 Windows HID
→ 取得 0xFA / 0xFB / 0xFC 报告
→ Opus、按键、触摸共享协议层
→ WASAPI/虚拟麦克风、SendInput 鼠标滚轮
```

## Windows 旧款 Siri Remote filter driver

研究对象：[`Jack-R1/SiriRemoteDriver@8d0f310`](https://github.com/Jack-R1/SiriRemoteDriver/tree/8d0f31037289ebf38d69122016624e0a2a125774)。

### 它做了什么

- KMDF 内核 lower filter；
- INF 绑定 `USB\VID_1286&PID_2044`，实际绑定的是作者的 USB 蓝牙适配器，不是遥控器本身；
- 过滤 USB 蓝牙 HCI/L2CAP 流量；
- 把 Windows 限制的 HID 通知重定向到普通应用可订阅的 Battery Power State 特征；
- 用户态 C# 程序通过 WinRT 订阅通知并写入 `0xAF` 启动命令；
- 源码注释知道语音通知约 102 bytes，但只输出十六进制，不提供完整 Windows 虚拟麦克风产品。

### 安装代价

其 `Debug` Release 说明要求：

1. 先在 Windows 配对 Siri Remote；
2. 手工把 INF 的 USB VID/PID 改成用户蓝牙适配器；
3. 在设备管理器把驱动安装到蓝牙适配器；
4. 失败时可能开启 Windows test signing mode 并重启；
5. 卸载依赖设备管理器 Roll Back Driver。

这条路径会把整个蓝牙适配器置于自定义过滤驱动之下，风险远大于普通设备应用。

### 为什么不能作为 A2854 结论

- README 明确写 Apple TV 4th Gen Siri Remote；
- 提交和 Debug Release 来自 2022–2023 年；
- 没有 A2854、第三代 USB-C 遥控器的硬件 ID或真机记录；
- 没有现代 Windows 11、HVCI/Memory Integrity、正式驱动签名验证；
- 没有触摸到 Windows Precision Touchpad 的实现；
- 没有把 Opus 音频发布为 Windows 麦克风。

因此它只能证明“Windows 蓝牙 HID 独占问题曾经可以用内核过滤绕过”，不能证明当前目标已经可用。

## A2854 已确认的协议能力

公开的 A2854 项目相互佐证：

- [`azais-corentin/siri-remote`](https://github.com/azais-corentin/siri-remote/tree/b165251ec50e7699064e586bc39957ec6702c52f)：Linux Rust，按键、完整触摸和 PipeWire 麦克风；
- [`henaxxx/a2854-siri-remote-linux@a1b1062`](https://github.com/henaxxx/a2854-siri-remote-linux/tree/a1b1062075b325191abdd0532a6922e8b04e0767)：A2854 按键和 100-byte Opus wrapper；
- [`Jakkumn/SiriRemoteESP@b0c6b13`](https://github.com/Jakkumn/SiriRemoteESP/tree/b0c6b132f7709c7060ad061ea0ddc1d5c97fb88b)：ESP32 BLE，第三代遥控器按键、clickpad 和 on-device Opus 解码；
- [`mobe-dev/esp32-siri-remote-receiver@a1f94d8`](https://github.com/mobe-dev/esp32-siri-remote-receiver/tree/a1f94d82115150fc0a1d97034f9d2e86927d6516)：ESP32-S3 把 Siri Remote 转为 USB HID 鼠标/键盘/媒体控制。

已知报告类别：

| 报告 | 内容 | Windows 目标 |
| --- | --- | --- |
| `0xFA` | Opus 语音 | 解码为 PCM 后写虚拟麦克风 |
| `0xFB` | 按键 | 映射为键盘/媒体键 |
| `0xFC` | 触摸 | 鼠标移动、点击、滚动 |

## 纯 Windows 用户态直连路线

### 理论架构

```text
A2854
→ Windows 蓝牙配对
→ BluetoothLEDevice
→ HID service 0x1812 / Report characteristics
→ 订阅输入报告
→ 0xFB 按键 → SendInput
→ 0xFC 触摸 → 鼠标/滚轮 SendInput
→ 0xFA Opus → libopus → PCM → CABLE Input
```

### 主要未知点

Windows 的 HID-over-GATT 驱动可能已经声明并占用 HID service。公开的 Web Bluetooth 尝试 [`ba-work/apple-remote`](https://github.com/ba-work/apple-remote/tree/58baefb965686df30cf53d801d607faceedc08d1) 也明确提示 Chrome 默认 blocklist 禁止访问 HID service，必须关闭浏览器安全限制；这不是产品方案。

必须在真实 Windows 11 + A2854 上验证：

1. `BluetoothLEDevice` 能否枚举 0x1812；
2. `GetCharacteristicsAsync(Uncached)` 是否返回 Report 特征；
3. CCCD 订阅是否成功，还是 `AccessDenied` / `Unreachable`；
4. Windows HID/Raw Input 是否已经交付按键或触摸 collection；
5. 写入 `0xAF` 后是否收到 100-byte 语音报告；
6. 配对、睡眠、RPA 地址变化和重连是否稳定。

没有这组结果前，不应承诺软件直连可行。

## 触摸与页面滚动

### 功能层结论

只要能取得触摸坐标和多指状态，就可以在 Windows 实现：

- 单指移动鼠标；
- 轻触左键；
- 实体 clickpad 点击；
- 拖拽；
- 双指垂直/水平滚动；
- 单指外圈圆周滚动映射为鼠标滚轮。

Windows 可以通过 `SendInput` 发送鼠标移动、点击和 `MOUSEEVENTF_WHEEL` / `MOUSEEVENTF_HWHEEL`。普通页面、浏览器、编辑器和设置列表都能响应标准滚轮事件。

### 已有 Windows 可用证据

`mobe-dev/esp32-siri-remote-receiver` 已把触摸转换为标准 USB HID：

- one finger → mouse pointer；
- two fingers → smooth vertical/horizontal scrolling；
- touch tap / physical click → left click；
- two-finger click → right click。

它还明确指出 Windows Precision Touchpad 尚未实现，因为当前只解码最多两个触点，而真正 PTP 报告至少要满足更多触点要求。

因此结论是：

- **实现页面滚动：可以；**
- **作为标准 USB 鼠标滚轮：已有开源实现证据；**
- **作为 Windows Precision Touchpad：尚未实现；**
- **纯 Windows BLE 直连：待验证 HID service 访问。**

## 麦克风路线

### 路线 A：Windows 用户态直接取得 `0xFA`

优点：

- 不增加外置硬件；
- 可以复用 Windows RC003 的 PortAudio/VB-CABLE 产品链路；
- 不需要 macOS PacketLogger、HAL 或 LaunchDaemon。

风险：

- Windows HID 驱动可能不允许订阅原始 Report 特征；
- Raw Input/HID API 可能只交付解析后的有限 collection，不交付 100-byte 语音帧；
- 若必须使用内核过滤驱动，发布复杂度会急剧增加。

### 路线 B：ESP32 外置桥

现有项目可组合的能力：

- `Jakkumn/SiriRemoteESP`：BLE 配对、按键、触摸、Opus 解码、16 kHz S16LE mono；
- `mobe-dev/esp32-siri-remote-receiver`：USB HID 鼠标、键盘、媒体和双指滚动。

要成为 Windows 完整无线麦，还需要新增：

```text
ESP32 Opus decoder
→ 16 kHz PCM
→ USB Audio Class microphone
→ Windows 标准录音设备
```

或者：

```text
ESP32
→ Wi-Fi/USB serial PCM
→ Windows 接收程序
→ VB-CABLE
```

这不是现成仓库已有功能，而是根据两个已验证能力组合出的新产品方向。USB Audio Class 路线对 Windows 用户最自然，通常不需要为标准 USB 音频设备单独安装自定义驱动；代价是必须销售或要求用户自备 ESP32-S3，并维护固件升级和配对体验。

### 路线 C：Windows 内核蓝牙过滤驱动

只在以下条件同时成立时才值得继续：

- 用户态 WinRT/HID 明确无法取得 `0xFA`；
- ESP32 外置硬件不符合产品定位；
- 团队愿意承担 WDK、驱动签名、HVCI、蓝牙兼容、蓝屏风险和回滚支持。

不建议以 `Jack-R1/SiriRemoteDriver` 的 Debug filter 直接开始正式实现。

## 权限与安装比较

| 路线 | 管理员权限 | 驱动 | 重启 | 安全/维护风险 |
| --- | --- | --- | --- | --- |
| 用户态 WinRT + VB-CABLE | App 不需要；VB-CABLE 安装需要 | 第三方虚拟音频驱动 | 通常需要一次 | 中 |
| ESP32 USB HID + USB Audio | Windows 端通常不需要自定义驱动 | 标准类驱动 | 通常不需要 | 中，增加硬件与固件 |
| 内核蓝牙过滤 + 虚拟音频 | 必须 | 两类自定义/第三方驱动 | 可能多次 | 高 |

Windows 不需要 macOS 的输入监控、辅助功能、PacketLogger 或 HCITraces 设置；对应的新风险是 UAC、驱动签名、SmartScreen、UIPI 和安全软件。

## 推荐验证顺序

### 1. 软件直连只读取证

- Windows 11 当前稳定版；
- A2854 与两种蓝牙芯片；
- 只枚举服务、特征和通知，不安装过滤驱动；
- 记录 HRESULT、GATT status、Report UUID/handle 和真实帧长度；
- 不修改系统蓝牙驱动。

### 2. 如果能收到报告

- 先实现 `0xFB` 按键；
- 再实现 `0xFC` 标准鼠标/滚轮；
- 最后接 `0xFA` libopus → Windows RC003 已有音频输出边界；
- 不第一版自研虚拟音频驱动。

### 3. 如果用户态被拒绝

- 不立即安装 Debug filter；
- 先验证 ESP32-S3 是否能同时提供 USB HID 和 USB Audio Class；
- 根据硬件成本、延迟和用户安装体验决定是否接受外置桥；
- 只有软件-only 是不可妥协要求时，才立项正式 Windows 蓝牙过滤驱动。

## 最终结论

- **Apple Remote 触摸滚动：可实现；标准 USB HID 路线已有开源证据。**
- **Apple Remote 麦克风：协议和 ESP32 解码已验证，但纯 Windows 软件直连尚未验证。**
- **当前最佳 Windows 产品基线仍是 RC003 fork，不是 SiriRemoteForge 或旧款 SiriRemoteDriver。**
- **Apple A2854 应作为独立实验后端，先做用户态 GATT/HID 可访问性验收。**

在真实 A2854 Windows 取证完成前，不应把 Apple Remote 麦克风列入 Windows 首版承诺。
