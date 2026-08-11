# 开发记录

## 精确接入点

- `Sources/RemoteMic/BluetoothVoiceSessionLeaseController.swift`：曾封装 10 秒保活、180 秒关闭和 2 秒停止确认超时；确认物理语音路径无法写出续期后已删除。
- [`Sources/RemoteMic/BridgeAppModel.swift`](../../Sources/RemoteMic/BridgeAppModel.swift)：撤回普通物理语音会话的租期控制接入，恢复只跟随真实 ATVV 开始/停止事件。
- 独立 iOS 仓库的 `Sources/RemoteControlComponents.swift`：加入短点按锁定与长按松手两种手势状态。
- 独立 iOS 仓库的 `Sources/RemoteMacConnection.swift`：区分“用户已经请求录音”和“麦克风真正开始”，使异步权限与启动期间也能正确停止。
- iOS 本地化和信息页：更新按钮提示及“仅在录音期间传输”的隐私说明。

`ATVVProtocol.swift`、手机与 Mac 之间的 wire message、PCM 格式和虚拟音频输出没有变化。

## 关键决策

1. 普通物理语音的 `startStreaming()` 不代表主机已经主动打开麦克风；不能把协议参考模型等同于真实 RC001/RC003 会话能力。
2. 2026-08-11 日志确认定时调用被 `microphoneOpened == false` 拒绝，因此删除普通会话的续期、三分钟上限和超时重连；底层命令只留给主动 `MIC_OPEN` 会话。
3. iOS 以 350ms 区分短点按和长按：按下立即启动；短点按松开后保持，长按松开后停止。
4. iOS 两种手势只负责表达用户意图，共用 `RemoteMacConnection` 的单一录音会话状态；权限等待、连接失败、断开和停止都收敛到同一清理路径，避免重复开始或界面显示仍在录音。

## 模拟硬件

私有 `hardware-simulation` 仓库曾用 `ATVVSessionLeaseReferenceModel` 验证“协议租期可以续期”的假设。真实日志证明生产普通物理语音路径没有写出该命令，因此该模型不能作为产品行为验证，主项目中的对应集成测试已删除。模拟仓库保留历史研究模型，不代表 RC003 固件结论。

## 验证状态

- Mac 普通语音租期控制器：已删除。
- 模拟租期与生产控制器集成测试：已删除，不再作为真实硬件证据。
- iOS 36 项测试、iPhone 12 Simulator 构建与单屏截图：通过。
- 撤回后的 RC001/RC003 普通语音自动化基线：主项目 189 项、项目自检 42 项、硬件模拟跨项目 16 项通过。
- RC003 超过 60 秒真机录音：未执行，问题未解决。
- iOS 与真实 Mac 点按开始/再次点按停止：未执行。
