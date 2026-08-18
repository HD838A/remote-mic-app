# Onboarding iPhone / Web 分支门禁调查

## Observations

- 现场测试包为 Apple Silicon 本地 ad-hoc 包，源码提交 `3618d94e`，Bundle 版本 `1.8.25 (119)`。
- 网页版连接页稳定显示“网页版暂时不可用”，右栏没有二维码；同一测试包的 `Info.plist` 无法读取 `RemoteWebRelayURL`，但包含 `NSLocalNetworkUsageDescription` 和 `_remotemic._tcp` Bonjour 服务。
- iPhone 分支的音频页已经检测并选中 `MiRemoteV 2ch`，但“音频输出正常”未通过；用户只有从 iPhone 开始一次语音后才能继续。
- 对应现场日志在 `18:33:56Z` 首次收到手机语音时才执行 `AUDIO REBIND reason=mobile_voice_start → AUDIO CONFIGURE → AUDIO READY`；松开后在 `18:34:01Z` 执行 `AUDIO RELEASE reason=mobile_voice_stopped`。
- 第二次手机语音在 `18:34:03Z` 再次按需配置音频并进入 Ready；进入语音测试页后，`18:34:05Z` 松开又释放音频。
- iPhone 分支随后真实收到语音和普通按键：日志包含 `MOBILE VOICE started/stopped source=iphone` 和三个不同的 `PHONE REMOTE button`，因此 Nearby、本地网络、辅助功能、手机控制与语音链路都实际工作。
- 进入完成页时手机语音已经停止，音频状态又是 `engine_running=false selected={none}`；页面显示“当前环境状态发生了变化”，无法点击“打开无线麦”。
- iPhone 权限页只显示辅助功能。当前 Bundle 已声明本地网络用途和 Bonjour 服务；真实 Nearby 连接已经成功。虽然 iPhone/网页接收当前按键不依赖 CoreBluetooth 遥控器或 IOHID，后续产品规则明确要求所有控制方式统一开启蓝牙、输入监控和辅助功能，以覆盖切换控制方式、自定义按键及 Fn 输入法切换。
- `18:37:20Z` 之后日志来自另一次 `APP START version=1.8.5` 和实体遥控器流程，不作为本次 iPhone `1.8.25 (119)` 问题的证据。

## Hypotheses

### H1：本地测试包没有注入 Web Relay 配置（ROOT HYPOTHESIS）

- Supports：包内没有 `RemoteWebRelayURL`；页面稳定显示“暂时不可用”，而不是生成二维码后连接失败。
- Conflicts：正式发布构建可能由 CI 注入配置，因此问题可能只影响本地测试包，不一定影响公开预览版。
- Test：使用明确的生产 relay 环境变量重建同一提交，验证包内 key 存在且 Web 会话配置能够生成二维码数据。

### H2：音频页错误要求按需手机音频播放器处于持续运行状态（ROOT HYPOTHESIS）

- Supports：日志只在 `mobile_voice_start` 配置输出，停止时释放；截图中设备存在且已选，唯一未通过项是输出 Ready；开始语音后立即可继续。
- Conflicts：实体遥控器路径会因 BLE Ready 提前保持音频播放器运行，原门禁对实体路径成立。
- Test：用能力策略测试分别输入“设备存在且已选、iPhone 未开始语音、播放器未运行”和实体遥控器同状态；iPhone 应允许进入真实语音测试，实体遥控器仍保持原门禁。

### H3：完成页错误把瞬时音频播放器 Ready 当成手机路径的持续环境条件（ROOT HYPOTHESIS）

- Supports：手机语音停止后日志明确释放音频，随后进入完成页；页面唯一表现为环境变化，真实 Nearby、语音与三个普通按键此前均已通过。
- Conflicts：完成页仍必须确认所选音频设备没有被移除，不能无条件放行。
- Test：完成页能力策略在 iPhone/网页路径下要求 MiRemoteV 2ch 或 BlackHole 2ch 已选择且仍存在，在实体遥控器路径下继续要求生产输出 Ready；设备被移除时三条路径都必须失败并回到音频页。

### H4：完成页误用了实体遥控器 BLE 连接状态判断手机连接

- Supports：同一时段日志持续出现 BLE timeout，截图提示也提到遥控器连接。
- Conflicts：现有分支设计已有 Nearby/WSS 独立连接能力，且失败也可能完全来自音频 Ready。
- Test：检查 `selectedControlConnected` 与完成页策略调用，确认 iPhone 使用 Nearby、网页使用 WSS，而不是 `model.isConnected`。

### H5：iPhone 权限页遗漏了必须可预检的系统权限

- Supports：页面只显示一项，用户认为信息不完整；Nearby 涉及本地网络。
- Conflicts：包已声明本地网络用途与 Bonjour；现场 Nearby、语音和按键成功；macOS 本地网络没有与辅助功能相同的可靠授权查询/跳转 API，连接页的真实会话门禁更准确。
- Test：检查生产连接启动、Info.plist 和权限策略；本地网络继续由下一页真实连接验证，三项系统权限按统一产品门禁逐项验证。

## Experiments

- H1：直接读取用户测试 ZIP 对应 App 的 `Info.plist`，`RemoteWebRelayURL` 不存在；`build-app.sh` 只在 `REMOTE_WEB_RELAY_URL` 非空时写入该 key，`WebRemoteConfiguration.relayURL()` 在环境和 Bundle 都无值时返回 nil。三层证据一致，确认本地打包遗漏配置。
- H2 / H3：临时在现有 iPhone/Web 分支测试中加入三行实验断言：设备已选择、连接与辅助功能有效、`audioReady=false` 时，音频页和完成页应通过。旧实现对 iPhone、网页两条路径共四个断言全部失败；实验代码随后撤回。该结果与现场 `mobile_voice_start` 才 Ready、`mobile_voice_stopped` 即 Release 的日志完全一致，确认门禁模型与按需音频生命周期冲突。
- H4：只读检查 `selectedControlConnected`，iPhone 明确使用 `model.isPhoneRemoteConnected`，网页明确使用 `webRemoteConnected`；完成页没有直接使用实体 BLE 的 `model.isConnected`。日志中的 BLE timeout 是同时存在的旧实体遥控器后台尝试，不是本次完成页根因，H4 被否定。
- H5：只读检查确认 iPhone/Web 的当前连接技术只依赖 Accessibility，Bundle 已声明 `NSLocalNetworkUsageDescription` 和 `_remotemic._tcp`，现场 Nearby 连接、语音、按键均成功；随后产品规则改为所有方式统一开启三项系统权限，因此不再按最小技术依赖裁剪权限页。

## Root Cause

1. 本地测试包没有注入发布流程已有的生产 `REMOTE_WEB_RELAY_URL`，Web Remote 配置为空，无法生成会话二维码。
2. iPhone 和网页语音采用按需虚拟音频生命周期：只有语音开始时配置，停止后立即释放；Onboarding 音频页和完成页却复用了实体遥控器“播放器必须持续 Ready”的门禁，导致必须先说话才能离开音频页，并在说完后必然卡住完成页。
3. iPhone 权限页按最小技术依赖只显示辅助功能，与“所有控制方式统一开启完整权限”的产品要求不一致。

## Fix

- 已实现：手机/网页音频页和完成页以“MiRemoteV 2ch 或 BlackHole 2ch 已选择且仍存在”为静态门禁，实际配置成功继续由下一页真实语音的会话、PCM、停止和文字验证；实体遥控器仍要求持续 Ready。
- 已实现：三种控制方式统一显示并验证蓝牙、输入监控和辅助功能；本地网络仍在连接页通过 Nearby/WSS 真实会话验证。
- 待执行：下一份本地测试包从私有生产环境注入 relay，并启用 `REQUIRE_WEB_REMOTE_CONFIGURATION=1`，缺配置时打包直接失败。

## Validation

- 旧实现加入回归断言后，iPhone/网页在 `audioReady=false` 时的音频页和完成页共四个断言全部失败，复现门禁冲突。
- 修复后 `swift test --filter OnboardingFlowTests` 23 项通过；同时覆盖实体遥控器仍失败、设备未选择仍失败和诊断失败码一致性。
- 中英文 strings 已通过 `plutil -lint`；完整 235 项 Swift 测试、42 项项目自检和构建通过。
- iPhone 与网页分支浅色/深色共 40 张生产视图截图已逐张检查，无内部滚动、裁切或黑白分栏。
- 带生产 Relay 配置的本地包及真实手机链路待后续步骤完成。

---
# Local transcript quick-send loss investigation

## Observations

- 功能开关持久化值为开启，现场 App 为 `1.8.5 (67)`，日志确认辅助功能权限可用。
- 2026-08-17 02:25:49 与 02:26:33 的两次 Codex 语音均完成音频接收和排空，但本地没有对应记录，也没有 `TRANSCRIPT ARCHIVE update_failed`。
- TextEdit 会话 22 成功保存；随后 Codex 会话 25、27、28 也成功保存，证明存储、权限和 Codex 的 Accessibility 输入框并非持续不可用。
- Codex 会话 23 在停止约 1 秒后发送 Return，没有保存；会话 24 停止约 1 秒后下一次语音开始，也没有保存。会话 25、27、28 的文字在输入框中保留足够时间并成功保存。
- `TranscriptCaptureCoordinator` 发现文字变化后要求稳定 0.9 秒；输入框在这之前恢复原文会清空候选，新会话开始则直接 `cancel()` 丢弃上一候选。
- 早期会话 19、20 的日志只有秒级精度且没有捕获候选诊断，因此可以确认它们没有落盘，但不能逐毫秒证明其文字何时出现、何时被发送清空。

## Hypotheses

### H1：快速发送或连续开始下一段语音时，已观察到的候选文字被清空（ROOT HYPOTHESIS）

- 支持：失败会话 23 的停止到 Return 仅约 1 秒；失败会话 24 的停止到下一会话开始仅约 1 秒；代码在这两种状态都丢弃候选。
- 冲突：会话 19、20 的 Return 日志约在停止 3 秒后，但缺少转写文字实际出现时间和候选诊断，不能单靠秒级日志排除同类竞态。
- 实验：让测试在候选文字稳定满 0.9 秒前把输入框恢复为原文，确认旧实现丢失已观察到的文字。

### H2：开关在最初两次语音时实际尚未生效

- 支持：用户是在测试过程中确认开关状态。
- 冲突：持久化值为开启；同一进程后续无需重启即可保存 TextEdit 和 Codex。
- 实验：现有启用状态测试和同进程现场成功记录足以否定持续初始化问题。

### H3：Codex 输入框不提供所需的 Accessibility 属性

- 支持：最初只有 TextEdit 基准成功。
- 冲突：同一 Codex Bundle 随后连续保存三条记录。
- 实验：现场 Codex 成功记录已经否定“完全不兼容”，只剩时序性变化可能。

### H4：归档写入失败或统计页未刷新

- 支持：用户在页面中看不到历史。
- 冲突：失败时目录根本不存在且没有归档失败日志；后续写入后文件与页面数据均出现。
- 实验：直接检查 `Application Support/RemoteMic/Transcripts/v1` 与运行日志，否定仅 UI 刷新问题。

## Experiment

- 在现有连续文字提取测试中只改动 3 行：结束语音后先推进 0.25 秒让协调器观察到合法候选，再把输入框模拟为发送后的空值，最后推进一个 0.125 秒轮询周期。
- 旧实现稳定失败：`harness.captures` 为空，证明候选虽然已经被观察到，但输入框清空会进入取消分支并永久丢失。
- 实验只改变一个变量（候选稳定前输入框清空），运行后已恢复测试源码。

## Root Cause

协调器把“稳定 0.9 秒”作为唯一提交条件，却在快速发送、焦点离开或下一次语音开始时无条件取消会话；因此已经观察到且符合原始光标连续差异规则的候选文字会在输入框清空前来不及提交。

## Fix

- 已观察到的合法候选在输入框清空、目标焦点离开或下一段语音开始时先结算，没有候选时仍取消。
- 周围文字发生无关变化、敏感目标、关闭开关和语音过程中切换目标仍保持拒绝。
- 日志新增不含正文的结算原因、Bundle ID 和字符数，后续可以区分稳定保存、快速发送和连续语音结算。
- 新增快速发送与下一段语音开始回归；旧实现的最小复现失败，修复后同一状态机用例通过。

## Validation

- `swift test`：236 项、22 个 Suite 全部通过。
- `plutil -lint`：Info.plist 与中英文 Localizable.strings 通过。
- `git diff --check`：通过。
- `1.8.5 (68)` Release App 构建成功，深度签名验证通过，主程序为 arm64，且未包含私有 AI 包。
- 独立语音记录页已实测侧边栏顺序、宽布局和真实 App 图标；RC001/Codex 快速发送与连续语音仍需用户使用新 App 完成真实时序复验。

---

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
