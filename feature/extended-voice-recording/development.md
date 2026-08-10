# 开发记录

## 精确接入点

- [`Sources/RemoteMic/BluetoothVoiceSessionLeaseController.swift`](../../Sources/RemoteMic/BluetoothVoiceSessionLeaseController.swift)：封装 10 秒保活、180 秒关闭和 2 秒停止确认超时，支持确定性测试调度。
- [`Sources/RemoteMic/BridgeAppModel.swift`](../../Sources/RemoteMic/BridgeAppModel.swift)：只在已接受的物理蓝牙语音会话开始/停止、断连和 App 退出边界启动或取消租期控制；闭包固定捕获实际发声 bridge。
- [`Apps/RemoteMicIOS/Sources/RemoteControlComponents.swift`](../../Apps/RemoteMicIOS/Sources/RemoteControlComponents.swift)：加入短点按锁定与长按松手两种手势状态。
- [`Apps/RemoteMicIOS/Sources/RemoteMacConnection.swift`](../../Apps/RemoteMicIOS/Sources/RemoteMacConnection.swift)：区分“用户已经请求录音”和“麦克风真正开始”，使异步权限与启动期间也能正确停止。
- iOS 本地化和信息页：更新按钮提示及“仅在录音期间传输”的隐私说明。

`ATVVProtocol.swift`、手机与 Mac 之间的 wire message、PCM 格式和虚拟音频输出没有变化。

## 关键决策

1. 保活跟随 `activeBluetoothVoiceDeviceIdentifier`，避免双遥控器连接或手动切换页面时把 `MIC_EXTEND` 发给错误设备。
2. 保活写入失败只记录并继续尝试；连接断开由既有生命周期终止会话，避免一次瞬时写失败提前截断音频。
3. 180 秒先发送 `MIC_CLOSE`；只有真实会话仍活跃且 2 秒没有 `STREAM_STOP` 时才重连。
4. iOS 以 350ms 区分短点按和长按：按下立即启动；短点按松开后保持，长按松开后停止。

## 模拟硬件

私有 `hardware-simulation` 仓库新增 `ATVVSessionLeaseReferenceModel`。该模型明确是 ATVV 租期假设，不是 RC003 固件事实：无保活 60 秒到期，收到 `MIC_EXTEND` 后从当前时间续租 60 秒。主项目集成测试用生产协议命令驱动该模型，证明 10 秒保活策略可跨过一分钟。

## 验证状态

- Mac 租期控制器单测：通过。
- 模拟硬件与生产协议集成：通过。
- iOS 36 项测试、iPhone 12 Simulator 构建与单屏截图：通过。
- RC003 超过 60 秒真机录音：未执行。
- iOS 与真实 Mac 点按开始/再次点按停止：未执行。
