# 排空尾音期间被打断后的语音会话恢复测试

## 适用版本或分支

- 分支：包含 `Bugs/2026-09-05-voice-session-wedges-when-audio-reconfigures-mid-drain.md` 修复的分支
- 平台：macOS 14 及以上（Intel 变体为 macOS 13 及以上）
- 设备：RC003（必需，Fn 轻触语音路径）；RC001 用于稳定基线回归
- 虚拟设备：`MiRemoteV 2ch`
- 第三方 APP：Typeless（Fn 轻触触发键），以及豆包输入法用于对照

## 测试前准备

1. 安装被测版本，在 无线麦SayAll 中选择 `MiRemoteV 2ch` 作为语音输出。
2. 语音键模式设为 Fn/地球键，并开启 Fn 点按（Typeless）。Typeless 已授权麦克风，并选择 `MiRemoteV 2ch` 或“系统默认”。
3. 准备至少两个可用音频输出设备用于制造设备变化：内置扬声器，以及一个 USB 或蓝牙耳机（也可用“音频 MIDI 设置”新建聚合设备切换）。
4. 打开 `~/Library/Logs/RemoteMic/runtime.log`，每个用例记录本地开始与结束时间（UTC 标记更佳）。
5. 记录测试前版本号与 Build，确认没有遗留的 Remote Mic 进程。

> 关键时间窗：本次修复针对的是「语音键松开之后约 0.75 秒内」。除用例 2 外，其余打断动作都必须在**松开语音键后立刻**（1 秒内）完成，否则排空已经自然结束，测试无法覆盖目标路径。

## 用例 1：基线——正常一次语音（必须先通过）

1. RC003 按住语音键说 3 到 5 个字，松开。
   - 预期：Typeless 收到成对的 Fn（打开一次、关闭一次），文字**第一次**就完整出现。
   - 预期：日志出现 `ATVV STREAM summary`，随后出现 `AUDIO PLAYBACK drained trace=… pending_buffers=0`。
2. 重复 3 次。
   - 预期：每次都是第一次成功。

失败判定：出现第二次或第三次才成功；出现单只 Fn；日志出现 `AUDIO PLAYBACK interrupted`；尾音被截断。

## 用例 2：修复前的原始复现路径——排空期间切换音频输出设备

1. RC003 按住语音键说话，松开语音键。
2. **松开后 1 秒内**在系统声音设置或“音频 MIDI 设置”里切换 Mac 的音频输出设备（或插拔 USB 耳机）。
3. 观察 Typeless 与日志。
   - 预期：日志出现 `AUDIO PLAYBACK interrupted trace=…`（打断被记录，正常）。
   - 预期：本次会话仍然完成收尾，Typeless 不会停留在“正在听写”。
4. 再次按语音键说 3 到 5 个字，松开。
   - 预期：**这一次按键被接受**，正常产生一对 Fn 并出现文字，无需退出重启 App。

失败判定（这就是修复前的症状）：第 4 步按语音键完全没有反应，日志里既没有新的 `ATVV STREAM summary` 对应的 Fn 动作也没有新的排空记录，必须退出并重启 App 才能恢复。

## 用例 3：排空期间遥控器断连 / 虚拟音频释放

1. RC003 按住语音键说话，松开语音键。
2. 松开后 1 秒内关闭遥控器或让它离开蓝牙范围。
   - 预期：日志出现 `AUDIO PLAYBACK interrupted`，随后出现 `AUDIO RELEASE completed reason=bluetooth_not_ready`。
   - 预期：不出现「释放动作卡住」——`AUDIO RELEASE completed` 必须出现。
3. 重新连接遥控器，再按一次语音键。
   - 预期：语音恢复，一次成功。

失败判定：`AUDIO RELEASE completed` 始终不出现；或重连后语音键无反应。

## 用例 4：排空期间睡眠唤醒

1. RC003 说话后松开语音键，1 秒内合盖或触发睡眠。
2. 唤醒 Mac，等待遥控器重连完成。
3. 按语音键说话。
   - 预期：一次成功；不需要重启 App。

失败判定：唤醒后语音键无反应，或需要重启 App。

## 用例 5：排空期间手机语音介入（两路排空重叠）

1. RC003 说话后松开语音键。
2. 松开后 1 秒内，从已连接的手机端开始并立即停止一次语音。
3. 观察两侧。
   - 预期：两路都完成收尾，Mac 界面不停留在“手机语音进行中”。
   - 预期：随后 RC003 与手机各自再来一次语音都能一次成功。

失败判定：任一路的状态停在进行中；或之后任一路语音键/按钮无反应。

## 用例 6：前后台与切换目标 APP

1. 无线麦SayAll 在前台时执行一次用例 2。
2. 无线麦SayAll 最小化 / 在后台时再执行一次用例 2。
3. 在排空窗口内把前台 APP 从 Typeless 切换到另一个可输入的 APP，再按语音键。
   - 预期：三种情况下，打断后的下一次语音键都被接受。
   - 预期：Fn 只发给当时的目标，不出现两个 APP 同时收到听写开关。

失败判定：任一状态下打断后语音键无反应；或 Fn 发错目标。

## 用例 7：左/右 Command 语音键模式对照（非 Fn 轻触路径）

1. 语音键模式改为左 Command 或右 Command，按用例 2 制造一次排空期间的设备切换。
   - 预期：与修复前行为一致，不出现新的卡死或多余按键；下一次语音正常。

失败判定：出现修复前不存在的行为变化。

## 稳定功能回归（必须逐项确认）

- 语音键三种模式（Fn、左 Command、右 Command）各跑一次完整语音，均一次成功；极速按下/释放、连续语音会话与异常中断恢复无回归。
- RC003 普通语音基线：`STREAM_START → AUDIO → STREAM_STOP`，尾音完整。
- RC001 短语音尾包不丢失。
- App 退出后不保留 Remote Mic 的音频 IO。

失败判定：任一项与上一正式版行为不一致。

## 日志收集

1. 复制 `~/Library/Logs/RemoteMic/runtime.log`。
2. 标注用例编号、遥控器型号、目标 APP、前后台状态、打断动作类型、开始/结束时间。
3. 重点搜索：`ATVV STREAM summary`、`AUDIO PLAYBACK drained`、`AUDIO PLAYBACK interrupted`、`AUDIO ENGINE configuration_changed`、`AUDIO ERROR player_restart_exception`、`AUDIO RELEASE completed`、`AUDIO REBIND`。
4. 判读要点：`AUDIO PLAYBACK interrupted` **只说明打断被记录**，不说明会话已经正常收尾。必须同时确认打断之后的下一次语音键真的产生了新的 Fn 配对和文字，才能判定通过。
5. 不需要提交用户语音内容。

## 验证边界

- **自动化已验证**：`VirtualAudioOutput` 的排空回调在被 `flushPlayer()` / `stop()` 打断、被第二次排空请求顶替、以及回调内部再次 `stop()` 时都恰好触发一次；`VoiceFnTapSessionController` 在排空回答完全不到达时由截止时间完成收尾并接受下一次语音，且正常排空会取消该截止时间。测试进程没有可用虚拟输出设备，`engine` 与 `player` 始终为 `nil`，真实播放节点分支未被执行。
- **代理可验证**：构建、单元测试、自测脚本、仓库边界检查、日志文本。
- **必须由真实硬件与真实用户完成**：本文件全部用例。真实音频设备热插拔、真实睡眠唤醒、真实 CoreBluetooth 时序、真实 Typeless / 豆包输入法听写结果、以及 2 秒截止时间在真机主队列阻塞时是否足够宽裕，均未经代理验证。
- 交付测试包时必须同时说明：以上用例尚未完成真实环境验收。
