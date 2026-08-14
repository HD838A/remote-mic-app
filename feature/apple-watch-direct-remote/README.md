# Apple Watch 直连遥控与收音

## 为什么开发

Apple Watch App 已能发起附近连接，但 Mac `1.8.14` 只有“连接手机”入口，用户无法明确开启 Watch 等待，也容易把连接状态误判为 iPhone 专用。

## 用户功能介绍

Mac `1.8.15` 的连接页按 iPhone、Apple Watch、网页版排列。点击“连接 Apple Watch”后，Watch 可直接发现 Mac、完成两位码授权，并复用现有遥控按键、手势映射和移动麦克风音频链路。

iPhone 与 Watch 共用一次附近等待。任一入口开启后都能接受两类设备；等待期间可以取消，取消会停止监听并释放候选和旧会话。

## 范围与非目标

- 增加 Mac 的 Apple Watch 专用入口、状态和中英文说明。
- 根据设备名称为 Watch 显示专用授权说明。
- 使用 `SayAllMacRemoteCore` 和 `SayAllMacRemoteUI` 承载附近连接、Web 会话核心与 UI，删除主仓库内重复实现。
- 保持 Mac 启动不自动监听；当前仍只保留一个附近客户端，网页版继续使用独立会话。
- 本次不修改 Watch App，不增加多客户端并发，也不实现跨互联网 Watch 控制。

## 隐私与兼容边界

Watch 音频只进入现有 Mac 移动语音链路，不由该组件持久化。长期信任沿用现有设备身份记录，用户可以在 Mac 清除。组件 revision 固定为 `dc8a728fd51473d1e08a4b88639175f1cdd7c105`；协议字段和既有 iPhone/Web 行为保持兼容。Mac 只在用户开启附近连接后启动 Watch 蓝牙服务，并确认 Bonjour 服务真正发布；发布超时或被移除时会自动恢复，不再只依赖端口监听状态。

## 涉及文件

- `Package.swift`、`Package.resolved`：固定组件依赖和产品。
- `Sources/RemoteMic/BridgeAppModel.swift`：组件适配、共享 Watch 状态、授权说明和按键类型映射。
- `Sources/RemoteMic/SettingsView.swift`：Watch 专用入口和组件 Web 会话视图。
- `Resources/*/Localizable.strings`、`Resources/Info.plist`：入口文案和本地网络用途。
- `Tests/RemoteMicTests/SettingsPageRegressionTests.swift`：入口顺序、按需监听和状态回归。

## 当前状态与限制

状态：候选代码完成，等待真机验收。自动化和构建结果记录在 [testing.md](testing.md)，人工步骤见 [Testing/AppleWatchDirectRemote.md](../../Testing/AppleWatchDirectRemote.md)。真实 Watch 的附近发现、授权、按键和收音尚不能由本机自动化替代。
