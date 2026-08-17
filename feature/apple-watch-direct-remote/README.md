# Apple Watch 直连遥控与收音

## 为什么开发

Apple Watch App 已能发起附近连接，但 Mac `1.8.14` 只有“连接手机”入口，用户无法明确开启 Watch 等待，也容易把连接状态误判为 iPhone 专用。

## 用户功能介绍

Mac `1.8.15` 的连接页按 iPhone、Apple Watch、网页版排列。点击“连接 Apple Watch”后，Watch 可直接发现 Mac、完成两位码授权，并复用现有遥控按键、手势映射和移动麦克风音频链路。

iPhone 与 Watch 共用一次附近等待。任一入口开启后都能接受两类设备；等待期间可以取消。对应设备成功授权后显示“已连接”和“取消连接”；取消会断开会话、停止监听并释放候选和旧会话。

## 范围与非目标

- 增加 Mac 的 Apple Watch 专用入口、状态和中英文说明。
- 根据设备名称为 Watch 显示专用授权说明。
- 使用 `SayAllMacRemoteCore` 和 `SayAllMacRemoteUI` 承载附近连接、Web 会话核心与 UI，删除主仓库内重复实现。
- 保持 Mac 启动不自动监听；当前仍只保留一个附近客户端，网页版继续使用独立会话。iPhone、Watch 和 Web 的语音会话分别标记来源，非当前来源的延迟音频或停止不会污染当前会话。
- 本次不修改 Watch App，不增加多客户端并发，也不实现跨互联网 Watch 控制。

## 隐私与兼容边界

Watch 音频只进入现有 Mac 移动语音链路，不由该组件持久化。长期信任沿用现有设备身份记录，用户可以在 Mac 清除。组件固定到已合入私有仓库主分支的 revision；新增的连接状态、语音开始结果和 `voiceReadyV1` 均保持可选与旧版兼容，既有 iPhone/Web 行为不变。Mac 只在用户开启附近连接后启动 Watch 蓝牙服务，并确认 Bonjour 服务真正发布；发布超时或被移除时会自动恢复，不再只依赖端口监听状态。Watch 蓝牙关闭或异常失去可用状态时会清理授权、连接和语音占用，避免界面残留“已连接”或继续阻塞 iPhone 语音。Mac 只在虚拟麦克风与系统语音键准备成功后通知新版 Watch 开始采集，避免首批音频提前到达被丢弃。

## 涉及文件

- `Package.swift`、`Package.resolved`：固定组件依赖和产品。
- `Sources/RemoteMic/BridgeAppModel.swift`：组件适配、iPhone/Watch 独立连接状态、授权说明和按键类型映射。
- `Sources/RemoteMic/SettingsView.swift`：Watch 专用入口、附近连接三态和组件 Web 会话视图。
- `Resources/*/Localizable.strings`、`Resources/Info.plist`：入口文案和本地网络用途。
- `Tests/RemoteMicTests/SettingsPageRegressionTests.swift`：入口顺序、按需监听和状态回归。
- `Tests/RemoteMicTests/WatchBluetoothVoiceJourneyTests.swift`：首次语音从 Mac 准备完成到 `voiceReady` 的跨组件回归。

## 当前状态与限制

状态：候选代码完成，已补充 iPhone/Watch 语音来源隔离、占用错误分类、移动语音诊断日志和 `voiceReadyV1` 首句就绪握手，等待真机验收。自动化和构建结果记录在 [testing.md](testing.md)，人工步骤见 [Testing/AppleWatchDirectRemote.md](../../Testing/AppleWatchDirectRemote.md)。真实 Watch 的附近发现、授权、按键、BLE 实时收音、首句听感和停止后切换 iPhone 尚不能由本机自动化替代。
