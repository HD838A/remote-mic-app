# 权限轮询位于 HIDRemoteMonitor 实例内部，每秒产生 N 次冗余 TCC IPC

- 时间：2026-09-25
- 状态：修复已提交，本地 diff 与单文件语法已检查；本机缺少完整 Xcode，未能执行全量构建、自动化回归与真机验证，等待上游 CI 与真机验收
- 影响范围：macOS；实测环境 macOS 27.0 build 26A428（Apple Silicon，M4）+ SayAll 1.9.21 build 174；任何已连接受支持遥控器的场景，且开销随 monitor 实例数线性增长
- 功能点：HID 按键抑制的权限监控（`HIDRemoteMonitor.startPermissionMonitor`）、输入监控与辅助功能权限轮询
- 简单描述：`HIDRemoteMonitor` 在**实例内部**创建 1 Hz 权限轮询定时器，而实例按设备创建（`hidMonitors` 字典 + `discoveryHIDMonitor`），导致 `IOHIDCheckAccess` 每秒被调用「存活实例数」次；每次调用都会真实穿透到 `tccd` 产生一次 TCC IPC，实测为 2.00 次/秒即 7,200 次/小时，且完全冗余。
- 原始记录：<https://github.com/HD838A/remote-mic-app/issues/494>；本机统一日志（`log show`，「process == RemoteMic」的 `TCCAccessRequest` 活动事件）

## Observations

1. **速率为恒定 2.00 次/秒。** 在完全静默（不运行任何日志或采样命令）的 180 秒窗口内回查，得到 360 次，即 2.00 次/秒；折算 7,200 次/小时、约 172,800 次/天。
2. **全部来自主线程，且节律规整。** 60 秒样本 120 次调用全部归属 threadID `121255`（主线程）。时间序列呈固定形态——每约 998 ms 连发 2 次，两次相隔 2–3 ms：

   ```text
   00.29143 → 00.29443
   01.29241 → 01.29430
   02.29141 → 02.29448
   03.29238 → 03.29431
   04.29239 → 04.29430
   ```

   3 分钟窗口内 180/180 秒都恰好出现 2 次，无漂移、无遗漏。
3. **单个 1 Hz 定时器只产生 1 次。** 用独立探针进程复刻 `runtimePermissions` 的谓词（`IOHIDCheckAccess(...) == granted && AXIsProcessTrusted()`）并以 1 Hz 运行 10 个 tick，合计只产生 11 次 TCC 活动（首次 `AXIsProcessTrusted` 计 1 次，其后被缓存）。因此实测的「每秒 2 次」无法由单个定时器解释。

## Hypotheses

### H1：轮询位于实例内部，开销随实例数线性增长（ROOT CAUSE）

- Supports：`startPermissionMonitor()` 在每个 `HIDRemoteMonitor` 实例内各创建一个 1 Hz 重复定时器；实例容器为 `BridgeAppModel.hidMonitors: [String: HIDRemoteMonitor]`（每设备一个）加独立 `discoveryHIDMonitor`；`DispatchHIDRemoteScheduler` 默认队列为 `.main`，因此所有实例的定时器都在主线程、创建时机相近，表现为同线程、相位一致、每秒连发 N 次。`isInputMonitoringGranted` 是静态属性（进程级全局状态），实例之间的轮询完全重复。2 个存活实例恰好解释实测的 2.00 次/秒、同主线程、相隔 2–3 ms。
- Conflicts：未直接枚举运行时存活的 monitor 实例数，因此「当前为 2 个实例」是由「同线程 + 每秒恰好 2 次 + 无漂移 + 两处实例来源」推断，而非直接观测。
- Test：在实例数分别为 1、2、3 时测量每秒 TCC 次数，应呈线性；或修复后复测应降为 1 次/秒（单一订阅者时）。

### H2：`AppleSiriRemoteAdapter` 的第二个 1 Hz 定时器

- Supports：源码中确实存在第二处 1 Hz 权限轮询（`AppleSiriRemoteAdapter.startPermissionMonitor`，`repeating: 1`）。
- Conflicts：**已排除。** 安装的二进制中 `APPLE REMOTE` 相关字符串为 0 命中，`runtime.log` 中 `APPLE REMOTE` 日志条数为 0；而该 adapter 启动成功会打印 `APPLE REMOTE START phase=completed result=monitoring model=a2854`。说明该版本未编译进 Siri Remote 适配器。

### H3：更换更便宜的权限 API 即可解决

- Supports：直觉上 `CGPreflightListenEventAccess` 之类的预检 API 应当更轻。
- Conflicts：**已排除。** 探针实测（每种 API 调用 15 次，间隔 200 ms，统计该进程产生的 `TCCAccessRequest`）：

  | API | 15 次调用 → TCC 次数 |
  | --- | --- |
  | `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` | 15 |
  | `CGPreflightListenEventAccess()` | 15 |
  | `CGPreflightPostEventAccess()` | 15 |
  | `AXIsProcessTrusted()` | 1（首次后缓存） |
  | `AXIsProcessTrustedWithOptions([prompt: false])` | 1（同上） |

  所有 Input Monitoring 类查询都是每次调用一次真实 TCC IPC，换 API 无效；只能减少调用次数。

## Experiments

1. 对照实验排除观测工具影响：先确认 `TCCAccessRequest` 只在诊断命令运行期间出现；随后停止一切日志/采样命令静默 240 秒，再回查该静默窗口，仍为 2.00 次/秒。**结论：这是无线麦自身的持续行为。**
2. 取 60 秒样本的 `threadID` 与时间戳，验证节律与线程归属（见 Observations 第 2 点）。
3. 编写 5 个独立探针进程，分别以 15 次 × 200 ms 调用单一 API，对照统计 TCC 活动数（见 H3 表）。
4. 编写组合探针复刻 `runtimePermissions` 谓词并以 1 Hz 运行，得到 11 次/10 tick，证明单定时器只产生 1 次。
5. 检索安装二进制的 `APPLE REMOTE` 字符串与 `runtime.log` 中对应日志，排除 H2。
6. 全仓库定位轮询实现与实例容器（`HIDRemoteMonitor.swift:99/268/1283`、`HIDRemoteScheduler.swift:21/51`、`BridgeAppModel.swift:608-609`）。

## Root Cause

输入监控与辅助功能权限是**进程级全局状态**，但轮询位于 `HIDRemoteMonitor` **实例内部**，而实例是按设备创建的。于是每个存活实例都会创建一个 1 Hz 定时器，每秒调用一次 `IOHIDCheckAccess`；由于该 API 无缓存、每次调用都产生一次真实 TCC IPC，每秒的 TCC 访问次数等于存活实例数。所有定时器都由 `DispatchHIDRemoteScheduler` 调度到主队列，所以表现为同一线程上每秒连发 N 次、相位一致。

根因置信度：高。代码结构、调度队列、API 开销（逐项实测）与实测节律四者相互吻合。缺口在于未直接枚举运行时实例数。

## Fix

1. 新增 `Sources/RemoteMic/HIDPermissionPoll.swift`：进程级共享的权限轮询，单例持有唯一的 1 Hz 定时器，按 token 支持订阅与取消订阅；最后一个订阅者离开时停止定时器。注释中记录该决策的原因。
2. `Sources/RemoteMic/HIDRemoteMonitor.swift`：
   - 属性 `permissionMonitor: HIDRemoteScheduledTask?` 改为 `permissionPollToken: UUID?`；
   - `startPermissionMonitor()` 先调用 `stopPermissionMonitor()`（保证幂等），再向共享轮询订阅；
   - 新增 `stopPermissionMonitor()`；
   - `stop()` 中原有的两行取消逻辑改为调用 `stopPermissionMonitor()`。

`isInputMonitoringGranted` 本就是静态属性，因此把轮询提升到进程级**不改变任何行为**：检查节奏仍为 1 Hz，权限撤销的检测延迟仍为最多 1 秒，回调体（`runtimePermissionsAreValid()` → `releaseForRevokedPermissions()`）逐字未改。

## 验证

已执行：

- `git diff --check`：无空白或行尾问题。
- `swiftc -parse`：`HIDPermissionPoll.swift` 与 `HIDRemoteMonitor.swift` 退出码均为 0。
- 旧属性名 `permissionMonitor` 在 `HIDRemoteMonitor.swift` 中无残留；全仓库无对 `permissionMonitor` 的测试引用。
- 改动范围为 1 个新增文件 + 1 个文件内 3 处修改，未触碰其他文件。

未执行（受本机环境限制，须由上游 CI 或维护者补足）：

- `swift build --disable-keychain` / `swift test --disable-keychain`：本机只安装了 Command Line Tools，未安装完整 Xcode，构建会在 `KeyboardShortcutPicker.swift` 处因 `SwiftUIMacros.StateMacro` 插件缺失失败。已用 `git stash` 在纯净 `upstream/main`（`41167180f18c07758e6732c5e366018ad4d958a4`）上复现同一失败，确认是既有环境问题而非本次改动引入。
- 实测降幅：需在连接遥控器后确认速率由 2.00 次/秒降为 1.00 次/秒（单一订阅者场景）。

## 未覆盖边界

- 本修复只消除实例间的重复轮询，**保留 1 Hz 轮询机制本身**。单一订阅者时仍为 1 次/秒；若要归零需改为通知驱动（见 Issue #494 的方案 2），那属于独立工作项。
- 未直接枚举运行时 monitor 实例数，因此「线性增长」与「当前为 2 个实例」仍为推断；需要时可通过统计 `HID START` 与实例容器的生命周期确认。
- 权限撤销路径（`releaseForRevokedPermissions`）未在真机上验证：仍为 1 秒内检测，但本次未实际撤销权限以触发该分支。
- 未验证多遥控器场景下共享订阅的取消订阅时机是否有泄漏（例如实例未走 `stop()` 直接释放）。
