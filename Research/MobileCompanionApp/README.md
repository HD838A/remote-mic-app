# 手机伴侣 App 可行性研究

- 研究日期：2026-08-02
- 当前项目：Remote Mic / 无线麦
- 目标：让手机替代或补充 RC003，控制 Mac 并提供按住说话的无线麦克风
- 第一阶段平台：iPhone / iPad + macOS 14 或更高版本

## 结论

**可以实现，而且非常适合作为降低专用蓝牙遥控器依赖的产品路线。**

现有 Mac App 已经具备两个最重要的下游能力：

1. `ButtonAction` 和 `KeyboardInjector` 可以执行方向键、系统音量、播放控制、自定义快捷键和打开应用；
2. `VirtualAudioOutput` 可以接收 16kHz 单声道 PCM，并把音频送入 MiRemoteV 2ch 或其他回环音频设备。

因此手机端不需要复制 Mac 的动作和虚拟声卡逻辑。它只需要承担输入端角色：显示虚拟按键、采集麦克风、与 Mac 安全配对并发送事件或音频帧。

推荐把产品拆成两个独立层级：

- **附近直连版：** 手机在 Mac 附近使用，不依赖云服务，是第一版；
- **互联网远程版：** 手机和 Mac 可以位于不同地点，需要账号、设备身份、端到端加密和中继服务，后续单独评估。

## 推荐的第一版体验

1. Mac 打开“手机伴侣”页面，显示设备名称和一次性六位配对码或二维码；
2. 手机 App 自动发现附近运行 Remote Mic 的 Mac；
3. 用户选择 Mac 并确认配对码，双方保存设备密钥；
4. 手机显示方向、确定、返回、主页、菜单、音量和语音键；
5. 点击或长按普通按键时，Mac 使用本机已有映射执行动作；
6. 按住手机语音键时开始传送麦克风音频，松开立即停止；
7. Mac 仍由用户选择 MiRemoteV 2ch 等输出设备，手机不修改系统默认麦克风。

第一版应要求手机 App 保持前台。这样连接状态、麦克风状态和停止按钮始终可见，也避免依赖受限制的 iOS 后台执行。

## 连接方案

### 推荐：Network framework + Bonjour + TLS

Mac 使用 `NWListener` 发布 Bonjour 服务，手机使用 `NWBrowser` 发现服务，再通过 `NWConnection` 建立加密连接。

Apple 官方 [`NWBrowser`](https://developer.apple.com/documentation/network/nwbrowser)文档确认它用于发现可用网络服务，并明确关联：

- `NSLocalNetworkUsageDescription`：说明为什么访问本地网络；
- `NSBonjourServices`：声明 App 要浏览的 Bonjour 服务类型。

连接参数启用 [`NWParameters.includePeerToPeer`](https://developer.apple.com/documentation/network/nwparameters/includepeertopeer)后，系统可以为连接和监听使用点对点链路技术。该 API 从 iOS 12 和 macOS 10.14 起可用。

这意味着第一版不应硬性要求手机和 Mac 连接同一个无线路由器。附近设备仍可以尝试系统提供的点对点链路；但实际发现速度、企业网络策略、个人热点和 Wi-Fi/蓝牙关闭状态仍需真机测试。

推荐一个连接承载两类消息：

- 可靠控制通道：配对、心跳、按键事件、状态和错误；
- 实时音频通道：带序号和时间戳的短音频帧，允许少量丢包，不因重传造成明显延迟。

第一版也可以全部使用一个 TLS/TCP 连接以降低开发量。16kHz、16-bit、单声道 PCM 只有约 32KB/s，附近连接完全能够承载；只有在延迟或网络抖动实测不满足时再引入 Opus 或独立 UDP/QUIC 音频通道。

### 不推荐作为新实现：Multipeer Connectivity

Apple 的 [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity)确实支持附近发现、消息、流、基础设施 Wi-Fi、点对点 Wi-Fi 和蓝牙链路，但 Apple 当前文档已经把其主要类型标记为 Deprecated。

因此它适合证明产品概念可行，不适合作为 2026 年新项目的长期基础。新实现优先使用 Network framework。

### BLE

手机模拟 BLE 外设、Mac 作为 Central 接收按键在技术上可行，但不推荐作为完整方案：

- iOS 的广播、后台和连接状态更复杂；
- 自定义 GATT 音频传输需要重新设计分包、流控和恢复；
- 手机与 Mac 已经可以通过 Network framework 获得更高带宽和更清晰的安全模型。

BLE 可以作为未来仅按键的低功耗备用模式，不作为第一版语音通道。

### 云端或互联网中继

如果手机和 Mac 不在附近、也不在同一可达网络，Bonjour 和点对点链路无法解决问题。互联网版必须增加：

- 用户账号或其他可恢复身份；
- 每台设备独立密钥和撤销机制；
- 端到端加密，服务端不能读取按键和语音内容；
- 穿透失败时的中继服务；
- 离线、弱网、重放攻击和会话劫持防护；
- 服务成本、隐私政策和滥用控制。

这些内容不会影响附近直连版的可行性，但工作量和长期运营成本明显更高，应作为独立阶段。

## 与当前代码的衔接

### 按键控制

`Sources/RemoteMic/RemoteButtons.swift` 已定义 `RemoteButton`、`ButtonAction` 以及单击、双击、长按所需的数据模型；`Sources/RemoteMic/KeyboardInjector.swift` 已完成实际动作执行。

手机端建议只发送：

```text
buttonDown(buttonID)
buttonUp(buttonID)
```

或由手机识别后发送：

```text
trigger(buttonID, singleClick | doubleClick | longPress)
```

优先推荐发送按下和松开，让 Mac 端继续统一处理手势阈值、按住重复和本机映射。这样手机与实体遥控器能保持一致行为，配置也只需维护一份。

Mac 收到事件后不应经过 `IOHIDManager`，而应进入独立的手机输入入口，最终复用现有动作执行。输入监控权限只服务实体 HID；手机动作仍可能需要辅助功能权限，因为键盘注入和操作其他 App 的系统限制没有改变。

### 手机语音

当前 RC003 音频经过 ATVV 解码后调用：

```text
BridgeAppModel → VirtualAudioOutput.enqueue(samples:)
```

手机可以直接采集并转换为 16kHz、16-bit、单声道 PCM，再将 `[Int16]` 音频帧送入同一个输出入口。这样不需要修改 MiRemoteV 2ch 驱动，也不需要让 macOS 把 iPhone 识别成新的硬件麦克风。

手机需要提供 [`NSMicrophoneUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription)，并在用户明确按住语音键后才采集。原始语音默认不落盘、不上传云端、不写入日志。

### 工程结构

当前 `Package.swift` 只声明 macOS 14，并且主 Target 中大量文件依赖 AppKit、IOKit、CoreAudio 和 Sparkle，因此不能把整个现有 Target 直接编译成 iOS App。

实现时建议：

1. 保留现有 macOS executable target；
2. 新建独立 iOS SwiftUI App target；
3. 只抽取小型跨平台协议模块，包含消息结构、版本协商、设备身份和编解码；
4. Mac 的 `KeyboardInjector`、虚拟音频、蓝牙和驱动代码继续留在 macOS target；
5. 手机 UI、麦克风采集、触觉反馈和连接生命周期留在 iOS target。

不需要为了手机 App 重构所有现有代码。

## 安全设计

手机遥控入口能触发键盘和打开应用，必须默认拒绝未配对设备。

最低要求：

- Mac 主动显示一次性配对码或二维码；
- 配对过程中验证双方看到的短码一致；
- 长期设备密钥保存在双方 Keychain；
- 每条会话使用 TLS，并防止重放旧命令；
- Mac 显示当前连接手机，支持立即断开和删除授权；
- 手机只发送协议定义的按钮 ID 和音频帧；
- 自定义快捷键仍由 Mac 本地配置，手机不能提交任意 shell 或脚本；
- 锁屏、用户切换或 Mac 睡眠后默认断开，恢复时重新认证；
- 日志不记录配对密钥、原始语音或可直接识别用户的设备标识。

## iOS 后台限制

Apple 的[后台执行时间说明](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)指出：普通 App 进入后台后通常只有约五秒完成必要任务，随后会进入 suspended 状态；后台任务只能用于完成有限工作，不能当作无限常驻机制。

因此第一版明确：

- 手机 App 在前台时提供完整遥控和语音；
- 切到后台或锁屏时停止语音并安全断开或进入可恢复状态；
- 不滥用 audio background mode 保持一个实际没有持续音频用途的网络连接；
- 锁屏按钮、Control Center 控件、Widget、Shortcuts/App Intents 作为后续独立入口研究。

## 分阶段实施

### 阶段 1：按键遥控 MVP

- iPhone/iPad SwiftUI 界面；
- Mac Bonjour 发布和手机发现；
- 配对码、TLS、Keychain 和设备撤销；
- 方向、确定、返回、主页、菜单、音量、播放控制；
- 按下/松开、重复、单击、双击和长按；
- Mac 端连接状态和权限错误提示。

工作量判断：中等。核心难点是可靠配对和生命周期，不是按键 UI。

### 阶段 2：按住说话

- iOS 麦克风权限和 `AVAudioSession`；
- 16kHz 单声道采集、分帧和发送；
- Mac 抖动缓冲、断流、会话结束和虚拟音频输出；
- 网络变化、来电、耳机切换和音频中断处理；
- 明确的录音指示、触觉反馈和松手停止。

工作量判断：中等偏多。现有虚拟音频输出可以复用，但移动端音频中断和弱网恢复必须认真验证。

### 阶段 3：产品增强

- 多台已配对 Mac 选择；
- 自定义手机布局；
- Shortcuts、Widget 或 Control Center 快捷入口；
- Android 客户端，共用同一版本化协议；
- 可选 Opus 编码；
- 可选互联网远程模式。

## 验收标准

阶段 1：

- 首次配对不超过一分钟，未经配对的手机不能执行任何动作；
- 不连接同一个无线路由器时，至少完成一组 iPhone 与 Mac 的附近点对点真机验证；
- 连续点击 500 次没有丢失、重复或顺序错误；
- 按住方向键和音量键重复节奏与实体遥控器接近；
- App 前后台切换、Wi-Fi/蓝牙切换、Mac 睡眠唤醒后可以明确恢复或提示重连；
- 删除授权后旧手机不能重新连接。

阶段 2：

- 按住后 300ms 内开始向虚拟麦克风输出有效音频；
- 松开后 200ms 内停止，不残留持续录音；
- 连续语音 10 分钟无明显累积延迟；
- 弱网下允许短暂音频丢失，但不能无限堆积或延迟播放；
- 电话、Siri、耳机切换和音频路由变化后状态一致；
- 原始语音不落盘、不进入日志、不经过云服务器。

## 最终建议

保留该 TODO，并优先做“iPhone 前台虚拟遥控器”MVP。它能以相对可控的工作量验证用户是否愿意用手机代替 RC003，而且第一阶段无需处理语音、虚拟声卡或互联网中继。

按键 MVP 成功后，再接入手机麦克风。现有 Mac 音频输出链路已经为这一步提供了良好基础，因此手机语音不是技术障碍，真正需要投入的是安全配对、连接恢复、iOS 音频生命周期和产品级隐私提示。
