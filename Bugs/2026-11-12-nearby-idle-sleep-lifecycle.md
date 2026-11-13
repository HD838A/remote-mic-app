# 附近连接空闲等待未随系统睡眠暂停

- 状态为候选修复，已补唤醒后自动重建；2026-11-13 build 352 真机 iPhone 自动重连、音量 +、唤醒后语音、连续三轮睡眠/唤醒和 Watch 两次回归通过；整夜功耗与实际资源撤销待验收。
- 范围为 Mac 端已主动开启、没有客户端和在途语音的附近连接等待；已有连接的睡眠/唤醒恢复也在本记录内。
- 现场反馈包含周期性网络 DarkWake。本记录只确认附近服务生命周期缺口，现场唤醒归因仍待验证。

## 证据与根因

开发基线为 `9f384bf93185007cead692b6f1f02004e5842ca1`。

`BridgeAppModel.enablePhoneRemoteConnection()` 启动附近手机与 Watch 服务。用户取消或 App 退出时才调用停止接口。`handleSystemAudioLifecycle()` 已接收系统睡眠通知，但只处理蓝牙与音频，没有暂停空闲的附近服务。

修复前对生产睡眠处理器执行源码断言，检查音频提前返回前是否存在附近资源更新。结果为失败，信息为 `REGRESSION: system sleep does not reconcile nearby network services before audio guards`。修复后的同一检查与长期回归一起验证。

缺少现场应用日志、数据包归属和精确源码身份。本机未复现反馈中的网络唤醒，因此不能把这个生命周期缺口写成周期性唤醒的已确认根因。

## 修复

- 用户开启意图与附近服务运行状态分离。
- 系统睡眠时暂停空闲等待；空闲连接在睡眠前干净关闭，让客户端收到断开，而不是留下静默死 socket。
- 睡眠时仍有语音排空则先保留服务，等排空完成后再关闭；唤醒时如果服务仍在运行，每个睡眠周期最多重建一次。重复唤醒通知不得重复重启。
- 唤醒只恢复此前仍启用的服务。睡眠期间取消、退出或失去权益后，保持关闭。
- 屏幕休眠和会话锁定沿用原连接行为。
- 主线程投递按代次过滤旧状态、二维码、按键、语音和音频回调。被丢弃的请求仍收到失败结果。
- 待授权弹窗在展示前和提交结果前校验代次。暂停时撤销旧弹窗。
- 主队列上的系统通知直接处理，避免额外 Task 延后睡眠资源清理请求。
- 附近服务停止时同步清空 `isPhoneRemoteConnected`、`isWatchRemoteConnected` 和会话状态，界面不能保留假“已连接”。

组件启停接口异步执行。日志只记录 `phase=submitted result=start_requested|stop_requested`，不把调用返回写成传输资源已完成释放。实际资源撤销及完成时间需要现场验证。

## 验证命令

```sh
swift test --disable-keychain --filter NearbyRemoteLifecycleTests
swift test --disable-keychain --filter 'MobileVoiceLifecycleTests|BluetoothLifecycleTests|OnboardingFlowTests'
git diff --check
```

2026-11-12 本地结果如下。

- 公开构建完整 Swift Testing 1,372 项、XCTest 4 项通过。
- 公开构建定向回归 235 项通过，包含新增 14 项生命周期测试。
- 固定 2.9.0 附近组件源码集成定向回归 240 项通过，包含已有 Watch 语音旅程。
- Apple Silicon 公开 Release 构建、仓库治理、仓库边界、Markdown 文件链接及 `git diff --check` 通过。
- 同一生产接线断言在原主线失败，在当前实现通过。

新增回归覆盖默认关闭、重复睡眠/唤醒、睡眠期间启用和取消、已有连接、语音排空、旧代次、拒绝结果以及恢复后的首批有序事件。生产接线检查覆盖音频提前返回之前的资源更新。

2026-11-13 真机补充：build 340 在 iPhone 已连接时进入系统睡眠，唤醒后 Mac 与 iPhone 都显示“已连接”，但 `lsof` 只剩监听端口，没有与 iPhone 的已建立连接；按音量 + 没有 `PHONE REMOTE button=volume_up` 日志。手动“取消连接 → 连接”后日志出现 `stop_requested`、`start_requested`、`trusted_identity_approved` 和音量命令，功能恢复。

根因是 `keepAlive` 让附近服务保持 `running`，但系统睡眠断开了客户端 socket，服务端没有收到断开通知；唤醒没有重启监听，`isPhoneRemoteConnected` 也没有清零，于是留下假“已连接”和失效命令通道。

修复过程：

- 第一版在唤醒后执行一次 stop/start。真机复验发现 Mac 能回到“正在等待”，但 iPhone 没有收到干净断开，不会自动重连，仍要手动连接。
- 第二版改为在睡眠前干净关闭空闲连接，让 iPhone 收到断开；唤醒后启动一次监听。若睡眠时语音仍在排空，先保留服务到排空完成，再关闭；如果唤醒时服务仍在运行，则每个睡眠周期最多重建一次。
- 附近服务停止时清空连接与会话状态，界面回到“正在等待”，不再显示假“已连接”。
- 重复唤醒通知不会重复启动/重建；每个睡眠周期最多一次。
- 空闲连接日志为 `stop_requested reason=system_will_sleep` 和 `start_requested reason=system_did_wake`；仅在语音仍在排空、唤醒后服务仍运行的路径使用 `reason=system_did_wake_restart wake_restart_attempt=1/1`。
- 新增回归覆盖空闲连接睡眠前关闭、语音排空后关闭、语音仍在时唤醒重建、重复唤醒不重复、睡眠中禁用取消，以及一个睡眠周期最多一次重启。

2026-11-13 修复后本地结果：公开完整 Swift Testing 1,372 项通过；受影响定向回归 238 项通过；`git diff --check` 通过。真机 build 352 验证：iPhone 已连接空闲睡眠时记录 `stop_requested reason=system_will_sleep`；唤醒后记录 `start_requested reason=system_did_wake`、`listener_ready`、`invitation_ready`，iPhone 自动重新连接并出现 `trusted_identity_approved`，音量 + 命令恢复；唤醒后语音、连续三轮睡眠/唤醒和 Watch 两次回归均通过。整夜功耗、实际 Bonjour/Watch 广播停止仍待验收。

2026-11-14 同步最新 `origin/main` 并生成合并提交 `6dd9da9b` 后：公开完整 Swift Testing 1,387 项、XCTest 4 项通过；受影响定向回归 240 项通过；`git diff --check` 通过。用户确认现有真机结果足够合入，剩余整夜功耗、实际 Bonjour/Watch BLE 停止、现场周期性唤醒归因和受影响引导流程截图后续补测。

该项仍保持候选：整夜功耗、实际 Bonjour/Watch 广播停止和现场周期性唤醒归因尚未完成复验；iPhone 和 Watch 的睡眠/唤醒自动重连、按键与语音已通过本轮真机验收。

## 真实验收边界

按 [附近移动设备测试手册](../Testing/NearbyMobileWaitingCancellation.md) 完成实际休眠、Bonjour 撤销、Watch BLE 广播停止、唤醒重连和首次语音。自动化事件回放只证明生命周期与投递顺序。

现场功耗对照须保持 Wi-Fi、供电、其他应用和睡眠条件一致。比较 App 退出、App 运行且附近关闭、附近等待开启三种状态。按完整日期窗口统计实际 Wake / DarkWake，保留背景唤醒基线。

当前变更没有新增配对超时、修改 P2P、改变协议或调整心跳。Web 会话不属于本次修复范围。
