# 项目日志规范

本文规定无线麦SayAll.app 的运行日志、用户可复制诊断和测试证据应如何设计与输出。目标是在不记录用户敏感信息的前提下，仅凭日志即可快速还原一次操作经过、确定失败边界，并区分确定事实与推测原因。

本规范适用于新增功能、现有功能修改、Bug 修复、状态机、异步任务、蓝牙、HID、音频、权限、输入法、Nearby、网页连接、更新与安装流程。用户如何收集日志和运行日志验收分别见现有调查文档及 [`Testing/RuntimeLogging.md`](Testing/RuntimeLogging.md)。

## 基本原则

- 日志是产品功能的一部分。新增或修改功能时，必须同步设计、实现和验证日志，不能等用户出问题后再补。
- 日志必须覆盖完整逻辑链路，而不是只记录入口、收到事件、解码成功或入队成功。必须继续记录下游是否真正处理、提交并产生用户可见结果。
- 日志只记录定位问题所需的最少信息。不得记录用户内容、个人身份、设备身份、凭据或可反推出这些信息的数据。
- 日志中的事实、未知状态和推测必须分开。无法通过公开接口确认的第三方 App 内部状态必须记录为 `unknown` 或明确的诊断边界，不能猜测为 `true`、`false` 或确定根因。
- 面向机器的字段必须使用稳定英文枚举和 `key=value`，不得依赖当前系统语言、本地化文案、Swift 类型描述或 `Optional(...)`。
- 同一次操作必须有可关联的进程内操作编号，并且只产生一个最终结果。轮询中的临时状态不能反复覆盖或伪装成最终失败。
- 日志时间统一使用带毫秒的 UTC ISO 8601；耗时统一使用单调时钟计算并输出整数毫秒。

## 基本信息

### 每行运行日志

`AppLogger` 写出的每一行至少包含：

```text
2026-08-30T03:19:26.123Z pid=1234 ver=1.9.18 build=172 COMPONENT ACTION phase=completed result=passed
```

必需字段：

| 字段 | 要求 |
| --- | --- |
| 时间戳 | UTC、ISO 8601、毫秒精度 |
| `pid` | 当前 SayAll 进程 ID，只用于区分同时运行的实例 |
| `ver` | `CFBundleShortVersionString` |
| `build` | `CFBundleVersion` |
| 组件与动作 | 稳定英文标识，例如 `AUDIO SESSION`、`ONBOARDING VOICE_ATTEMPT` |
| `phase` 或等价状态 | `requested`、`started`、`completed`、`failed`、`cancelled`、`timed_out` 等稳定值 |
| `result` / `reason` | 最终结果或稳定原因码；成功也要明确记录 |

### 诊断头

用户复制的诊断、验收 session 和每次 App 启动的环境头必须包含以下 App 信息：

```text
diagnostic_schema=3
app_version=1.9.18
app_build=172
source_revision=<完整 Git Commit SHA 或 unknown>
build_channel=stable|pr_preview|local|unknown
release_tag=v1.9.18|none|unknown
bundle_id=com.hd838a.RemoteMic
process_id=1234
process_architecture=arm64|x86_64|unknown
hardware_architecture=arm64|x86_64|unknown
running_under_rosetta=true|false|unknown
```

要求：

- `diagnostic_schema` 是诊断格式版本。字段删除、重命名或语义变化时必须递增；仅增加可选字段可以保持版本不变。
- App 版本和 Build 必须同时存在。PR 候选包不得只靠相同的版本和 Build 与正式包区分；必须提供 `source_revision` 和 `build_channel`，候选分发时还应使用未被正式包占用的更高 Build。
- `source_revision` 必须在构建时写入产物，运行时不得尝试读取 Git 工作区。
- 无法可靠取得的值写 `unknown`，不能省略后让人误以为旧格式或字段采集失败。

系统基本信息必须包含：

```text
generated_at=2026-08-30T03:19:26.123Z
macos_version=26.0.1
macos_build=25A123
app_language=zh-Hans
```

要求：

- 记录完整 macOS 产品版本和系统 Build，不能只记录主版本。
- 只记录 App 当前语言，不记录用户账户、地区、时区、Apple ID 或系统设备名称。
- 权限、Feature Flag、控制方式和运行模式只在影响当前功能链路时加入对应功能上下文，不把所有用户设置无差别导出。

## 新增或修改功能的日志要求

开发前必须先画出该功能从用户动作到最终可见结果的逻辑链路，并为每一个实际存在的边界确定日志。至少覆盖以下阶段：

1. 用户或系统请求进入功能。
2. 前置条件和权限检查。
3. 状态机接受或拒绝请求。
4. 异步任务、系统 API 或跨组件调用开始。
5. 数据到达、解析、验证和路由。
6. 下游消费、提交或输出。
7. 用户可见结果真正产生。
8. 取消、替换、超时、断开、重试和恢复。
9. 唯一最终结果。

不得用一条“成功”跨越多个尚未验证的阶段。例如：

- `received` 只证明收到数据，不证明解析成功。
- `decoded` 只证明解码成功，不证明数据已路由到正确会话。
- `enqueued` 只证明入队，不证明音频已经播放或写入目标设备。
- `submitted` 只证明提交异步请求，不证明目标 App 已聚焦或动作已执行。
- `audio_received` 只证明 SayAll 收到声音，不证明输入法已经生成文字。

### 每条逻辑链路的必需事件

| 事件 | 记录内容 |
| --- | --- |
| 请求 | 稳定动作名、来源分类、进程内 `operation_id` |
| 前置检查 | 每个会改变分支的条件及通过/失败结果 |
| 状态变化 | `from`、`to`、触发原因和 generation；状态未变化时不重复刷日志 |
| 跨组件交接 | 上游结果、下游是否接受、同一 `operation_id` |
| 异步等待 | 等待对象分类、超时阈值、实际耗时 |
| 取消或替换 | `reason=cancelled_by_user|superseded|disconnect|permission_revoked|...` |
| 失败 | 失败阶段、稳定原因码、可用的 error domain/code、是否可重试 |
| 恢复 | 原失败原因、恢复入口、恢复后状态和耗时 |
| 完成 | 最终用户结果、总耗时；一次操作只能有一个终态 |

`operation_id`、`attempt_id`、`generation` 必须是进程内短生命周期编号，不能使用设备 UUID、会话 Token、手机号或其他可识别用户的值。进程重启后可以重新从零开始。

### 状态机和高频事件

- 状态机只记录真实状态转换。轮询仍处于同一状态时不得重复写相同失败。
- 一次 attempt 只输出一个 `terminal_result`。录音中、等待文字等中间阶段不作为最终失败写入用户诊断事件历史。
- 高频音频包、HID 报告和网络帧不得逐包输出。应记录首包、尾包、聚合计数、字节数、帧数、峰值区间、丢弃数量和耗时。
- 防抖或合并任务只记录最终执行，必要时增加 `coalesced_events=<数量>`；被替换且没有产生业务效果的任务不能制造大量假事件。
- 并发和重试必须带 generation 或 attempt，迟到回调应记录 `ignored reason=stale_generation`，避免把旧回调归到新会话。

### 错误和失败归因

- 系统错误统一记录稳定的 `error_domain` 和 `error_code`；不得把 `localizedDescription` 直接写入机器日志。
- 同一事件存在多个错误时使用语义前缀，例如 `connect_error_domain`、`write_error_code`。
- `observed_failure` 表示已经确认的现象；`probable_cause` 只能用于有证据支持的候选原因，并必须同时给出 `probable_cause_confirmed=true|false`。
- 第三方 App 内部设置、服务器内部状态或硬件固件行为无法观察时，必须写明边界，例如：

```text
observed_failure=external_tool_no_commit
diagnostic_boundary=external_tool_internal_state_unavailable
probable_cause_confirmed=false
```

- 不能把“没有日志”当作成功，也不能把“请求已发出”当作最终功能可用。

## 推荐字段格式

事件建议使用以下顺序，便于人读和机器解析：

```text
COMPONENT ACTION operation_id=12 phase=completed result=passed source=physical_remote elapsed_ms=842
```

字段规范：

- key 使用小写 snake_case。
- 枚举值使用小写 snake_case。
- 布尔值只使用 `true` 或 `false`；确实无法确认时使用 `unknown`，不能用空值代替。
- 数字字段在 key 中带单位，例如 `elapsed_ms`、`sample_rate_hz`、`bytes_received`。
- 字符串必须经过单行和稳定 token 处理；不得出现换行、Tab、控制字符、未转义空格或本地化文本。
- 缺失值使用语义明确的 `none`、`unknown` 或 `unavailable`，并在同一字段中保持一致。

一次 Onboarding 语音测试的理想终态示例：

```text
ONBOARDING VOICE_ATTEMPT attempt_id=12 phase=completed result=failed voice_tool=weixin
trigger_down_observed=true trigger_up_observed=true audio_samples_received=true
audio_route=virtual_audio_direct audio_received_samples=64000
audio_scheduled_samples=64000 audio_played_samples=64000 audio_pending_samples=0
audio_selected=miremotev_2ch audio_actual_observation=miremotev_2ch audio_bound_observation=true
input_target_ready=true focus_lost=false focus_recovered=false manual_input_observed=false
transcript_commit_observed=false terminal_result=external_tool_no_commit
external_microphone_observable=false external_microphone_user_confirmed=true
external_next_check=microphone_matches_selected_device
probable_cause_confirmed=false diagnostic_boundary=external_tool_internal_state_unavailable
elapsed_ms=3128
```

这条日志能证明 SayAll 已收到声音、实际绑定并播放到所选虚拟设备、输入目标正常，但第三方工具没有提交文字。`external_microphone_user_confirmed` 只能表示用户勾选确认，不能替代自动检测；SayAll 不得读取第三方 App 私有配置。因而日志应优先提示检查“第三方工具麦克风是否与 SayAll 所选设备一致”，但不能进一步断言微信输入法没有开启“按住说话”或已经确定选择了错误麦克风。

虚拟音频链路必须分别记录以下事实，不能只输出 `audio_received=true` 或 `enqueued=true`：

| 阶段 | 推荐字段 |
| --- | --- |
| SayAll 收到音频 | `audio_received_batches`、`audio_received_samples` |
| 路由与入队 | `audio_route`、`audio_enqueue_failures`、`audio_scheduled_samples` |
| Core Audio 设备绑定 | `audio_selected`、`audio_actual_observation`、`audio_bound_observation` |
| 实际播放与排空 | `audio_played_samples`、`audio_interrupted_samples`、`audio_pending_samples` |
| 连续会话隔离 | `audio_generation`；上一 generation 的迟到 callback 不得计入下一次 attempt |

当录音结束时仍有正常 pending 音频，不应立即输出终态失败；应等待该功能定义的排空/文字截止窗口，只有截止时仍 pending、播放不完整或已经中断才判定为音频投递失败。

## 隐私与敏感信息红线

任何运行日志、统一日志、用户可复制诊断、崩溃附加信息和测试证据都不得包含：

- 用户说出的音频、音频原始字节、语音转写正文、输入框内容和文字前后文。
- 剪贴板内容、按键输入内容、自定义快捷指令参数、URL query/body、Webhook Header 或 Body。
- 用户名、邮箱、手机号、Apple ID、账户 ID、联系人、地址或其他身份信息。
- 用户目录、完整文件路径、文件名、文档名、窗口标题或工作区名称。
- 蓝牙 MAC、设备 UUID、序列号、系统设备名称、用户自定义设备名、IP 地址和 Bonjour 实例名。
- 邀请码、配对码、授权码、Token、Cookie、API Key、密码、私钥、证书内容、P8、Keychain 值或任何凭据。
- 第三方 App 的私有文件、数据库、沙盒容器、历史、内部配置或未公开协议数据。
- 前台 App、输入框或文档的用户可识别内容。需要区分逻辑分支时使用批准的稳定分类，例如 `voice_tool=weixin`，不输出窗口标题或内部对象描述。

不得为了规避上述限制而直接记录敏感值的哈希。稳定哈希仍可能成为跨会话跟踪标识；需要关联时只使用当前进程内随机或递增编号。

允许记录的内容包括：

- 稳定功能枚举、状态、布尔结果和脱敏计数。
- 已批准的产品/协议分类，例如 `remote_model_family=rc003`、`audio_device_kind=miremotev_2ch`。
- 音频帧数、采样率、声道数、耗时和脱敏信号统计，但不包含可还原声音的样本。
- 系统错误 domain/code、HTTP 状态类别和稳定业务原因码，但不包含响应正文、请求内容或凭据。

如果不确定某字段是否可能识别个人或恢复用户内容，默认不记录，并在代码审查中明确评估。

## 诊断摘要要求

提供给用户复制的诊断摘要必须：

- 首行写明产品和诊断类型。
- 包含 `diagnostic_schema`、App 完整身份、系统基本信息和生成时间。
- 只包含当前问题所需的功能状态，不导出整个设置数据库。
- 对每次操作给出唯一终态，并保留有限数量的最近关键事件。
- 明确写出自动确认、用户手动确认和外部不可观察状态，不能混为同一种绿色通过。
- 不包含正文、音频、路径、设备标识和凭据。
- 字段必须可向后兼容；旧字段无法继续解释时递增 `diagnostic_schema`。

## 开发与评审检查清单

新增或修改功能的 PR 必须逐项确认：

- [ ] 已画出从入口到用户可见结果的完整链路。
- [ ] 每个会改变结果的前置条件和分支都有稳定日志。
- [ ] 异步提交与真实完成分开记录。
- [ ] 成功、失败、拒绝、取消、超时、重试、恢复和迟到回调均可区分。
- [ ] 一次操作只有一个终态，并可通过 operation/attempt/generation 关联。
- [ ] 日志包含足够的耗时、计数和稳定原因码，可定位具体失败阶段。
- [ ] 没有输出用户内容、个人信息、设备身份、路径、凭据或第三方私有状态。
- [ ] 错误使用稳定 domain/code，没有输出本地化错误正文。
- [ ] 高频路径已聚合、去重或限频，不会淹没关键事件。
- [ ] 自动化覆盖关键日志字段、终态去重和隐私红线。
- [ ] 用户可观察行为变化时，`Testing/` 测试手册已说明如何收集和判断日志。

如果无法通过日志区分功能失败发生在哪个组件、哪个阶段或哪个 attempt，该功能不满足交付要求。
