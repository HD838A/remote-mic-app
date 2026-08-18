# MiRemoteV 音频通道自动恢复测试

## 适用版本或分支

- 分支：`codex/fix-miremotev-audio-stale`
- 平台：macOS 13 Intel 与 macOS 14+ Apple Silicon
- 音频设备：`MiRemoteV 2ch`
- 语音来源：RC001/RC003、iPhone、Apple Watch、Web

## 测试前准备

1. 安装候选 App 和对应架构的 MiRemoteV 2ch，确认系统“音频 MIDI 设置”可见该设备。
2. 在无线麦SayAll.app中选择 MiRemoteV 2ch，并准备系统录音工具及至少一款第三方语音工具。
3. 第三方工具分别测试“跟随系统默认输入”和“明确选择 MiRemoteV 2ch”。
4. 打开 `~/Library/Logs/RemoteMic/runtime.log`，为每个用例记录准确开始、结束时间。
5. RC001/RC003 用例使用真实遥控器；移动端用例分别使用真实 iPhone、Apple Watch 和浏览器。

## 用例 1：连续语音基线

1. 使用 RC003 连续执行 10 次短语音和 1 次至少 2 分钟的长语音。
2. 每次确认文字工具都收到完整输入，松开后尾音没有被截断。
3. 检查每条 `ATVV STREAM summary` 的 `enqueue_failures=0`，并确认最终出现 `AUDIO PLAYBACK drained`。

预期：无需主动 `MIC_OPEN`，`STREAM_START → AUDIO → STREAM_STOP` 每次都可用；没有 `AUDIO HEALTH stale` 或非预期重绑。

失败判定：任一次无声、首字或尾音丢失、缓冲持续不排空、出现 enqueue failure，或需要手动重新选择设备。

## 用例 2：播放器/路由异常后的自动恢复

1. 保持遥控器已连接，依次切换系统默认输入、默认输出，插拔 USB/蓝牙音频设备，并修改 MiRemoteV 2ch 可用的采样率设置。
2. 每次系统状态稳定后立即开始一次遥控器语音。
3. 检查日志是否先出现 `AUDIO HEALTH stale` 或 `AUDIO ENGINE configuration_changed`，随后出现成功的 `AUDIO REBIND finished`。

预期：首次语音开始前自动恢复，用户不需要进入设置页重新选择 MiRemoteV 2ch；恢复最多影响开始前的短暂等待，不丢弃已经开始的整段语音。

失败判定：日志仍把 `player_playing=false` 记为 healthy、语音缓冲显示 accepted 但工具无声、恢复循环，或必须手动重选设备。

## 用例 3：睡眠与锁屏唤醒

1. 遥控器已连接且语音基线正常时，让 Mac 睡眠至少 1 分钟后唤醒。
2. 重复锁屏、等待 1 分钟、解锁。
3. 每次唤醒或解锁后立即执行一次短语音，再执行一次 30 秒语音。

预期：语音开始门禁检测实时 engine/player/device 状态；如已 stale，先自动重绑再接收语音。全过程无需重新选择设备。

失败判定：唤醒后第一段或后续语音无声、App 显示就绪但 `player_playing=false`、反复重绑，或第三方工具必须重新选择输入。

## 用例 4：多语音来源

1. 断开实体遥控器，依次从 iPhone、Apple Watch、Web 开始和停止语音。
2. 每个来源重复 5 次短语音，并在来源之间完全停止后切换。
3. 制造一次音频路由变化后，再分别启动三个来源。

预期：每个来源开始前执行同一实时健康门禁；异常时成功重绑，来源互斥和停止逻辑保持不变。

失败判定：任一来源因缓存的旧 ready 状态无声、一个来源的恢复污染另一个来源、或停止后仍占用通道。

## 用例 5：第三方 App 缓存边界

1. 同时打开系统录音工具和第三方语音工具，都选择 MiRemoteV 2ch。
2. 触发用例 2 或用例 3 的音频变化，然后开始语音。
3. 比较两个消费者是否同时恢复；再把第三方工具改为系统默认输入复验。

预期：系统录音工具和第三方工具都恢复。如果只有第三方工具无声而系统录音正常，在该工具内重新选择输入并记录工具名称、版本和时间段。

失败判定：所有消费者都无声且宿主没有发现 stale，或宿主恢复后系统录音仍无声。

注意：只有单个第三方 App 持有旧输入流不代表宿主自动恢复失败；macOS 没有通用接口强制其他 App 重开输入流。

## 稳定功能回归

- 蓝牙最后一只遥控器断开后仍按原逻辑释放虚拟音频；另一只遥控器在线时不释放。
- RC001 短语音尾包完整；RC003 普通路径无需前置主动 `MIC_OPEN`。
- 测试音、长录音、Fn 轻触、iPhone/Watch/Web 语音均可开始和停止。
- 无任何语音来源时，硬件变化不会无条件重新占用 MiRemoteV 2ch。
- App 退出后不保留音频 IO；设置中的其他回环设备仍可选择。

## 日志收集

1. 复制 `~/Library/Logs/RemoteMic/runtime.log`，只保留测试时间段也可以。
2. 记录 Mac 型号、芯片、macOS、App 版本/Build、MiRemoteV 版本、遥控器型号和第三方工具版本。
3. 重点搜索：`AUDIO HEALTH`、`AUDIO ENGINE`、`AUDIO REBIND`、`AUDIO WRITE`、`ATVV STREAM summary`、`AUDIO PLAYBACK`。
4. 不提交语音内容；日志本身不应包含用户语音、设备身份凭据或 Token。

## 自动化、代理实测和用户实测边界

- 自动化验证 stopped-player 与错误设备绑定会被判定为不健康，并覆盖原有虚拟音频生命周期策略。
- 代理实测使用真实 AVFoundation 对象证明 `engine=true / player=false` 状态可达，但没有模拟真实 MiRemoteV HAL 或用户反馈机器。
- 睡眠唤醒、真实 CoreAudio 设备变化、RC001/RC003、iPhone、Apple Watch、Web、最终听感和第三方 App 收音必须按本手册进行真实环境验收。
