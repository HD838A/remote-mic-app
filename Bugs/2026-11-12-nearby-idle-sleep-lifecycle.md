# 附近连接空闲等待未随系统睡眠暂停

- 状态为候选，真实睡眠与 iPhone / Watch 验收待完成。
- 范围为 Mac 端已主动开启、没有客户端和在途语音的附近连接等待。
- 现场反馈包含周期性网络 DarkWake。本记录只确认附近服务生命周期缺口，现场唤醒归因仍待验证。

## 证据与根因

开发基线为 `9f384bf93185007cead692b6f1f02004e5842ca1`。

`BridgeAppModel.enablePhoneRemoteConnection()` 启动附近手机与 Watch 服务。用户取消或 App 退出时才调用停止接口。`handleSystemAudioLifecycle()` 已接收系统睡眠通知，但只处理蓝牙与音频，没有暂停空闲的附近服务。

修复前对生产睡眠处理器执行源码断言，检查音频提前返回前是否存在附近资源更新。结果为失败，信息为 `REGRESSION: system sleep does not reconcile nearby network services before audio guards`。修复后的同一检查与长期回归一起验证。

缺少现场应用日志、数据包归属和精确源码身份。本机未复现反馈中的网络唤醒，因此不能把这个生命周期缺口写成周期性唤醒的已确认根因。

## 修复

- 用户开启意图与附近服务运行状态分离。
- 系统睡眠时暂停空闲等待，同时调用手机和 Watch 服务的停止接口。
- 已有连接、待开始语音和尾音排空保留原生命周期。最后一个客户端断开且语音排空后，重新判断是否暂停。
- 唤醒只恢复此前仍启用的服务。睡眠期间取消、退出或失去权益后，保持关闭。
- 屏幕休眠和会话锁定沿用原连接行为。
- 主线程投递按代次过滤旧状态、二维码、按键、语音和音频回调。被丢弃的请求仍收到失败结果。
- 待授权弹窗在展示前和提交结果前校验代次。暂停时撤销旧弹窗。
- 主队列上的系统通知直接处理，避免额外 Task 延后睡眠资源清理请求。

组件启停接口异步执行。日志只记录 `phase=submitted result=start_requested|stop_requested`，不把调用返回写成传输资源已完成释放。实际资源撤销及完成时间需要现场验证。

## 验证命令

```sh
swift test --disable-keychain --filter NearbyRemoteLifecycleTests
swift test --disable-keychain --filter 'MobileVoiceLifecycleTests|BluetoothLifecycleTests|OnboardingFlowTests'
git diff --check
```

2026-11-12 本地结果如下。

- 公开构建完整 Swift Testing 1,397 项、XCTest 4 项通过。
- 公开构建定向回归 235 项通过，包含新增 14 项生命周期测试。
- 固定 2.9.0 附近组件源码集成定向回归 240 项通过，包含已有 Watch 语音旅程。
- Apple Silicon 公开 Release 构建、仓库治理、仓库边界、Markdown 文件链接及 `git diff --check` 通过。
- 同一生产接线断言在原主线失败，在当前实现通过。

新增回归覆盖默认关闭、重复睡眠/唤醒、睡眠期间启用和取消、已有连接、语音排空、旧代次、拒绝结果以及恢复后的首批有序事件。生产接线检查覆盖音频提前返回之前的资源更新。

## 真实验收边界

按 [附近移动设备测试手册](../Testing/NearbyMobileWaitingCancellation.md) 完成实际休眠、Bonjour 撤销、Watch BLE 广播停止、唤醒重连和首次语音。自动化事件回放只证明生命周期与投递顺序。

现场功耗对照须保持 Wi-Fi、供电、其他应用和睡眠条件一致。比较 App 退出、App 运行且附近关闭、附近等待开启三种状态。按完整日期窗口统计实际 Wake / DarkWake，保留背景唤醒基线。

当前变更没有新增配对超时、修改 P2P、改变协议或调整心跳。Web 会话不属于本次修复范围。
