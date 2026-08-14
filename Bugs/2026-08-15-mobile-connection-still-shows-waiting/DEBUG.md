# 移动设备已连接后仍显示正在等待

- 时间：2026-08-15
- 状态：候选修复完成，等待真实 iPhone / Watch 验收
- 影响范围：Mac App“连接与语音”页的 iPhone / Apple Watch 状态与停止操作

## 复现

1. 启动 Mac App，进入“连接与语音”。
2. 点击“连接手机”或“连接 Apple Watch”开启附近监听。
3. 使用对应移动设备完成授权并成功连接。

错误结果：Mac 仍显示“正在等待手机/Watch”，按钮仍为“取消等待”。

正常边界：未连接时应显示等待；真正连接后应显示“已连接”和“取消连接”；断线但监听仍开启时应回到等待；用户取消连接后应断开会话并停止监听。

## 日志结论

本问题是可由状态绑定代码稳定复现的显示状态缺失，不依赖特定现场日志。现有日志能记录监听开启/关闭与服务发布，但没有向界面提供 iPhone、Watch 各自的已授权连接状态，因此不能仅凭监听仍开启判断客户端未连接。

## 根因假设与实验

### H1：界面把“监听开启”误当成唯一连接状态（根因）

- 观察：`SettingsView.phoneConnectionsPanel` 的状态文案、颜色和按钮只读取 `isPhoneRemoteConnectionEnabled` / `isWatchRemoteConnectionEnabled`。
- 实验：静态检查确认 `BridgeAppModel` 只有共享监听开关，没有 iPhone 或 Watch 的已连接属性。
- 结论：连接成功后监听开关仍为 `true`，所以界面必然继续显示等待。

### H2：组件已经提供连接状态，但 Mac App 未接入（否定）

- 实验：检查 `PhoneRemoteServer` 和 `WatchBluetoothRemoteServer` 的公共回调。
- 结论：组件没有连接状态回调，Mac App 无法得知授权会话何时建立或关闭。

### H3：连接成功后应关闭监听开关（否定）

- 实验：检查 `disablePhoneRemoteConnection()`；它会停止 Phone Bonjour、Watch BLE 并取消现有客户端。
- 结论：监听状态和连接状态必须分离，不能通过关闭监听表示已连接。

## 最小修复方案

1. `SayAllMacRemoteCore` 为 Phone 和 Watch 服务分别增加连接状态回调：授权并发出 ready 后报告连接，客户端关闭/退订/停止服务后报告断开。
2. `BridgeAppModel` 在主线程保存 iPhone、Watch 独立连接状态，并在用户停止附近连接时立即清空。
3. 设置页按“已连接 → 正在等待 → 尚未开启”的优先级显示；已连接时按钮为“取消连接”，继续复用现有停止方法。
4. 不修改协议、语音路由、自动监听策略、Web 会话或实体遥控器链路。

## 验证计划

- 组件测试：确认连接回调 API 与授权、关闭、停止路径绑定。
- Mac 回归：确认 iPhone/Watch 三态文案、颜色和按钮动作；等待保持橙色，真实连接使用绿色。
- 构建与测试：组件 `swift test`，Mac `swift test`、项目测试脚本和构建。
- 真机边界：自动化不能代替真实 iPhone/Watch 的系统连接与断线回调，需在用户实际测试 Mac 上验收。

## 修复

- `SayAllMacRemoteCore` 新增 Phone / Watch 独立连接状态回调，并在授权、客户端关闭、Watch 退订和服务停止路径更新状态；相同状态不会重复通知。
- `BridgeAppModel` 在主线程保存两个连接状态，App 停止或用户取消附近连接时立即清空。
- iPhone / Watch 状态分别按已连接、等待、未开启显示。真实连接使用绿色“已连接”，按钮改为“取消连接”；等待继续使用橙色和“取消等待”。
- “取消连接”复用既有 `disablePhoneRemoteConnection()`，同时断开当前会话并停止 Phone Bonjour 与 Watch BLE，没有增加自动监听或协议字段。

## 验证结果

- 私有组件：`swift test`，20 项通过。
- Mac 主仓：`swift test`，220 项、18 个 suite 通过。
- 项目自检：`./scripts/test.sh`，42 项通过并完成 Debug 构建。
- Release 编译：`swift build -c release` 通过。
- `git diff --check` 通过。
- 未执行真实 iPhone / Apple Watch 的连接、主动断线和取消连接闭环；开发代理 Mac 与用户测试 Mac 不是同一台，该部分仍需真机验收。
