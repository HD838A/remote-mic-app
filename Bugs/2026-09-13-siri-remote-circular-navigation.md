# Siri Remote 圆周导航无法切换与轻点确认缺失

## 复现

- 版本：1.9.21 (174)，现场进程 PID 71873。
- 日志：`/Users/andy/Library/Logs/RemoteMic/runtime.log`，2026-09-13 03:26:14–03:26:50 UTC。
- 操作：TV 键启动 Cmd-Tab 后在触摸面外圈顺/逆时针旋转；随后在当前选项上静止轻点，不按实体确定键。
- 实际：日志显示圆周事件不断提交，但无法确认系统实际切换；静止轻点没有进入 AppSwitcher 确认。

## 日志证据

现场已有 `APPLE REMOTE TOUCH_CONTEXT ... result=submitted` 和实体 `select` 的确认结束记录，但没有记录：

- AppSwitcher 会话起始/结束时的前台 Bundle ID；
- 每个 Command、Tab、左右选择事件的真实投递结果；
- 确认后前台应用是否变化。

私有触摸解释器在 `circular_navigation` 模式下原先只允许 `.scroll`，`.click` 在结束时被条件直接屏蔽，因此轻点缺少任何宿主回调。

## 根因

1. Siri Remote AppSwitcher 只复用了按键投递，不复用 RC003 已有的前台变化监测与确认后探针；`success=true` 仅表示 `CGEvent.post` 调用链返回，不能证明系统接受了导航。
2. 圆周模式结束触摸时强制要求 `routingMode == .standard`，静止轻点被丢弃。

## 修复

- 私有适配器在圆周模式保留静止轻点输出，并新增 `onCenterTapConfirmation` 回调；圆周模式下轻点不再发送鼠标点击。
- 公开宿主将该回调接入 AppSwitcher：活动会话中轻点确认当前选择，普通模式仍执行现有悬停目标点击。
- Siri Remote AppSwitcher 增加会话起始前台、前台变化监测、确认后延迟探针和 Command 释放结果日志。
- `KeyboardInjector.AppSwitcherSession` 增加按键角色、键码、边沿、Command 修饰状态和投递结果的脱敏事件日志。

## 验证

- 私有 Siri Remote 包：`swift test --disable-keychain`，65 项通过。
- 公开宿主：`swift test --disable-keychain`，504 项通过。
- 自动化覆盖：圆周旋转方向映射、圆周模式静止轻点输出、轻点确认接线、AppSwitcher 生命周期日志存在性。

## 真机边界

本轮未在用户现场复测 macOS Cmd-Tab UI；必须使用真实 A2540/A2854 完成：顺/逆时针切换、圆周轻点确认、实体确定/返回、超时、断连，并核对同一 `operation_id` 的可见性探针和唯一终态。自动化中的 `success=true` 仍不能替代系统前台变化与屏幕窗口可见性验收。

## 后续现场回归：多轮后失效与微信窗口未显示

### 复现与证据

- 用户随后在当前 Mac 真实复现：圆周导航开始时可用，多轮后再次失效；微信无论使用圆周触摸还是实体方向/确定键导航，都没有真正显示窗口。
- 对应现场进程为 `1.9.21 (174)`、PID `15341`，约在 2026-09-13 08:03 UTC。日志存在多轮 `phase=start`、触摸导航提交、`phase=ended command_release=true`，并出现 `selected=com.tencent.xinWeChat`。
- 上述日志只能证明 CGEvent 提交和 `NSWorkspace.frontmostApplication` 的一次 Bundle ID 观察，不能证明微信有屏幕上普通窗口；本机微信进程此前已长期存在，进程存在也不能证明窗口已经打开。
- 因现场日志缺少跨轮关联、状态聚合和窗口可见性，这一后续问题当前根因仍未确认。不得沿用前一问题的“圆周轻点被屏蔽”根因，也不得把微信误解释为某个自定义按键动作。

### 本轮诊断补充

- 每轮 Siri Remote AppSwitcher 从首次 TV 开始生成进程内递增 `operation_id`；启动、继续 Tab、圆周导航、实体左右、触摸/实体确认、取消、超时、Command 释放、可见性探针和终态使用同一 ID。
- 结束时聚合记录 Tab 次数、圆周导航步数、实体左右次数、触摸/实体确认次数、耗时以及会话结束前后 active 状态，避免新增逐触摸帧日志。
- 确认后在 0、150、500、1000 ms 做有限探针，记录前台 Bundle ID、目标进程 active/hidden/terminated、激活策略、普通窗口数和屏幕上普通窗口数。
- 窗口统计只使用公开 `CGWindowListCopyWindowInfo`，按目标 PID、layer 0 和正面积计数；不读取或记录窗口标题、内容、路径、设备标识和用户输入。
- 每轮最终只给出一个诊断终态：`visible_target_confirmed`、`frontmost_changed_no_visible_window`、`frontmost_unchanged`、`cancelled`、`timed_out`、`submission_failed` 或 `diagnostic_unknown`。该终态用于定位，不改变系统 AppSwitcher 或 App 激活行为。

### 待真机复测

使用新日志版本连续执行至少 10 轮，并让微信分别处于未运行、后台有窗口、后台无普通窗口/已隐藏三种公开状态。出现用户可见失败时，保留完整 `operation_id` 链；只有新日志能够稳定区分会话状态、系统未接受、无可见窗口或前台被抢回后，才能确认根因并开始行为修复。

### 自动化验证

- 社区构建 `swift test --disable-keychain`：506 项、40 个 suite 全部通过。
- 启用私有 Siri Remote Package 的完整集成测试：543 项、44 个 suite 全部通过。
- 自动化验证了窗口过滤、active/hidden/terminated 与屏幕窗口组合判定、0/150/500/1000 ms 探针配置、日志字段接线和不读取 `kCGWindowName`。真实 Siri Remote、多轮 Cmd-Tab 和微信窗口显示仍未复测，根因保持未确认。
