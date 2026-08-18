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

## 日志收集

发生问题时提供：

- 精确的 UTC 开始、屏幕关闭、休眠、唤醒、解锁和首次语音时间；
- `~/Library/Logs/RemoteMic/runtime.log` 对应时间段；
- 休眠前、屏幕关闭后和唤醒后的 `pmset -g assertions`；
- App 版本、macOS 版本、Mac 型号、遥控器型号和所选音频设备；
- 使用的真实语音工具及其麦克风选择方式。

重点检索日志前缀：`SYSTEM AUDIO`、`AUDIO RELEASE`、`AUDIO REBIND`、`AUDIO DEFAULT_INPUT`、`ATVV STREAM`、`MOBILE VOICE`。

## 验证边界

- 自动化可以证明生命周期策略、重叠事件状态、活跃语音保护和原有蓝牙/Fn 会话基线。
- Release 构建只能证明代码可编译和组装。
- 只有真实 macOS 电源管理、真实 MiRemoteV 2ch、真实遥控器和 `pmset` 才能证明 CoreAudio 断言确实消失并且 Mac 能进入自动休眠。
