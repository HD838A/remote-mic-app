# 升级后 Onboarding 已收到实体按键但仍显示蓝牙未连接

- 时间：2026-08-11
- 状态：已修复
- 影响范围：macOS；现场版本 `1.8.9 (101)`；此前已安装并可正常使用、升级后首次进入 Onboarding 的用户
- 功能点：首次使用设置向导、RC003 HID 按键、CoreBluetooth 语音连接恢复
- 简单描述：Bug 索引状态：候选修复完成，等待真实升级与 RC003 验收

## 原始记录

用户截图显示同一遥控器页面同时存在以下状态：

- 蓝牙状态仍为“正在查找小米遥控器”；
- 实体按键状态已显示“已收到”；
- 用户确认此时普通按键实际可用，重启无线麦后蓝牙状态恢复。

截图文件为 `802 × 614` PNG，SHA-256 为 `013efd46eada4ce07337da1b92406a11c95b3dba7b4928d0174c80791468ea47`。

## 复现

现场的精确 Sparkle 升级首次启动尚未在本机复现：本机已安装版本是 `1.8.7 (68)`，不是用户现场的 `1.8.9 (101)`。当前可稳定复现的是代码状态缺口：HID 回调可以先写入 `lastRemoteButtonPress`，而蓝牙 bridge 集合为空时调用现有 `reconnect()` 不会创建 bridge，也不会产生任何恢复动作。

错误边界：

1. HID 普通按键事件已经到达，因此按键操作和“已收到实体按键”可正常出现；
2. CoreBluetooth bridge 尚未进入 Ready，因此页面仍显示未连接；
3. 自动路径不会因按键到达而恢复；
4. bridge 尚未创建时，页面的“重新查找”同样无操作；
5. 完整重启会重新执行启动流程，所以现场重启后恢复。

## 日志检查

没有取得用户失败启动和重启成功两个时段的 `~/Library/Logs/RemoteMic/runtime.log`，本机日志也不是事故现场日志，因此无法确认首次进程中 bridge 未建立的上游原因究竟是更新进程交接竞争，还是音频初始化期间的启动延迟。

后续现场判别：

- 若失败时出现 `BLE CONNECTING` 后跟随 `BLE CONNECT TIMEOUT`，优先调查 Sparkle 更新进程与蓝牙交接；
- 若已有 `HID BUTTON`，但长期没有 `BLE CONNECTING`，优先调查蓝牙启动是否被音频初始化延迟或遗漏；
- 修复命中空 bridge 恢复分支时会记录 `BLE RECONNECT starting_missing_bridges`。

## 假设与实验

### H1：HID 与 CoreBluetooth 是独立链路，升级首次启动时 HID 可先恢复

代码确认 HID 回调直接更新 `lastRemoteButtonPress`，Onboarding 也直接订阅该值；蓝牙连接状态则只来自 bridge Ready。截图中的矛盾状态与该结构一致。

### H2：收到 HID 按键后会自动拉起或恢复蓝牙

旧实现不成立。Onboarding 只把按键加入已观察集合，没有调用恢复动作。

### H3：用户点击“重新查找”能够覆盖 bridge 尚未创建的情况

旧实现不成立。`BridgeAppModel.reconnect()` 只遍历已经存在的 bridge；当正式 bridge 和 discovery bridge 都不存在时函数直接结束。

回归测试先在旧实现上运行并失败：缺少一次性恢复策略，源码接线也没有从实体按键事件进入恢复入口。

## 根因

已确认的停滞根因是：HID 与 CoreBluetooth 状态独立，Onboarding 在收到 HID 普通按键后只更新页面状态；与此同时，`reconnect()` 在 bridge 尚未创建时是空操作。这使“按键可用但 BLE 未 Ready”的瞬态没有恢复出口，可以一直保持到 App 重启。

bridge 在用户首次升级进程中为何没有及时建立，因缺少现场日志仍未确认；本次修复不把该上游原因写成定论，也不改变共享音频或蓝牙启动顺序。

## 修复

1. `OnboardingFlowPolicy` 增加一次性恢复判定：只有已收到实体按键、BLE 未连接且本页尚未请求过恢复时才返回 true。
2. Onboarding 遥控器页在普通按键集合或最后按键更新后执行该判定，命中后只调用一次 `model.reconnect()`；重新进入本页时重置一次性标记。
3. `BridgeAppModel.reconnect()` 在运行时已启动且正式、发现 bridge 均不存在时调用 `startBluetoothConnections()`，使自动恢复和手动“重新查找”都能真正启动连接。

## 验证

- 旧实现：`swift test --filter OnboardingFlowTests` 编译失败，确认缺少 `shouldRequestRemoteReconnect`，源码接线也不具备恢复分支。
- 候选修复：同一命令 6 项通过，覆盖无按键、已经连接、已经请求、需要恢复四种策略状态，以及按键事件与空 bridge 启动分支的源码接线。
- `swift test`：194 项、20 个 suite 全部通过。
- `scripts/test.sh`：42 项项目自检通过。
- `swift build -c release`：通过。
- `scripts/build-app.sh`：通过；测试 App 的 `codesign --verify --deep --strict` 通过。
- `git diff --check`：通过。

## 验证边界

自动化只证明状态策略和生产代码接线，不能真实驱动 CoreBluetooth 回调，也不能证明 Sparkle 更新首次启动时的系统进程交接。发布预览版前仍需用此前正常使用的已安装版本升级到候选版，连接真实 RC003，在不重启 App 的情况下验证页面从“已收到按键但未连接”自动恢复为已连接，并检查普通 `STREAM_START → AUDIO → STREAM_STOP` 语音基线。
