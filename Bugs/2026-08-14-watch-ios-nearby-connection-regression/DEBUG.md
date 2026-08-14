# 2026-08-14 Watch 与 iPhone 附近连接回归调查

## Observations

- 用户现场为 Mac `1.8.22`、iOS `0.8.12 (6)`，问题时段为北京时间 15:50 左右，对应日志 `07:50Z`。
- iPhone 的网络路径为可用 Wi-Fi，Bonjour 浏览器进入 `ready`，但所有发现轮次均没有 `browser_results`，因此失败发生在服务发现阶段，尚未进入 TCP 或配对。
- Watch 能看到一个 `_remotemic._tcp` 服务，但接口类别为 `other`；TCP 路径为不可用，随后进入蓝牙备用链路。
- Watch 记录 `ble_fallback_start` 和 `ble_scan_start` 后，旧 TCP 连接的 `.cancelled` 被处理为连接失败，调用连接重置并停止刚开始的蓝牙扫描。
- Mac 日志只有 `PHONE REMOTE listener_ready`，没有任何 `WATCH BLE starting/state/advertising`，因此 1.8.22 没有实际启动 Watch 蓝牙服务。
- 1.8.19 与 1.8.22 的实际发布包具有相同签名主体、本地网络说明和 Bonjour 服务声明。
- `sayall-mac-remote` 中 `PhoneRemoteServer.swift` 在 1.8.19 使用的 `da7f0bc` 与 1.8.22 使用的 `9852d0f` 内容哈希相同；手机服务源码没有发生变化。
- 1.8.22 主工程的 `BridgeAppModel` 只有 `PhoneRemoteServer`，没有实例化或启动 `WatchBluetoothRemoteServer`。
- 当前 `PhoneRemoteServer` 把 `NWListener.ready` 记录成 `listener_ready`，但没有记录 Bonjour 服务是否真正完成注册，也没有在服务注册丢失或超时时自恢复。

## Hypotheses

### H1: Watch 蓝牙备用链路被旧 TCP 终止回调清理（ROOT HYPOTHESIS）

- Supports: 日志顺序为 `ble_fallback_start` → `ble_scan_start` → 旧连接 `.cancelled` → `connection_failure`；代码中的 `.cancelled` 无条件进入 `handleConnectionFailure`，该方法最终调用 `resetConnection()` 并停止蓝牙。
- Conflicts: 连接对象身份保护理论上应过滤已释放连接，但现场日志证明该终止事件仍进入失败分支，因此还需要显式的传输切换保护。
- Test: 增加纯策略测试，验证蓝牙已接管时旧 TCP 的终止事件必须被忽略；同时把旧连接引用先从当前状态中移除再取消。

### H2: Mac 1.8.22 只增加了 Watch 入口和依赖，没有启动蓝牙外围服务（ROOT HYPOTHESIS）

- Supports: 发布包包含 Watch BLE 字符串，但 1.8.22 的 `BridgeAppModel` 没有 `WatchBluetoothRemoteServer` 引用；现场没有任何 Watch BLE 运行日志。
- Conflicts: 无。
- Test: 在主工程接入服务后，构建产物启动并点击附近设备入口，日志必须出现 Watch BLE 启动、状态和广播结果。

### H3: Mac 的 TCP 端口已监听，但 Bonjour 服务没有真正发布或发布后丢失（ROOT HYPOTHESIS FOR IPHONE）

- Supports: Mac 只有 `listener_ready`，iPhone 在 Wi-Fi 正常且浏览器 ready 的情况下始终发现 0 个服务；当前实现没有观察 `serviceRegistrationUpdateHandler`。
- Conflicts: Watch 看到了一个服务，但它位于不可用的 `other` 接口，可能是旧记录或伴随链路，不能证明 Mac 当前 Wi-Fi 上的服务已发布。
- Test: 记录 Bonjour `.add/.remove`，并在监听 ready 后限定时间内没有 `.add` 时重建监听；本地集成测试必须实际浏览到服务。

### H4: 1.8.22 的签名、Info.plist 或手机服务源码发生回归

- Supports: 故障随 Mac 版本切换出现。
- Conflicts: 两个实际发布包的签名与 Bonjour/本地网络声明一致；`PhoneRemoteServer.swift` 哈希完全相同。
- Test: 已完成发布包和源码对比，本假设被否定。

### H5: iPhone 本地网络权限或 Wi-Fi 不可用

- Supports: 服务发现为 0 时这类环境问题常见。
- Conflicts: iOS 日志明确显示 Wi-Fi 路径 satisfied、Bonjour 浏览器 ready，且同一设备较早版本能发现并连接。
- Test: 已由现场路径日志否定权限未授权和 Wi-Fi 不可用；仍需在修复包上做真实设备回归。

## Experiments

- 发布包对比：1.8.19 与 1.8.22 的签名、本地网络声明、Bonjour 声明一致；H4 否定。
- 源码哈希对比：两个 Mac 版本使用的 `PhoneRemoteServer.swift` SHA-256 相同；H4 的源码回归分支否定。
- 入口检查：1.8.22 `BridgeAppModel` 不含 Watch 服务引用，而二进制包含未被调用的 BLE 实现；H2 确认。
- 状态流检查：Watch 日志与 `.cancelled → handleConnectionFailure → resetConnection → bluetooth.stop` 代码路径一致；H1 确认。

## Root Cause

1. Watch：Mac 主工程未启动 Watch 蓝牙服务；手表端从不可用 TCP 切换到蓝牙时，又错误处理旧 TCP 的终止事件，立即清理了蓝牙会话。
2. iPhone：现场能够确认 Mac 的 Bonjour 服务对 iPhone 不可见，但旧日志只证明 TCP listener ready，不能证明 Bonjour 注册成功；当前实现缺少服务注册确认与自恢复，使发布异常无法被发现或恢复。

## Fix

- `sayall-mac-remote`：Phone Bonjour 在 `serviceRegistrationUpdateHandler` 确认 `.add` 后才记为已发布；发布超时、服务被移除或 listener 失败时自动重建。Watch BLE 等待 `didAdd service` 成功后才广播，并记录服务注册与广播生命周期。
- Mac 主工程：实例化并接入 `WatchBluetoothRemoteServer`，仅在用户点击 iPhone 或 Apple Watch 连接入口后与 Phone Bonjour 一起启动；取消等待或 App 停止时同时关闭。Watch 的授权、按键阶段、语音开始/停止、压缩音频和自定义标题继续进入既有移动遥控链路。
- Watch：BLE 已接管时忽略被取消的旧 TCP 终止回调；切换传输前先移除旧 browser/connection 引用，避免旧回调重置刚启动的 BLE。

## Verification

- `sayall-mac-remote` 16 项测试通过，包含真实启动 `PhoneRemoteServer` 并等待系统回调确认 `service_published`，以及 Bonjour 发布 watchdog 与 Watch 广播时序测试。
- Mac `swift test`：218 项、18 个 suite 全部通过。
- Mac `./script/build_and_run.sh --verify`：Release APP 构建、签名与启动成功。
- 本机启动后未点击附近入口时，日志没有 Phone Bonjour 或 Watch BLE 启动记录；点击“连接 iPhone”后同时出现 `PHONE REMOTE service_published`、`WATCH BLE advertising`，`dns-sd` 在系统层发现 `_remotemic._tcp` 的 `AndyMac` 实例；取消等待后出现 `PHONE REMOTE disabled_by_user` 与 `WATCH BLE stopped`。
- iOS / Watch 全量测试 65 项通过，iOS 与 Watch Simulator 构建成功，覆盖 BLE 接管后旧 TCP `.cancelled/.failed` 不得终止当前蓝牙会话。
- 以上只能证明本机发布、模拟器和自动化边界；用户的实际 Mac、真实 iPhone 和真实 Apple Watch 连接、授权、按键与收音仍需新包验收。
