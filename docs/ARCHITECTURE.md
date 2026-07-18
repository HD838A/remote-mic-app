# Open Voice Bridge 架构

Open Voice Bridge（开放语音桥）面向两类外设：

1. 自带按键和私有语音协议的语音遥控器，例如 Xiaomi RC003；
2. 以系统音频设备、USB 接收器或厂商无线链路出现的无线麦克风，例如 DJI Mic 系列。

项目不会假设所有设备都使用 BLE、ATVV 或 HID。设备、传输、协议、音频和平台必须分别建模，只有经过真实平台验证的组合才能标为 `implemented`。

## 分层

```text
UI shell
  │
Application coordinator
  ├── Device adapter registry
  │     ├── Identity matcher
  │     ├── Capability declaration
  │     └── Protocol/session adapter
  ├── Transport providers
  │     ├── BLE GATT
  │     ├── Bluetooth HID
  │     ├── USB / system audio input
  │     └── Future platform-specific transports
  ├── Audio graph
  │     ├── Decode / normalize
  │     ├── gain / channel policy
  │     └── user-selected output or virtual microphone
  ├── Action mapping
  │     ├── logical button actions
  │     └── platform key / system actions
  └── Platform backend
        ├── macOS
        ├── Windows
        └── Linux
```

### 1. Device profile

`device-profiles/*.json` 是语言无关的能力与研究状态目录，格式由 `specs/device-profile.schema.json` 约束。Profile 只描述事实：身份、候选传输、能力、平台状态和证据来源；它不是驱动，也不会因为写入一个 JSON 就自动变成“已支持”。

当前 macOS 代码中的 `VoiceBridgeDeviceProfile` 是同一概念的运行时最小实现。RC003 的蓝牙名称与 HID VID/PID 已集中到一个生产 profile，避免第二个设备继续复制硬编码。

### 2. Device adapter

一个设备适配器负责：

- 精确识别目标设备，不使用容易误连的模糊品牌匹配；
- 声明其真实能力和需要的传输；
- 管理设备专属的握手、会话和控制协议；
- 把设备事件转换成统一的语音帧、按键边沿、状态或控制意图；
- 在断线、撤权、协议不匹配时失败关闭。

Xiaomi RC003 当前由 `XiaomiBluetoothBridge`、`HIDRemoteMonitor` 和 `RemoteVoiceFunctionMapper` 共同组成第一个 macOS 适配器。后续切分必须以真实第二个设备为驱动，避免为了抽象而重写已通过真机验收的路径。

### 3. Transport provider

传输提供器只负责平台 I/O，不理解具体产品业务：

- BLE GATT：扫描、连接、characteristic 读写与通知；
- Bluetooth HID：原始按键 report 与设备移除；
- USB / system audio：枚举系统已经暴露的音频输入或输出；
- 未来传输：必须先有官方资料或抓取到的真实设备证据，再加入 schema。

同一设备可以组合多条传输。RC003 使用 BLE GATT 传语音，同时使用 Bluetooth HID 传按键。无线麦克风可能通过厂商无线链路连接接收器，但在电脑端只表现为 USB 数字音频；这类设备不应被强行塞进 BLE 适配器。

### 4. Audio graph

统一音频边界使用显式格式元数据：采样率、位深、声道数、时间顺序和流代次。设备解码器输出规范化 PCM，平台音频后端再决定写入用户选择的回环设备、虚拟麦克风或其他目标。

安全门保持不变：

- 不自动修改系统默认输入/输出；
- 不上传或保存语音；
- 测试音不能阻塞真实语音；
- 新一代连接不能接受旧一代回调或音频帧。

### 5. Action mapping

设备适配器输出逻辑按钮，平台后端把逻辑动作转换为 macOS、Windows 或 Linux 的按键/系统动作。设备的物理 usage 与平台动作不得混在同一个枚举中，否则无法复用设备适配器。

RC003 的 F5→Fn 是一个明确的 macOS 平台策略，只对该设备 HID 身份生效，不属于所有语音设备的通用行为。

### 6. Platform backend

平台后端负责权限、蓝牙/HID API、音频 API、按键注入、虚拟音频选择和生命周期：

| 平台 | 当前状态 | 边界 |
| --- | --- | --- |
| macOS | RC003 已实现 | CoreBluetooth、IOHID、CoreAudio、AppKit；最低部署目标 11 |
| Windows | planned（`apps/windows/rc003/` 已有源码/构建候选，未真机验收） | 需独立验证蓝牙、Raw HID、系统音频和按键注入权限模型 |
| Linux | planned | 需独立验证 BlueZ、evdev/uhid、PipeWire/PulseAudio 与桌面会话权限 |

这里的 Windows/Linux 技术名只是候选边界，不代表已经选型或实现。

## DJI Mic 2 为什么先列为 research

DJI 官方资料说明接收器可以通过 USB-C 连接电脑；同时，发射器直接蓝牙连接的官方兼容范围列出了 Osmo Pocket 3、部分 DJI 设备和手机，没有把桌面系统列为通用直连目标。因此首个桌面研究路径应是“USB 接收器如何被各系统枚举为音频设备”，蓝牙路径必须另做真机验证，不能因为产品带蓝牙就直接套用 RC003 的 BLE GATT 模型。

官方依据：

- [DJI Mic 2 Specs](https://www.dji.com/mic-2/specs)
- [DJI Mic 2 FAQ](https://www.dji.com/mic-2/faq)
- [Osmo Pocket 3 Specs](https://www.dji.com/osmo-pocket-3/specs)

## 代码与目录演进

当前阶段保持已发布 target 不动：

```text
Sources/XiaomiRemoteBridgeMac/   # 已实现的 RC003 macOS 适配器
device-profiles/                 # 语言无关设备能力与研究状态
specs/                           # profile schema 与未来公共契约
docs/                            # 公共架构与接入说明
```

当第二个真实设备适配器进入实现后，再根据实际共享量引入：

```text
core/                            # 只有被两个实现复用的状态/音频/动作契约
devices/<device-id>/             # 设备协议与适配器
platforms/macos/
platforms/windows/
platforms/linux/
apps/<platform>/
```

在第二个实现出现前不决定共享核心必须使用 Swift、Rust、C++ 或其他语言。先用 schema 固定跨语言事实，再由真实复用与部署约束选择实现语言。

`apps/windows/rc003/` 是一个例外说明：它是**同一个设备（RC003）的第二个平台**候选，不是第二个设备适配器，因此提前以 `apps/<platform>/<device-id>/` 的形式独立落地，而不等待 `core/`/`platforms/` 抽象出现。它是纯 Python 实现，与 `Sources/XiaomiRemoteBridgeMac` 的 Swift 代码没有共享依赖；在真机验收前只是 source/build candidate，见该目录自己的 README（含"Known gaps"一节列出的真机待核验事项）。

## 兼容原则

- 总项目改名不等于立即修改已发布应用名或 Bundle ID；权限身份变化必须单独验收。
- 历史 `v0.2.0` 继续代表 Xiaomi RC003 macOS 测试版。
- 新设备必须单独标注 `research / planned / implemented / unsupported`。
- 新平台必须完成自身权限、安装、音频和真机门，不能继承 macOS PASS。
