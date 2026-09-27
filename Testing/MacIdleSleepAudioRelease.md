# Mac 自动休眠时释放虚拟音频测试

## 适用范围

- 分支：`fix/bug-mac-sleep-audio-20260818`
- 平台：macOS
- 音频设备：优先使用 `MiRemoteV 2ch`，并至少回归一个其他可写入的虚拟音频设备
- 遥控器：RC003；如有 RC001，同步执行基础休眠与唤醒用例

## 测试前准备

1. 安装待测无线麦SayAll.app，连接真实遥控器并确认 BLE、HID 和普通语音均正常。
2. 在无线麦SayAll.app中选择 `MiRemoteV 2ch` 作为语音输出。
3. 准备豆包或另一个真实语音输入工具，并确认唤醒前能收到遥控器音频。
4. 将 macOS 显示器关闭时间临时设置为便于测试的较短时间；记录测试前的设置，测试结束后恢复。
5. 打开终端，准备在关键步骤运行 `pmset -g assertions`。
6. 记录测试开始 UTC 时间，并保留 `~/Library/Logs/RemoteMic/runtime.log`。

## 用例一：屏幕亮起时保持现有语音体验

1. 保持屏幕亮起且遥控器已连接。
2. 按住语音键说一句完整短句，松开后等待文字上屏。
3. 重复三次，并执行一个普通遥控器按键。

预期：三次语音都不丢首字、不断尾，普通按键正常；日志不应无故出现 `SYSTEM AUDIO` 暂停事件或音频释放。

失败判定：屏幕正常使用时虚拟音频被自动释放、首次语音明显变慢、丢首字、无声或普通按键受影响。

## 用例二：遥控器持续连接时允许 Mac 自动休眠

1. 保持遥控器在 Mac 附近并确认 BLE 仍为 ready。
2. 不退出无线麦SayAll.app，也不把语音输出改为“不输出语音”。
3. 停止操作，等待显示器按系统设置自动关闭，并继续等待系统进入自动休眠。
4. 在进入休眠前后分别保存一次 `pmset -g assertions`；如测试条件不允许休眠后执行命令，唤醒后立即保存并结合系统睡眠时间判断。

预期日志顺序：

1. `SYSTEM AUDIO event=screen_did_sleep ... suspended=true`
2. `AUDIO RELEASE requested reason=system_screen_did_sleep ...`
3. 如系统默认输入原为虚拟设备，出现 `AUDIO DEFAULT_INPUT fallback_applied ...`
4. `AUDIO RELEASE completed ... engine_running=false`

预期系统结果：`com.apple.audio.MiRemoteV2ch_UID.context.preventuseridlesleep` 不再由无线麦SayAll.app进程持续持有，Mac 能按原系统设置进入自动空闲休眠。

失败判定：没有收到屏幕休眠事件、释放只 requested 但没有 completed/cancelled 结果、引擎仍为 running、MiRemoteV 2ch 的 CoreAudio 断言持续增长，或 Mac 仍不能自动休眠。

## 用例三：唤醒后自动恢复且第一次语音可用

1. 从用例二的休眠状态唤醒并解锁 Mac。
2. 不进入设置页、不重新选择音频设备，立即按住语音键说一句话。
3. 再等待五秒并说第二句话。

预期：系统事件可能先后出现 `screen_did_wake`、`system_did_wake` 和 `session_did_become_active`；存在其他暂停原因时日志记录 `resume_deferred`，最后一个原因解除后记录 `AUDIO REBIND` 与 `SYSTEM AUDIO resume_completed configured=true`。如果唤醒发生在旧释放排空完成前，应出现带 `trigger=resume_...` 或 `trigger=bluetooth_voice_start` 的 `AUDIO RELEASE cancelled`。两次语音均正常，第一次不丢首字。

失败判定：唤醒后必须手动重新选择设备、第一次语音无声或丢首字、恢复发生在会话仍锁定时，或恢复失败但日志没有具体原因和音频状态。

## 用例四：休眠事件不得打断正在进行的语音

1. 按住语音键并持续说话。
2. 在保持语音的同时锁定屏幕，或用测试环境触发会话 inactive/屏幕休眠事件。
3. 松开语音键并等待尾音排空。

预期：事件发生时记录 `SYSTEM AUDIO suspend_deferred`，当前语音不中断；停止语音后记录 `AUDIO RELEASE requested reason=system_suspended_after_bluetooth_voice` 和 `AUDIO RELEASE completed`。

失败判定：系统事件到达时立即截断正在说的话、停止后音频仍长期占用，或释放被取消但日志没有 `superseded` / `required_again` 原因。

## 用例五：多系统事件不会过早恢复

1. 锁屏并等待显示器关闭。
2. 唤醒显示器但暂不解锁。
3. 观察日志后再完成解锁。

预期：日志中的 `reasons` 同时记录 `screen_sleeping`、`session_inactive` 等实际原因；只解除其中一个原因时出现 `resume_deferred`，完成解锁后才恢复音频。

失败判定：显示器刚亮但用户会话仍锁定时就重新长期占用音频，或原因集合出现无法清除的残留状态。

## 用例六：设置和连接稳定基线

分别验证：

1. 选择“不输出语音”后休眠并唤醒，确认不会自动选择旧设备。
2. 遥控器断连后休眠并唤醒，确认不会因为唤醒单独启动虚拟音频；遥控器重新 ready 后才恢复。
3. 休眠期间手动改过系统默认输入，唤醒后确认无线麦SayAll.app不覆盖用户的新选择。
4. 手机和 Apple Watch 正在发送语音时触发锁屏，确认活跃语音不被提前释放；停止后释放。
5. 测试音播放期间触发锁屏，确认播放完成后释放。

失败判定：任何旧设置被错误恢复、断连设备导致音频提前重启、用户手动选择被覆盖，或移动语音/测试音被系统事件直接截断。

## 用例七：同机多账户快速用户切换后语音可用

适用分支：合入 `main` 后的 `main`（原改动分支 `codex/session-switch-audio-recovery-20260927`，已合入）。在该文档既有休眠/唤醒用例之上追加，**用例一~六仍需全部通过**。

对应问题见 [`Bugs/2026-09-26-multi-user-session-switch-mic-no-audio.md`](../Bugs/2026-09-26-multi-user-session-switch-mic-no-audio.md)。该问题**尚未复现**，本用例是把它从「无法定性」推进到「可定性」的真机流程，**通过不等于根因已确认**。

### 测试前准备

1. 同一台 Mac 上准备两个真实用户账户 A、B，都安装并运行无线麦SayAll.app。
2. 在 A 中选择 `MiRemoteV 2ch`，并确认实体遥控器的 BLE、HID、普通按键与真实语音文字上屏均正常。
3. 两个账户都保留 `~/Library/Logs/RemoteMic/runtime.log`，并记录开始 UTC 时间。

### 步骤

1. 在 A 中确认遥控器为 ready 且语音正常。
2. 用菜单栏「切换用户」切到 B，让 B 的 App 运行起来（可用同一台遥控器做一次按键或语音）。
3. 切回 A，**不做任何手动操作**：不要点「立即重新连接」，不要重新选择音频设备，不要重开 App。
4. 切回后 10 秒内按住语音键说一句话并等待文字上屏。
5. 重复两次（共三次语音）。

### 预期日志顺序（A 账户）

1. `SYSTEM AUDIO event=session_did_resign_active changed=true suspended=true reasons=session_inactive`
2. `SYSTEM AUDIO event=session_did_become_active changed=true suspended=false reasons=none ready_bridges=0 configured_bridges=1`
3. `SYSTEM AUDIO resume_skipped reason=system_session_did_become_active required=false`
4. `SYSTEM AUDIO voice_link_recovery event=session_did_become_active cause=no_ready_bridge ready_bridges=0 configured_bridges=1`
5. `BLE RECOVERY phase=begin trigger=session_activated ...` 与 `BLE RECOVERY phase=requested trigger=session_activated ...`
6. 随后出现 `BLE SCANNING` / `BLE CONNECTED` / `BLE READY`，紧接着 `AUDIO REBIND reason=bluetooth_ready` 等音频重建日志。

预期用户结果：切回后**不需要任何手动操作**即可语音，三次均不丢首字、不断尾。

如果第 5 步之后的桥始终没有进入 ready：日志应出现 `BLE DISCONNECTED` 与 `BLE RECONNECT scheduled failure_count=...`。此时记录退避间隔、失败次数和最终是否 ready，并按 Bug 文档里的 H3（两个账户实例争抢同一台遥控器）继续调查，**不得据此判定为已修复**。

### 稳定功能回归项

1. 单账户下锁屏再解锁（会话切回）不应出现 `BLE RECOVERY trigger=session_activated`：桥本来就 ready，门控应为完全空操作。
2. 正在按住语音键说话时切换会话，不应出现 `BLE RECOVERY`（活跃语音门控）。
3. 没有配置任何遥控器时切换会话，不应凭空启动蓝牙连接。
4. 用例一~六全部仍通过，尤其不得出现音频被提前释放或重建。

### 失败判定

- 切回后仍需手动点「立即重新连接」或重开 App 才能语音；
- 桥已经 ready 时仍出现 `BLE RECOVERY trigger=session_activated`（说明门控失效，可能打断健康连接）；
- 正在进行的语音被 `BLE RECOVERY` 打断，或出现尾字丢失；
- 三次语音中任何一次丢首字、断尾或无声。

## 日志收集

发生问题时提供：

- 精确的 UTC 开始、屏幕关闭、休眠、唤醒、解锁和首次语音时间；
- `~/Library/Logs/RemoteMic/runtime.log` 对应时间段；
- 休眠前、屏幕关闭后和唤醒后的 `pmset -g assertions`；
- App 版本、macOS 版本、Mac 型号、遥控器型号和所选音频设备；
- 使用的真实语音工具及其麦克风选择方式。

重点检索日志前缀：`SYSTEM AUDIO`、`SYSTEM AUDIO voice_link_recovery`、`AUDIO RELEASE`、`AUDIO REBIND`、`AUDIO DEFAULT_INPUT`、`BLE RECOVERY`、`BLE DISCONNECTED`、`BLE RECONNECT`、`ATVV STREAM`、`MOBILE VOICE`。

## 验证边界

- 自动化可以证明生命周期策略、重叠事件状态、活跃语音保护和原有蓝牙/Fn 会话基线。
- Release 构建只能证明代码可编译和组装。
- 只有真实 macOS 电源管理、真实 MiRemoteV 2ch、真实遥控器和 `pmset` 才能证明 CoreAudio 断言确实消失并且 Mac 能进入自动休眠。
- 用例七的「会话切回」只涉及快速用户切换与解锁，不依赖休眠/唤醒，因此不需要 `pmset`；但只有**真实双账户 + 真实遥控器 + 真实第三方语音工具**才能证明切回后确实恢复拾音，单机单账户与单元测试都不能替代。

## Issue #283 回归：恢复最近物理输入

1. 选择 Wave Link 的目标物理麦克风，确认它成为系统默认输入。
2. 启用 SayAll 虚拟输入并结束语音，等待虚拟资源释放。
3. 预期恢复到刚才的物理设备，而不是按名称排序的第一个设备；设备缺失时才回退到内置/首个候选。
4. 失败判定：覆盖用户手动选择，或恢复到错误物理设备。
