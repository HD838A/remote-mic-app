# 实体遥控器按需占用虚拟声卡测试

## 背景与目标

旧行为：只要实体遥控器保持连接，无线麦就持续绑定所选虚拟音频设备（如 `MiRemoteV 2ch`），系统默认输入若指向该虚拟设备，第三方语音 App 会一直采集它。部分用户反馈这会让 Mac 正常播放语音或视频时音量被压得特别小。

新行为（本手册验证对象）：默认改为**按需占用**——遥控器空闲连接时不绑定虚拟声卡；收到语音键按下（`STREAM_START`）后立即绑定并使用；语音松开后延迟约 2 秒释放，并把系统默认输入从虚拟设备切回物理麦克风。启动参数 `--virtual-audio-keep-alive` 或 `defaults write <bundle-id> VirtualAudioKeepAliveEnabled -bool true` 可恢复旧的常驻行为。

## 适用版本或分支

- 分支：包含「实体遥控器按需占用虚拟声卡」改动的功能分支
- 平台：macOS 14 及以上
- 设备：RC001、RC003 实体遥控器；手机分支回归需 iPhone App 或网页版
- 虚拟设备：`MiRemoteV 2ch`（或 `BlackHole 2ch`）

## 测试前准备

1. 安装并在无线麦中选择 `MiRemoteV 2ch` 作为语音输出。
2. 把 macOS 系统默认输入设为 `MiRemoteV 2ch`，并配置一款真实语音工具（豆包输入法 / 微信输入法）。
3. 打开一个持续播放的语音或视频（浏览器或本地播放器均可），作为「音量是否被压低」的观察对象。
4. 打开 `~/Library/Logs/RemoteMic/runtime.log`，记录每个用例的开始与结束时间。
5. 确认 `APP START` 行包含 `virtual_audio_keep_alive=false`（默认按需模式）。

## 用例 1：空闲连接不占用虚拟声卡

1. 启动 App 并连接遥控器，不按语音键，等待 10 秒。
   - 预期：日志出现 `AUDIO ON_DEMAND startup_release` 与 `AUDIO RELEASE completed reason=startup_on_demand_idle`（或启动后无 `AUDIO READY` 常驻）；`AUDIO REBIND deferred reason=bluetooth_ready`。
2. 观察正在播放的视频/音乐音量。
   - 预期：与未运行无线麦时一致，没有被压低。
3. 用「音频 MIDI 设置」观察 `MiRemoteV 2ch`。
   - 预期：设备存在，但无线麦未保持音频 IO 运行。

失败判定：空闲连接 10 秒后引擎仍常驻（日志显示 `engine_running=true` 持续存在），或播放音量仍被明显压低。

## 用例 2：按下语音键快速建立链路并成功上屏

1. 在目标输入框聚焦后，按住语音键说一句话，松开。
   - 预期：日志顺序出现 `AUDIO HEALTH stale reason=bluetooth_voice_start` → `AUDIO REBIND finished reason=bluetooth_voice_start success=true` → `ATVV STREAM accepted` → `ATVV AUDIO routed ... accepted=true`。
   - 预期：整句话完整上屏，首字不缺失。
2. 重复 10 次短句输入。
   - 预期：每次都完整上屏；`ATVV STREAM summary` 中 `enqueue_failures=0`。

失败判定：任何一次首字或首词缺失、`enqueue_failures>0`、或 `AUDIO REBIND` 失败导致 `ATVV STREAM rejected_audio_output`。

## 用例 3：松开后延迟释放并恢复播放音量

1. 说完一句话松开语音键，开始计时。
   - 预期：约 2 秒后日志出现 `AUDIO ON_DEMAND release_due reason=bluetooth_voice_stopped` → `AUDIO RELEASE completed`；若系统默认输入是虚拟设备，出现 `AUDIO DEFAULT_INPUT fallback_applied`。
2. 释放完成后观察播放音量。
   - 预期：几秒内恢复正常音量。
3. 再次按下语音键。
   - 预期：出现 `AUDIO DEFAULT_INPUT restore_applied`，系统默认输入恢复为虚拟设备，语音正常上屏。

失败判定：松开 5 秒后仍未释放；释放后音量不恢复；或再次按压后默认输入未恢复、语音无法上屏。

## 用例 4：连续快速按压不抖动

1. 以小于 2 秒的间隔连续进行 5 段语音输入（说—松—立刻再按）。
   - 预期：每段开始时日志出现 `AUDIO ON_DEMAND release_cancelled trigger=ensure_bluetooth_voice_start`（复用未释放的引擎），不出现反复 `AUDIO REBIND` 或音频设备来回切换。
   - 预期：每段完整上屏，尾音不被截断。

失败判定：连续按压期间出现释放/重建竞争导致的丢音、上屏缺尾字，或默认输入设备来回跳动。

## 用例 5：尾音不被释放截断

1. 说一句较长的话，语速在句尾放慢，松开语音键。
   - 预期：`AUDIO PLAYBACK drained ... pending_buffers=0` 出现在 `AUDIO ON_DEMAND release_due` 之前；句尾最后一个词正常上屏。

失败判定：句尾字词经常丢失，或 `AUDIO PLAYBACK interrupted` 在正常松开路径上出现。

## 用例 6：keep-alive 兜底开关恢复旧行为

1. 退出 App，执行 `defaults write <bundle-id> VirtualAudioKeepAliveEnabled -bool true`（或用 `--virtual-audio-keep-alive` 启动），重新启动并连接遥控器。
   - 预期：`APP START` 行包含 `virtual_audio_keep_alive=true`；连接后出现 `AUDIO REBIND finished reason=bluetooth_ready success=true` 并保持常驻；语音停止后不出现 `AUDIO ON_DEMAND release_scheduled`。
2. 验证语音输入正常后，删除该键并重启，确认回到按需模式。

失败判定：开关开启后仍按需释放，或开关关闭后仍常驻。

## 稳定功能回归项

- 试音按钮：空闲时点击试音，能按需建立输出、播放试音，结束后释放（`AUDIO RELEASE ... reason=test_tone_finished`）。
- 遥控器断连：语音空闲时断连/重连流程与 `Testing/BluetoothDisconnectAudioRelease.md` 结论一致。
- 合盖/锁屏：与 `Testing/MacIdleSleepAudioRelease.md` 结论一致；挂起期间按需释放不重复触发。
- iPhone/网页版语音：手机分支语音开始/结束的按需建立与释放行为不回退（原有按需门禁）。
- RC003 长语音（如启用 `--rc003-voice-extension-test`）：分段续接期间不得触发按需释放。
- 长录音：长录音开始/结束路径正常，结束后按需释放。

## 日志收集方式

- 运行日志：`~/Library/Logs/RemoteMic/runtime.log`，关键前缀 `AUDIO ON_DEMAND`、`AUDIO RELEASE`、`AUDIO REBIND`、`AUDIO DEFAULT_INPUT`、`ATVV STREAM`。
- 每个用例记录开始/结束本地时间，便于按时间段截取。

## 验证边界

- 自动化已覆盖：`VirtualAudioConnectionLifecycleTests`（按需/常驻策略、松开后延迟释放与各入口取消释放的源级校验）、`MobileVoiceLifecycleTests`（手机语音生命周期在按需参数下的策略）、全量 438 项单元测试通过。
- 自动化不能覆盖：真实遥控器按压到上屏的首字/尾字完整性、系统默认输入切换对第三方语音 App 的实际影响、播放音量是否恢复。用例 1–6 必须在真实设备上执行后才能视为验收完成。
- 「播放音量被压低」的根因与第三方 App 对虚拟设备的采集方式有关，属外部不可观察状态；本手册只验证无线麦侧不再默认占用虚拟声卡及默认输入按需切换，不承诺所有第三方组合下音量必然恢复。
