# Voice input destination readiness investigation

## Observations

- User-visible failure: after a mapped button launches or focuses a target app, the first two Fn voice attempts can do nothing and the third succeeds.
- Field logs show the app action returns before the target input is focused:

  ```text
  15:37:44 APP ACTION opened bundle=com.openai.codex
  15:37:47 APP FOCUS succeeded bundle=com.openai.codex

  15:37:49 APP ACTION opened bundle=com.openai.codex
  15:37:51 APP FOCUS succeeded bundle=com.openai.codex
  ```

- `KeyboardInjector.send` returns `true` immediately after submitting an asynchronous application activation/focus request.
- `VoiceFnTapSessionController` independently posts Fn after a fixed 150 ms delay.
- There is no handoff proving that the frontmost app owns a safe editable Accessibility element before Fn is posted.
- The Fn controller and mapper sources are identical between `v1.8.3` and `v1.8.8`; onboarding and wider Typeless exposure made the existing race easier to encounter.
- Existing controller tests cover tap pairing and audio pre-roll, but no test composes target activation latency with the first voice stream.

## Hypotheses

### H1: Fn is posted before asynchronous target focus completes (ROOT HYPOTHESIS)

- Supports: field logs show 2-3 seconds between app-open and focus-success while the Fn controller waits only 150 ms.
- Conflicts: none.
- Test: simulate a target that becomes editable after 3 seconds and assert that the first Fn-down is not attempted before readiness.

### H2: The third-attempt behavior is caused by a counter in the Fn session controller

- Supports: the user observes a repeatable third-attempt success.
- Conflicts: no three-attempt counter exists; the controller starts every idle session the same way.
- Test: inspect and exercise consecutive sessions with identical timing.

### H3: The regression is a Codex-specific Accessibility selector failure

- Supports: the reported target app is Codex and it has a specialized composer focus strategy.
- Conflicts: the missing readiness handoff also affects Claude, cmux, custom apps, recorded fields, focus shortcuts and arbitrary shortcuts.
- Test: use a target-agnostic delayed editable-focus fixture rather than a Codex-specific candidate.

### H4: Audio is lost before the virtual device becomes ready

- Supports: the symptom is missing dictated text.
- Conflicts: existing pre-roll tests prove audio is buffered until the fixed Fn start tap; the field event order points to focus completing after Fn.
- Test: record buffered samples while readiness is delayed and require complete replay after readiness.

## Experiment

The regression test in `CoreVoiceInputJourneyTests` uses the production Fn controller with a simulated target that is not ready during the fixed 150 ms start delay. The key setter records any Fn-down attempted before the target becomes editable.

Observed on the old implementation: the test failed exactly as predicted. At 150 ms it recorded an Fn-down attempt while the simulated target was not ready, then recorded `start_tap_failed`; advancing to the target's 3-second readiness point produced no later Fn tap because the session had already been disabled. This confirms H1 and rejects H2 as the primary cause.

## Root Cause

`KeyboardInjector.send` acknowledges submission of asynchronous target activation/focus, while `VoiceFnTapSessionController` independently posts Fn after 150 ms; without a readiness handoff, Fn can reach the old or non-editable focus before the intended input exists.

## Fix

Added a shared destination-readiness coordinator, connected every external configured-action entry point to it, delayed only Fn sessions that have a recent target-switch request, expanded pre-roll to five seconds, and cancelled unsafe, superseded, changed or timed-out destinations. The original delayed-target reproduction, controller lifecycle tests and RC001/RC003 simulated hardware journeys now pass.

---

# Onboarding upgrade HID-before-BLE investigation

## Observations

- 用户现场 `1.8.9 (101)` 升级首次启动截图中，同一页显示“正在查找小米遥控器”和“已收到实体按键”。
- 普通按键实际可用，重启 App 后 BLE 状态恢复。
- HID 回调直接更新 `lastRemoteButtonPress`，BLE 展示状态只在 `XiaomiBluetoothBridge` Ready 后为已连接，两条链路彼此独立。
- 本机没有现场版本和事故时段日志，因此不能确认首次进程为何没有及时建立 bridge。

## Hypotheses

### H1: HID 先恢复，但 Onboarding 没有把该证据用于 BLE 恢复（ROOT HYPOTHESIS）

- Supports: 旧页面按键订阅只更新 `observedRemoteButtons`，不调用重连。
- Test: 要求按键已观察、BLE 未连接、尚未恢复时策略返回 true，并检查按键回调接入恢复函数。

### H2: 手动“重新查找”已能创建缺失 bridge

- Conflicts: 旧 `reconnect()` 只遍历现有正式和 discovery bridge；两者均为空时无操作。
- Test: 检查 `reconnect()` 在空 bridge 状态调用 `startBluetoothConnections()`。

### H3: 每个后续实体按键都应重连

- Conflicts: 连续重连会造成连接抖动，并可能破坏已经进行的连接尝试。
- Test: 一次恢复请求后策略必须返回 false。

## Experiments

- 在旧实现先加入 Onboarding 定向回归；`swift test --filter OnboardingFlowTests` 因不存在 `shouldRequestRemoteReconnect` 而失败，生产按键接线和空 bridge 启动分支也不存在。
- 实现一次性策略、按键接线和空 bridge 启动后，同一套 6 项定向测试通过。

## Root Cause

已确认的停滞根因是 HID 与 BLE 状态独立，而收到 HID 按键后没有恢复 BLE；同时空 bridge 状态下的 `reconnect()` 是无操作，使瞬态只能等完整重启重新执行启动流程。首次升级进程为何进入空 bridge 状态仍需现场日志确认。

## Fix

- Onboarding 遥控器页只在“已收到实体按键、BLE 未连接、尚未请求恢复”时调用一次 `model.reconnect()`。
- 重新进入遥控器页时重置该一次性状态。
- `BridgeAppModel.reconnect()` 在运行时已启动且没有任何 bridge 时调用 `startBluetoothConnections()`，同时写入 `BLE RECONNECT starting_missing_bridges` 诊断日志。

## Validation

- `swift test --filter OnboardingFlowTests`：6 项通过。
- `swift test`：194 项、20 个 suite 全部通过。
- `scripts/test.sh`：42 项项目自检通过。
- `swift build -c release`、`scripts/build-app.sh`（含深度签名校验）与 `git diff --check`：通过。
- 自动化只覆盖策略和代码接线；真实 Sparkle 升级首次启动、CoreBluetooth 回调和 RC003 普通语音基线仍待验证。

---

# 普通物理语音 MIC_EXTEND 撤回与 Typeless 尾音反馈调查

## Observations

- 2026-08-11 的 RC001 普通长按会话在 10 秒、20 秒均记录 `ATVV MIC_EXTEND rejected` 与 `ATVV VOICE LEASE extend written=false`；另一个约 10.9 秒会话也在 10 秒处被拒绝。
- 同一批日志的两个会话都继续收到音频，松开后记录 `STREAM_STOP` 和 `AUDIO PLAYBACK drained pending_buffers=0`。
- 普通物理语音的 `startStreaming()` 只设置 `streaming = true`；只有主机主动 `MIC_OPEN` 成功才设置 `microphoneOpened = true`。
- `requestMicrophoneExtend()` 要求 `microphoneOpened && streaming`，所以普通物理会话不会真正写出续期命令。
- 用户反馈 Typeless 长按松手前最后 1–2 秒文字丢失，但尚未提供发生时间、App 版本、遥控器型号或对应日志，当前无法复现其现场。
- Typeless 停止路径先调用 `endSessionAfterDraining`，排空虚拟音频后才发送第二次 Fn 点按；排空最多等待 0.75 秒。
- 2026-08-09 已保存的 13 次 Fn 路线真机验收全部最终记录 `AUDIO PLAYBACK drained`，没有 `AUDIO PLAYBACK interrupted`，不能证明反馈现场发生了排空超时。
- 控制与音频使用不同 BLE 特征；收到 `STREAM_STOP` 后，`handleAudio()` 会静默忽略 0.3 秒内到达的音频数据。现有日志没有记录被该分支丢弃的数据量。

## Hypotheses

### H1: 定时 MIC_EXTEND 导致 Typeless 尾音丢失

- Supports: 两者都位于普通蓝牙语音会话生命周期中。
- Conflicts: 普通会话的命令实际未写出；反馈发生在松手边界而不是 10 秒定时边界；收到 `STREAM_STOP` 时租期计时器立即取消。
- Test: 对照现场会话的 `MIC_EXTEND`、`STREAM_STOP` 与音频排空时序。
- 结论：依据现有代码和日志基本排除。

### H2: Typeless 停止时 0.75 秒排空上限清除了剩余缓冲

- Supports: 超时路径会把待播放计数清零并结束 Fn 会话；如果积压超过 0.75 秒，尾音会被截断。
- Conflicts: 已保存的 Fn 真机基线全部正常排空，没有中断证据；现场尚无日志。
- Test: 获取反馈现场完整日志并检查停止时 `pending_buffers`、排空完成时间及是否出现 `AUDIO PLAYBACK interrupted`；用可控积压超过 0.75 秒的音频输出复现。
- 结论：候选原因，未确认。

### H3: STREAM_STOP 先于最后音频特征通知到达，0.3 秒保护窗静默丢弃尾包（当前优先假设）

- Supports: 控制和音频是不同 BLE 特征，通知顺序不能由单一特征保证；代码明确丢弃停止后 0.3 秒的数据且不记录日志；丢失最后一个音素或词组可能表现为识别文字少 1–2 秒。
- Conflicts: 代码窗只有 0.3 秒，尚不能直接解释完整 1–2 秒原始音频丢失；历史真机验收没有观察到尾音异常。
- Test: 增加只读诊断计数并用模拟硬件回放 `STREAM_STOP → 延迟音频通知`，再结合现场日志确认实际乱序和丢弃 sample 数；在用户明确授权修复前不修改生产行为。
- 结论：优先候选，未确认。

### H4: Typeless 自身在第二次 Fn 点按或识别提交时截断未完成结果

- Supports: 用户看到的是最终识别文字而不是原始 PCM；第三方 App 的提交时机可能放大很短的音频尾部延迟。
- Conflicts: Mac 端已经设计为排空后再发送停止点按；没有现场日志或对照 App 结果。
- Test: 同一长按会话同时在可保存原始输入结果的目标和 Typeless 中对照，并记录第二次 Fn 点按时间。
- 结论：环境候选，未确认。

## Experiment

- 只读核对生产日志与状态门禁，确认普通会话的 `MIC_EXTEND` 在写 BLE 前被拒绝；无需修改代码即可否定 H1。
- 未对 Typeless 候选原因做生产实验：缺少用户现场时间段和明确修复授权，不能把推测性改动当成修复。

## Root Cause

- 普通 `MIC_EXTEND` 候选方案失败的根因：物理按键会话只进入 `streaming`，没有主机主动开麦的 `microphoneOpened` 状态，因此续期请求被本地门禁拒绝，从未写入遥控器。
- Typeless 尾音反馈：当前未确认根因；现有证据基本排除与定时 `MIC_EXTEND` 相关，优先调查停止控制与尾部音频通知乱序，其次调查 0.75 秒排空上限。

## Fix

- 删除普通会话的 10 秒续期、180 秒强制关闭和 2 秒停止确认超时重连，以及只验证该候选实现的测试。
- 保留底层 `MIC_EXTEND` 协议能力，限定给未来已经成功主动 `MIC_OPEN` 的独立实验。
- 本轮不修改 Typeless 停止或音频处理逻辑；需要现场日志或可重复模拟后再进入正式修复。
- 撤回后验证：`swift test` 189 项、`scripts/test.sh` 42 项、`hardware-simulation/scripts/test-remote-mic.sh` 16 项全部通过；未执行新的真实 RC001/RC003 或 Typeless 真机验收。

---

# Onboarding 新配对遥控器 BLE / HID 生命周期调查

## Observations

- 用户提供的两张 Onboarding 截图分别确认：新遥控器已在系统蓝牙连接但页面仍显示查找；之后页面显示“小米遥控器已连接”，普通按键仍未被无线麦收到，但 macOS 系统音量键可以正常响应。
- 真实现场日志为用户提供的 `runtime.log`，SHA-256 `1c97fb79a30e42d9b39c876cfde73b589bf5b272de887727982b84a8b38f2a5b`；此前读取的本机日志不作为现场证据。
- `14:10:47Z` discovery 通过 `source=scan name=MI RC` 找到新设备，随后完成 `BLE MODEL identified=rc003`、`ATVV CAPS` 和 `BLE READY`，说明 BLE 协议链路可用。
- 同一时段首次映射为 `matched=1 applied=0`，稍后稳定为 `matched=2 applied=1`；输入监控和辅助功能均为 `true`，但持续出现 `HID START rejected power_suppressed=false`。
- App 在 `14:15:12Z`、`14:16:11Z` 和 `14:23:01Z` 重启后仍为 `matched=2 applied=1`，因此“重启会修好 HID”被现场日志否定。
- `OnboardingView` 从系统蓝牙设置返回时只刷新权限，不刷新 discovery；目标 identifier 又持续连接超时，因此新系统连接设备可能要等新的扫描周期才出现。
- `XiaomiBluetoothBridge` 的 discovery 模式每个新连接周期会先调用 `retrieveConnectedPeripherals(withServices:)`；因此重新开始 discovery 周期可以识别已经被系统连接、但可能不再广播的新遥控器。
- `RemoteVoiceFunctionMapper` 原逻辑要求全部匹配 service 写入成功才把 `isPowerKeySuppressed` 设为 true；任一旧、失败或幽灵 service 都会让全部 HID monitor fail-closed。

## Hypotheses

### H1: 从系统蓝牙设置返回时没有刷新新设备发现（ROOT HYPOTHESIS）

- Supports: 用户边界是重启后恢复；重启会重新创建 discovery bridge，而返回前台只刷新权限。discovery 新周期会查询系统已连接外设。
- Supports: 现场日志显示旧 target identifier 长时间超时，最终由 `source=scan` 找到新设备；返回前台缺少 discovery 刷新。
- Test: 源码接线回归要求 Onboarding 遥控器页恢复前台时调用仅刷新 discovery 的生产入口；旧实现失败，候选实现通过。

### H2: 部分 UserKeyMapping 成功导致全局 HID fail-closed（ROOT HYPOTHESIS）

- Supports: 现场连续记录 `matched=2 applied=1`、权限为 true、`HID START rejected`，与代码的全目标门禁完全一致。
- Conflicts: 不能简单把“至少一个成功”视为全局安全，否则失败设备的 Power usage 仍可能触发锁屏。
- Test: 两个 Location ID 中一个完整成功、一个部分失败时，只允许完整成功的 Location；缺失 Location 必须 fail-closed。旧实现无法表达该范围，候选测试通过。

### H3: 输入监控或辅助功能权限在配对期间失效

- Supports: 权限失效也会让 App 不处理 HID，而系统音量仍能响应。
- Conflicts: 现场日志明确记录 `input=true accessibility=true`，已否定为本次根因。

### H4: BLE 连接展示只跟随旧选中 profile

- Supports: 重新配对会产生新的 CoreBluetooth identifier。
- Conflicts: 当前 `refreshBluetoothPresentation()` 的 `isConnected` 检查所有 bridge 的 Ready 状态，不只检查选中 profile；如果新 discovery bridge 已 Ready，Onboarding 应显示连接。
- Test: 只读代码核对已否定其作为第一张截图的主要原因。

## Experiments

- 最小系统实验确认：目标 `IOHIDServiceClient` registry ID 与 `IOHIDDevice` registry ID 不同，但两侧 `LocationID` 位模式一致；可用 `UInt32 LocationID` 把成功抑制的 event service 安全映射到实际监听设备。
- 失败回归先确认旧实现缺少 `locationID`、安全范围和前台 discovery 接线；生产实现后定向测试通过。
- UI 截断另见独立 Bug 文档；固定宽度和单行状态可直接由生产布局代码稳定复现。

## Root Cause

1. Onboarding 遥控器页从系统设置返回时没有刷新 discovery，新配对设备可能只存在于系统连接列表而不继续广播。
2. 电源键抑制对多个 HID service 部分成功时，旧安全门只能“全部开启或全部关闭”；为避免危险 Power 事件，它关闭全部 monitor，导致安全设备的普通按键也完全失效。

## Fix

- 遥控器页恢复前台时刷新 discovery cycle。
- mapper 记录每个 service 的 Location ID，只有同一 Location 下全部 service 都成功写入 Power→F20 映射时才进入安全集合。
- HID monitor 只打开和处理安全 Location 集合内的设备；失败或缺失 Location 的设备继续 fail-closed。
- 不修改 HID 报告格式、普通按键映射或 BLE/ATVV 协议。

---

# Onboarding 全流程恢复门禁审计

## Observations

- 现有流程对每一页分别检查能力，但原完成页无条件通过，因此权限、遥控器或音频在后续页面失效后仍可完成。
- App 回到前台时原来只刷新权限；遥控器页后来补了 BLE discovery，但 HID 生产监听仍没有重建，音频页也不主动重新枚举设备。
- 遥控器页只显示“等待实体按键”，没有显示 `hidStatus`；`HID START rejected`、权限变化或设备未打开对用户表现相同。
- 语音和三个按键的通过标志是视图内存状态；若完成页也强依赖这些标志，窗口或 App 在完成页重建后会把它们清零并形成新的停滞。
- 现有截图能证明布局，状态机测试能证明布尔门禁，二者都不能触发系统设置切回、CoreBluetooth 热插拔、IOHID service 部分失败和音频驱动变化的组合顺序。

## Hypotheses

### H1: 当前页从系统设置返回时没有刷新对应生产依赖（ROOT HYPOTHESIS）

- Supports: 前台回调只统一刷新权限；遥控器与音频各自依赖 discovery、IOHIDManager 和 CoreAudio 枚举。
- Test: 源码接线回归要求遥控器页同时调用 `refreshRemoteDiscovery`、`applyHIDSettings`，音频页调用 `refreshAudioDevices`。

### H2: 底层多设备状态被压成单一 Bool，部分失败导致全局阻断（已由现场日志确认）

- Supports: `matched=2 applied=1` 后持续 `HID START rejected power_suppressed=false`，权限为 true。
- Test: 设备级 Location 安全集合只允许完整成功设备，失败或缺失 Location 继续拒绝。

### H3: 完成页不重验运行时，流程结束时不保证 App 仍可用（ROOT HYPOTHESIS）

- Supports: 原 `.complete` 直接返回 true，与权限、BLE、音频实时状态无关。
- Test: 完整能力通过时允许完成；随后断开 BLE 或使音频未就绪时必须阻止完成。

### H4: 最终页应要求所有前序临时标志仍为 true

- Supports: 能最严格复用前面每个步骤的结果。
- Conflicts: 标志只存在于 `OnboardingView`，窗口或 App 重建会清零；用户即使已完成实测也会在最终页被永久阻断。
- Test: 当前权限、BLE 和音频仍有效，但临时语音/按键标志因视图重建清零时，完成页仍可继续。
- 结论：否定；最终页只重验实时生产依赖，前序交互仍由原页面门禁负责。

## Experiment

- 先新增门禁和源码接线回归，旧实现分别在完成页断连、遥控器 HID 前台恢复、音频前台刷新和按键错误可见性上失败。
- 实现当前页恢复和最终运行时重验后，同一组定向测试通过。

## Root Cause

测试模型只覆盖了每个组件的静态成功条件，没有把跨应用前后台、热插拔、多个底层对象部分成功和最终状态回退组合为一个用户旅程；生产页面也缺少针对 HID 失败的可见状态和重试入口。

## Fix

- 遥控器页回到前台时刷新 BLE discovery 和 HID 配置，显示生产 HID 状态并提供重新检测。
- 音频页回到前台时重新枚举输出设备。
- 完成页重新验证当前权限、BLE 和音频输出，并在进入时刷新 discovery 与音频列表。
- 页面进入日志增加 `ONBOARDING STEP entered=<step>`。

## Validation

- 失败优先的 Onboarding 定向测试 13 项通过。
- `swift test`：208 项、20 个 suite；`scripts/test.sh`：42 项；私有硬件模拟：16 项，均通过。
- Release App 构建、深度签名校验和 `git diff --check` 通过。
- 生产视图浅色、深色各 8 张已逐张检查；标准完成态与运行时退化错误态都已检查，无裁切或黑白分栏。
- 未执行真实 RC001/RC003 新配对、系统权限历史、充电线状态、音频驱动安装或第三方语音工具验收。

---

# 1.8.22 点击快捷指令崩溃

## Observations

- 用户 `1.8.22 (114)` 崩溃报告为主线程 `EXC_BREAKPOINT / SIGTRAP`，Swift `_assertionFailure` 后进入 `RemoteMicMacroView.body.getter`。
- 用户二进制 UUID 与 GitHub Release 下载包一致；最终 App 含标准 `Contents/Resources/SayAllMacroPlatform_SayAllMacroRemoteMic.bundle`，二进制仍含 `.app` 根目录和发布机器 `/private/tmp/...` 两个 SwiftPM 候选路径。
- 资格入口已通过 `Bundle.main.resourceURL` 解析资源，但 `RemoteMicMacroView` 的空状态两处和通用本地化函数一处仍直接使用 `bundle: .module`。
- 当前 Mac 没有用户设备的有效资格，因此不伪造线上资格；使用同一资源 Bundle 和自动访问器构造最小标准 `.app` 复现。

## Hypotheses

### H1: 页面残留的直接 `Bundle.module` 找不到用户机不存在的构建目录（ROOT HYPOTHESIS）

- Supports: 崩溃函数、三处源码调用、错误候选路径和 `fatalError` 异常类型完全一致。
- Conflicts: 资格入口正常；它使用的是另一条安全资源路径，正好限定了故障边界。
- Test: 标准 `.app/Contents/Resources` 中放入真实 Bundle，分别执行自动访问器和 `Bundle.main.resourceURL` 对照。

### H2: 打包脚本根本没有复制资源

- Supports: 缺资源也会触发同一 `fatalError`。
- Conflicts: 同 UUID 下载包已确认 Bundle、本地化文件和 `Info.plist` 存在。
- Test: 最终 App 结构检查；已否定。

### H3: 本地化目录大小写或 `Info.plist` 损坏

- Supports: 历史候选出现过类似问题。
- Conflicts: 当前在 Bundle 初始化前崩溃，候选路径没有进入 `Contents/Resources`。
- Test: 通过标准资源 URL 初始化 Bundle 并读取英文字符串。

### H4: Developer ID 签名阻止资源读取

- Supports: 用户运行签名发布包。
- Conflicts: 资源不含可执行代码，其他资源已正常读取，错误明确是路径解析。
- Test: 保留最终 App 结构并直接读取标准资源 URL。

## Experiment

- 旧自动访问器在资源实际存在时仍以状态 `133` 退出，报告 `.app` 根目录和不存在的构建机绝对路径。
- 单变量改为 `Bundle.main.resourceURL` 后状态 `0`，成功读取 `Quick Commands`；H1 确认，H2–H4 不符合故障边界。

## Root Cause

此前只修复资格入口，没有审计实际快捷指令页面；页面三处直接 `Bundle.module` 绕过标准 App 资源解析器，而发布验证只检查文件存在，开发机的绝对构建缓存掩盖了运行时崩溃。

## Fix

- 页面空状态和通用本地化统一复用现有安全资源 Bundle。
- 私有模块测试禁止 `RemoteMicMacroView` 重新出现 `bundle: .module`。
- 宿主构建脚本拒绝包含该绕过路径的私有模块。

## Validation

- 私有模块 30 个 XCTest + 7 个 Swift Testing 通过。
- 宿主门禁测试先失败后通过。
- 宿主门禁直接检查 `1.8.22` 私有模块提交时在编译前拒绝，状态 `1`，错误为 `SayAll macro page bypasses the packaged resource resolver`。
- 最新 main 注入修复模块的 Apple Silicon Release App 构建和 `verify-app.sh` 通过。
- 独立打包 `RemoteMicMacroView` 在移走完整 SwiftPM 构建目录后真实渲染，状态 `0` 并输出 `PACKAGED_MACRO_VIEW_RENDERED`。
- 无缓存宿主 App 正常启动并在 `800 × 650` 设置窗口打开关于页和快捷指令邀请码区域。
- 尚未完成 Developer ID、公证、Intel 和有效资格宿主侧边栏真实点击。
