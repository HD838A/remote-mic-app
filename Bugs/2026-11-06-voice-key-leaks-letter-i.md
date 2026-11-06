# Intel Mac 语音键漏成字母 i，首次语音测试全程被判手动输入

- 时间：2026-11-06
- 状态：已最终定性（22:48）——漏字仅在“遥控器尚未被 App 接管”的时序窗口出现；285 重装后未复现；代码改动保留为防御性兜底，待 Xcode 27 构建与 CI 验证
- 影响范围：App 2.0.0 build 285；MacBook Pro 16,2（Intel，macOS 14.2.1，x86_64，非 Rosetta）；小米 RC003 语音遥控器
- 功能点：`RemoteVoiceFunctionMapper` Fn 硬映射、Onboarding 语音测试页手动输入门禁、`HIDRemoteMonitor` 设备接管时序
- 简单描述：按住遥控器语音键，前台输入框出现字母 `i`，豆包输入法不会起浮窗；Onboarding 语音测试连续 4 次在松手瞬间以 `voice.manual_input` 失败。当日稍后（重置状态、遥控器被接管后）同一操作不再出现 `i`，语音恢复正常。
- 原始记录：用户提交的 `SayAll first-use diagnostics`（`diagnostic_schema=3`，2026-11-06T03:36:51Z 与 2026-11-06T14:48:30Z 两份）

## 现象与现场证据

诊断字段：

- `voice_trigger_path=bluetooth_remote`、`voice_started=true`、`voice_samples_received=true`、`voice_ended=true`
- `voice_audio_received_samples=63360`、`voice_audio_enqueue_failures=0`、`voice_audio_delivery_result=delivered_to_selected_device`
- `voice_attempt=4`、`voice_attempt_phase=failed`、`voice_terminal_result=manual_input`、`voice_transcript_wait_ms=0`
- `manual_transcript_input_observed=true`、`transcription_appeared=true`
- `remote_voice_button_press_count=0`、`remote_control_button_observation_count=1`
- `voice_key_mode=fn`、`voice_fn_tap_mode_enabled=false`

同机只读复核（App 未运行）：

- `hidutil list` 可见 RC003：`VendorID 0x2717`、`ProductID 0x32B8`、Transport `Bluetooth Low Energy`。
- `hidutil property --get UserKeyMapping` 里存在 `0x70000003E → 0xFF000003`，以及 Return/方向/Home/Power/音量等中和项；映射事务本身成功，`matched=0` 不是本次原因。
- 现场按用户描述做了两次对照：ABC 输入源下按住语音键，TextEdit 里打出字母 `i`；用 Mac 自带 Fn/Globe 长按，豆包输入法正常起浮窗并出字。两点合起来说明：豆包侧监听 Fn 正常，出问题的是遥控器这颗键在系统里的用法。

## 稳定复现

**结论（当日 22:48 最终定性）：不能通过“重装/清状态”稳定复现。漏字只在“遥控器尚未被 App 接管”的时序窗口出现，窗口是否出现取决于首次连接的接管时序。**

当日证据链：

- 修复前（映射表只有 `0x3E`，且其目标值是旧版本写入的**无效 32 位短形式** `0xFF000003`）：`11:32–11:36` 连续 4 次 voiceTest 全部 `voice.manual_input`；伴生条件 `button_status=button_mapping.status.connected_fallback`（旁听兜底）与 `remote.button_not_ready`（11:34:44 blocked、11:34:47 recovered，App 尚未完成设备接管，约 20 秒）。
- 补写 `0x0C → Fn` 后（12:10–12:11）：连续 3 次 voiceTest 全部 passed，onboarding 一次走完。
- 22:20 重置全部本地状态（偏好域、App Support、Caches 等已删除并验证）后重装 build 285 重跑 onboarding：voiceTest attempt 1 一次通过（7 秒），未复现。
- 22:48 再次重置状态、在语音测试页按住语音键但**不说话**：失败为 `voice.external_tool_no_commit`（未说话且未确认豆包按键，属正常未完成），关键字段 `manual_transcript_input_observed=false`、`button_status=button_mapping.status.connected_fallback`——**旁听兜底态下没有漏 `i`**。

最终模型：**遥控器语音键发出的 HID 键值取决于它是否已被 App 接管**——

- 未被接管（首次连接早期，伴随 `remote.button_not_ready`）→ 发字母 `i`（`0x0C`）→ 系统直通输入框；若此时映射只认 `0x3E` 且 `0x3E` 的目标值无效（上午的双重叠加），则既无 Fn 又漏字，voiceTest 必挂；
- 已被 App 接管（哪怕只是旁听兜底）→ 发 F5（`0x3E`）→ 被映射为 Fn，一切正常（22:20、22:48 的情形）。

由此：

- 本修复（`0x0C` 一并映射为 Fn + 门禁排除不落字事件）定位为**防御性兜底**：兜住“遥控器未接管 + 映射只认 F5”的窗口；在 285 当前行为下（接管后键值为 F5）是惰性的、无副作用的；
- 上午失败更根本的来源是“首次连接后 `remote.button_not_ready` 持续约 20 秒、遥控器接管时序未完成”，建议另立调查项，需内部解密日志（`HID CONNECTED mode=`、`VOICE FN MAPPING`、`remote.button_not_ready` 前后时序）或带日志的新构建定性；
- 11:32 时 `0x3E` 目标值为无效短形式的写入来源（哪个版本）同样待查：当前 268/270 源码写入的是规范 64 位形式。

已知不复现/变体：若 onboarding 期间设备已被 promote 为独占（例如同一连接上重跑 onboarding），`i` 不会出现，失败形态会变成“有音频无文字”（`voice.no_transcript` / `external_tool_no_commit`）而不是 `manual_input`。

## 根因

漏字只在“App 尚未完成对这台遥控器的接管”的时序窗口里出现（首次使用/重置后的 onboarding 阶段），且当日是三个条件叠加：

1. `HIDRemoteMonitor` 有两条设备打开路径：`activateDevice` 用 `kIOHIDOptionsTypeSeizeDevice` 独占设备（状态 `button_mapping.status.connected`），`probeDevice` / `promoteProbedDevice` 只以 `kIOHIDOptionsTypeNone` 旁听（状态 `button_mapping.status.connected_fallback`）。失败当天的诊断字段正是 `button_status=button_mapping.status.connected_fallback`，且 `remote.button_not_ready` 持续约 20 秒——App 尚未完成设备接管。22:48 的对照诊断证明：**同样是旁听兜底态，遥控器被接管后该键不再漏 `i`**，因此键值本身随接管状态变化（未接管 = 字母 `i`，接管后 = F5），或存在等价的按键接管机制；确切机制需内部解密日志确认。
2. `RemoteVoiceFunctionMappingPolicy` 只把语音键的 `usage 0x3E`（键盘 F5）映射为 Fn，且当天 `0x3E` 的目标值是旧版本写入的无效 32 位短形式（`0xFF000003`，页面 0，无法转成 Fn）。未接管态下遥控器发出字母 `i`（`usage 0x0C`）没有命中映射，于是：
   - 系统不会产生 Fn，第三方语音工具收不到启动键（语音输入不可用）；
   - 这个键以普通字符 `i` 打进前台输入框。
3. `OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput` 只检查 `keyDown + hidSystemState + sourceUnixProcessID<=0`，不判断这个 keyDown 是否真的落字。语音键漏出的字符、以及语音触发键自身的 Fn keyDown（keyCode 63，同样来自 hidSystemState 且 pid=0）都会被判成“确认物理手输”，`OnboardingView` 于是在 `onChange(of: transcript)` 里立即 `finishVoiceAttempt(.manualInput)`；这解释了 4 次尝试的 `voice_transcript_wait_ms=0`。

失败窗口恰好就是首次语音测试本身，因此该缺陷在“最需要它通过”的时刻触发。

## 修复

- `RemoteVoiceFunctionMappingPolicy`：引入 `remoteVoiceKeySources`（`0x3E` 与 `0x0C`），`applying`/`restoring` 改为按 usage 集合增删，Fn 映射与 Typeless 中和映射同时覆盖两种用法；原来的单条 `remoteVoiceKey`/`neutralRemoteVoiceKey` 保留为第一个来源的别名，避免调用点语义漂移。
- `RemoteVoiceFunctionMapper.OriginalMappings.voice` 改为 `voices: [HIDUsageMapping]`，恢复时按实际存在的来源逐条还原，不会覆盖运行期间其他来源的映射变化。
- `OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput` 新增 `keyCode`/`characters` 两个可选参数：修饰键（54/55/56/58/59/60/61/62/63）与不落字的事件（空字符、控制字符、AppKit 功能键私用区 U+F700–U+F8FF）不再计入手动输入；`OnboardingView` 传入 `currentEvent.keyCode` 和 `currentEvent.characters`。
- `TECHNICAL.md` / `TECHNICAL.en.md` 同步语音键用法与中和范围。

## 验证

- **现场映射层验证（同日 12:19）**：用 `hidutil property --set` 在已连接的 RC003 上补写 `0x70000000C → 0xFF000003`（保留原有全部条目）后，用户按住语音键复测：豆包输入法正常起浮窗，输入框不再出现 `i`。说明 Intel 上这台机器的 macOS 能够把该 vendor top-case usage 转成 Fn，不需要额外的软件注入回退。
- **写入形式验证（同日 12:44）**：把该条改成 App 使用的 64 位形式 `0x000000FF00000003`（页面 `0xFF`、usage `3`）后复测，行为不变（豆包起浮窗、无 `i`）。即 32 位短形式与 64 位形式在这台机器上等价，新构建按 `functionKeyDestination` 写出的值可以直接验收。
- **旧构建回归**：build 285 启动后会重写 `UserKeyMapping`，但它只替换已知的 `0x3E` 与 Power 条目，未识别的 `0x0C` 条目原样保留（这一点与修复前“进入 Bridge Ready 就会整体覆盖”的预期不同）；同时它把 `0x3E` 那一条从 32 位短形式改写成 64 位规范形式。首用事件存储显示该构建在补丁生效后 `voiceTest` 连续 3 次 passed（attempt 5/6/7）、`controls` 与 `complete` 均通过、`onboarding.completedVersion=1`。
- **模式对照（同日 13:17）**：关闭 App（遥控器仍连接、方向键可用）后在 TextEdit + ABC 下按住语音键，输入框出现 `i`；App 运行且独占设备时同一操作不再出现 `i`。这组对照把“首次使用漏字”锁定在旁听兜底态，而不是映射写入或豆包侧问题。
- 单机逻辑级验证：把 `HIDUsageMapping` + 新策略 + 新门禁抽成独立 Swift 程序，用本机 Swift 5.9.2 编译运行，22 项断言全部通过（两种用法都映射为 Fn、`i` 映射被替换、幂等、power 追加顺序、恢复逐条还原、Fn/方向键/空字符不计入手动输入、`i` 仍计入）。
- `git diff --check`：见提交前检查。

## 验证边界

- 本机只有 Swift 5.9.2，仓库 `swift-tools-version` 为 6.2.0，`swift build` / `swift test` 无法在本机执行；整包编译、`RemoteMicTests`、SelfTest 与 Release 构建仍需在 Xcode 27 环境完成。
- 改动已 rebase 到上游 `HD838A/remote-mic-app` main（`64c382ac`，`CFBundleVersion=270`；build 285 为流水线覆盖的构建号）之上的提交 `5ec69190`，分支 `codex/voice-key-usage-i-20261106`，尚待推送与 CI。
- 修复定位为防御性兜底：285 当前行为下（接管后键值为 F5）改动是惰性的；它覆盖的是“遥控器未接管 + 映射只认 F5”的窗口。是否与 285 的接管/注入路径双触发，需在改后构建上确认。
- 漏字窗口的触发条件（`remote.button_not_ready` 约 20 秒、`0x3E` 目标值短形式的写入来源）尚未定性，需内部解密日志或带日志的新构建；本文不声称可按需复现。
- build 285 重写 `UserKeyMapping` 时只替换它已知的 `0x3E` 与 Power 条目，不会清除 `0x0C`；因此现场补丁能跨 App 重启存活，验收前需要主动让遥控器断开重连来复位。
- 未验证其他 RC003 批次是否还有第三种语音键用法；若后续现场再出现漏字，应把实际 usage 加进 `remoteVoiceKeySources` 而不是改单条记录。
- 输入源恢复时序（Fn 抬起时立即切回上一个输入法）未改动，仍观察是否会在豆包提交前抢走输入源。
