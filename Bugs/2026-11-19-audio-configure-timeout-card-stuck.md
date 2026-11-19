# 虚拟音频启动阻塞导致遥控器卡片长期“状态确认中”

- 时间：2026-11-19
- 状态：候选修复；自动化通过，等待真实虚拟声卡、遥控器和第三方语音工具验收
- 影响范围：macOS；使用 SayAll 虚拟音频输出的遥控器语音用户；App 退出后重新启动、虚拟设备重新枚举或 Core Audio 短暂卡住时
- 功能点：`VirtualAudioOutput` 配置队列、`AVAudioEngine` 启动、遥控器卡片语音就绪判定
- 简单描述：遥控器蓝牙和 HID 按键已经可用，但卡片持续显示“状态确认中”；日志显示第二次启动的音频输出配置停在 `prepare_engine`，后续所有配置请求都排在被阻塞的串行队列后面，直到完全退出 App 重开。

## 现场证据

用户提供两份加密 `.rmlog` 和一张生产界面截图；截图只作为外部现场证据，图片字节不入仓库。日志按受控流程解密，以下时间同时给出日志 UTC 和截图所在时区 UTC+8。

版本与环境：

- App `2.0.9 (408)`，公开构建通道，私有平台 `2.12.5`。
- 截图显示“小米蓝牙遥控器 2 Pro”和“苹果遥控器 Lightning”均显示“状态确认中”，Chromecast 显示“未连接”。
- 用户确认普通按键已经可用；完全退出 App 后重新打开，卡片恢复。

### 第一次运行：音频输出正常

`12:36:30`（`04:36:30Z`）启动后，`SayAll` 输出在 78 ms 内完成配置：

```text
AUDIO CONFIGURE operation_id=1 phase=completed result=ready reason=ready status_key=audio.output.current_format
AUDIO REBIND finished reason=startup success=true status=audio.output.current_format
```

`12:38:43`（`04:38:43Z`）苹果遥控器语音实际开始采集，`12:38:52` 正常停止并记录尾音排空：

```text
APPLE REMOTE AUDIO capture=started source=apple_remote_microphone
APPLE REMOTE AUDIO capture_stop phase=completed result=tail_settled completion=normal
APPLE REMOTE AUDIO playback_stop phase=completed result=completed completion=normal
```

`12:39:33`（`04:39:33Z`）用户退出 App，日志记录 `APP STOP`。

### 第二次运行：音频队列停止推进

`12:40:09`（`04:40:09Z`）重新启动，`12:40:10` 开始配置新的 `SayAll` 设备实例：

```text
AUDIO CONFIGURE operation_id=1 phase=started result=pending queue_wait_ms=0
AUDIO CONFIGURE operation_id=1 phase=applying result=pending stage=select_device
AUDIO CONFIGURE operation_id=1 phase=applying result=pending stage=prepare_engine
```

此后到截图和日志结束，没有出现：

- `stage=start_engine`
- `AUDIO READY`
- `AUDIO CONFIGURE phase=completed`
- `AUDIO REBIND finished`

后续 `12:41:05`、`12:41:25`、`12:41:54`（`04:41:05Z`、`04:41:25Z`、`04:41:54Z`）的配置请求只有 `phase=requested`，没有 `phase=started`。这说明串行 `engineQueue` 仍卡在第一次配置中，后面的请求全部排队。

同一段时间遥控器本身仍在工作：

- `12:40:18`–`12:40:24`：小米遥控器音量键事件连续到达并执行。
- `12:40:34`：`APPLE REMOTE HCI upgrade phase=ready result=installed_version_verified`。
- `12:40:35`：`SIRI REMOTE AUDIO phase=ready result=capture_available`。
- `12:40:46`–`12:40:50`：苹果遥控器方向键事件连续到达并执行。

界面截图发生在 `12:41:51`，此时两张卡片都仍是“状态确认中”。

## 已确认根因

`configureOnEngineQueue` 在共享串行 `engineQueue` 上同步调用 `engine.prepare()`。这次调用没有返回，导致：

1. 当前配置操作无法完成，`isAudioOutputReady` 保持 false。
2. 后续配置、停止和恢复任务全部排在同一个队列后面，无法执行。
3. `remoteCardStatus` 把语音判为 `.unknown`，`RemoteDeviceCardStatus.resolve` 对 `.unknown` 返回 `.confirming`，卡片显示“状态确认中”。

因此卡片不是没有刷新，也不是蓝牙连接状态错误；它反映的是音频输出尚未确认。App 重启会创建新的进程、队列和音频引擎，所以当前现场可以通过退出重开恢复。

## 尚未确认的底层触发条件

日志只能证明 `engineQueue` 停在 `prepare_engine`，不能证明底层是：

- 虚拟音频驱动在旧进程退出后没有及时释放；
- `coreaudiod` 对新 HAL 客户端的响应暂时阻塞；
- 设备重新枚举与 `AVAudioEngine.prepare()` 的竞态；
- 其他进程占用虚拟设备。

需要在卡住时抓取 `sample SayAll` 或 `spindump`，并对照 `coreaudiod` 系统日志，才能确认 HAL 层根因。本次修复不假设具体驱动原因，只保证音频启动不会无限阻塞共享队列。

## 修复

- 新增 `AudioEngineStartCoordinator`：把 `AVAudioEngine.prepare()` 和 `start()` 放到独立工作队列，最多等待 2 秒。
- 超时后取消启动令牌，并让孤立引擎在工作线程返回后自行停止；共享音频队列不再被 Core Audio 调用永久占用。
- 配置超时只允许重试一次。重试使用新的引擎和新工作队列，成功后正常恢复卡片；两次都失败时记录明确失败并让卡片进入“语音异常”，不再无限“状态确认中”。
- 卡片在“已连接 + 语音必需 + 已选择输出设备 + 音频输出明确失败”且当前状态为“语音异常”时，第三行显示“恢复语音”备用入口。点击后调用 `recoverRemoteVoiceAudio()`，重新执行一轮有界配置；语音或测试音进行中禁用，不替代正常语音启动路径。
- 正常路径不改变：成功后仍在原 `engineQueue` 上启动 player、提交状态和观察配置变化；不 flush、不丢弃尾音，不改变语音会话时序。

新增脱敏日志：

```text
AUDIO CONFIGURE timeout operation_id=<id> attempt=<n> phase=timed_out result=failed reason=prepare_timeout completion=forced pending_buffers=<n>
AUDIO CONFIGURE cleanup operation_id=<id> attempt=<n> phase=completed result=stopped reason=prepare_timeout
AUDIO CONFIGURE retry operation_id=<id> attempt=<n> reason=prepare_timeout queue=audio_output
AUDIO CONFIGURE completed operation_id=<id> phase=completed result=ready|failed reason=ready|configure_failed|configure_timeout attempts=<n>
AUDIO ERROR start_failed ... operation_id=<id> attempt=<n>
REMOTE CARD_ACTION phase=requested action=recover_voice source=user
REMOTE CARD_ACTION phase=completed action=recover_voice result=ready|failed
REMOTE CARD_ACTION phase=cancelled action=recover_voice result=blocked reason=<stable_reason>
```

日志沿用进程内操作号和 attempt，不包含设备身份、用户路径、音频正文或第三方 App 私有状态。

## 验证

自动化：

- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --scratch-path .build-public --filter VirtualAudioConnectionLifecycleTests`：51 项通过。
- 卡片、本地化、设置页和音频定向回归：`RemoteDeviceCardStatusTests|LocalizationTests|VirtualAudioConnectionLifecycleTests|SettingsPageRegressionTests`，158 项 / 4 个套件通过。
- 公开全量 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --scratch-path .build-public`：1529 项、112 个套件通过。
- 公开 Release 构建 `SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain --scratch-path .build-public -c release`：通过。
- `scripts/verify-repository-governance.sh`：通过。
- `scripts/check-repository-boundaries.sh`：`REPOSITORY BOUNDARY PASS`。
- 本地公开测试包 `2.0.8 (408)`，源码 `46e40d3a`（与 PR 代码树一致，其后仅文档修订），安装到 `~/Applications/SayAll.app`。首次启动 `AUDIO READY` 69 ms，完全退出后重新启动 `AUDIO READY` 64 ms，均为 `attempt=1`，没有 timeout/retry；日志新增 `attempt=` 和 `attempts=` 字段正确。
- 生产 `SettingsView` 离屏截图夹具 `CARD_SCENARIO=audio`：中文/英文、浅色/深色共 4 张 `1067 × 760`（Retina `2134 × 1520`），“恢复语音”/“Restore”按钮与状态文字无截断，已附 PR；截图只证明静态布局，不替代真实点击和音频恢复验收。
- 新增覆盖：
  - 启动成功返回 `.ready`；
  - 启动抛错返回 `.failed`；
  - 工作线程阻塞时 50 ms 测试超时返回 `.timedOut`，调用方不被阻塞，释放后 cleanup 执行；
  - 只有 `timedOut` 允许重试一次，`failed` 和 `ready` 不重试；
  - 生产源码接线和 `prepare_timeout` 日志字段检查；
  - “恢复语音”只在已连接、语音必需、已选择输出且音频输出明确失败时出现；组件、会员、映射和链路失败不出现；
  - 中英文按钮文案与设置页接线检查。

真实环境边界：

- 尚未在真实 `SayAll` 虚拟声卡上复现这次 Core Audio 阻塞并验证自动重试是否成功。
- 尚未完成实体遥控器语音、第三方语音工具文字上屏和连续会话复验。
- 如果底层 HAL 永久阻塞，两个尝试都会超时，卡片会明确显示失败而不是“状态确认中”；此时仍需要重启 App 或恢复系统音频服务。
- 被放弃的工作线程和 `AVAudioEngine` 会在 HAL 返回后自行执行 cleanup；如果 HAL 永不返回，该孤立对象保留到进程退出。本次修复保证共享音频队列和卡片状态不再被永久阻塞，不宣称能回收永不返回的 HAL 调用。

## 后续

用本候选构造本地测试包，执行：

1. 正常启动并确认音频 ready。
2. 使用一次苹果或小米语音会话，确认文字上屏。
3. 完全退出 App，立即重新打开，观察是否出现 timeout/retry 日志以及卡片是否自动恢复。
4. 如果现场仍能复现阻塞，在卡片卡住时抓取 `sample SayAll`，补充 HAL 栈和 `coreaudiod` 证据。

真实设备、系统音频状态和第三方工具结果完成前，本修复保持候选状态。
