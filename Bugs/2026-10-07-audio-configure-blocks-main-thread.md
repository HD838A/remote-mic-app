---
title: 音频重配在主线程访问 mainMixerNode 导致 App 长时间无响应
subtitle: 官方 hang 采样锁定 HAL 查询与引擎递归锁互等
lang: zh
template: doc
theme: shadcn
---

## A 结论

App 在音频重配过程中于**主线程**访问惰性属性 `AVAudioEngine.mainMixerNode`。
该访问触发 AVFAudio 同步下探到 Core Audio HAL 查询，经 `HALC_ProxyObject` 阻塞在 `mach_msg` 等待 `coreaudiod` 回复。
主线程因此无法服务 AppKit 事件，App 表现为「程序没有响应」。

同时，音频引擎的 I/O 绑定变更线程持有等待方指向主线程的引擎内部递归互斥锁。
即使 HAL 查询返回，引擎也可能无法自行解开，**卡死不限于单次查询耗时**。

用户运行版本为 `1.9.21 (174)`。该版本的空闲重绑循环修复尚未包含在发布版本中，
因此用户现场存在「高频重绑 → 高频访问 HAL → 命中驱动无响应」的放大条件。

本 Bug 独立于空闲重绑循环：**即使循环被切断，真实拔插外接音频设备仍会在主线程走到同一行**。

## B 错误证据

### 用户现场

- 用户报告 App 多次「程序没有响应」，Mac CPU 占用 25%、风扇变响；用户未记录发生时刻，也未留意具体触发动作。
- 现场系统：`macOS 27.0.1 (26A434)`，Apple Silicon `Mac16,10`，16 GB，10 核。
- 现场 App：`1.9.21 (174)`，`Team ID L3QHLDRPAY`，安装于 `/Applications/SayAll.app`。
- 现场遥控器为小米蓝牙语音遥控器，选中输出为 `MiRemoteV 2ch`。

### 官方 hang 采样

证据来源是 macOS 生成的 hang 报告（`Report Version 73`），不是用户自行分析：

- `Event: hang`，`Duration: 775.72s`，`Duration Sampled: 4.10s`。
- `Steps: 41`，采样间隔 100ms，报告记录采样前已无响应 772 秒。
- `Note: Unresponsive for 772 seconds before sampling`。

主线程 41 个采样点**全部**落在同一条调用链：

```
-[NSApplication run]
 └ _dispatch_main_queue_drain                    ← 主线程正在执行派到主队列的音频任务
   └ [RemoteMic 符号缺失 4 帧]
     └ -[AVAudioEngine mainMixerNode] + 60
       └ AVAudioEngineImpl::GetOutputNode
         └ AVAudioEngineImpl::UpdateOutputNode(bool) + 712
           └ -[AVAudioNode outputFormatForBus:]
             └ AVAudioIONodeImpl::GetOutputFormat
               └ AVAudioIOUnit::GetHWFormat + 176
                 └ _dispatch_lane_barrier_sync_invoke_and_complete
                   └ AVAudioIOUnit_OSX::_GetHWFormat + 544
                     └ AVAEHalUtil::GetSubDevices + 88        ← HAL 枚举子设备
                       └ AudioObjectGetPropertyDataSize_mac_imp
                         └ HALC_ShellObject::HasProperty
                           └ HALC_ProxyObject::HasProperty
                             └ mach_msg → mach_msg2_trap         ← 19/41 样本停在此
```

阻塞点是 `AVAudioEngineImpl::UpdateOutputNode` 内部的跨线程同步栅栏。
栅栏另一侧经 `AVAEHalUtil::GetSubDevices` 走到 HAL 代理的 `HasProperty`，
在 `mach_msg` 上等待 `coreaudiod` 回复且始终未返回。栈上没有应用自身的计算循环。

### 引擎内部互斥锁

另一线程在全部 41 个采样点停在：

```
invocation function for block in AVAudioEngineImpl::IOBindingChanged
 └ std::__1::recursive_mutex::lock
   └ __psynch_mutexwait
     └ psynch_mtxcontinue
       * (blocked by turnstile waiting for RemoteMic main thread)
```

等待方明确指向主线程。该线程 `last ran 1223.247s ago`，说明自阻塞起就不再获得执行机会。

### 与运行日志的交叉核对

用户同批提交的 `runtime.log` 记录 `1.9.21 build=174` 的 5 个进程实例。
其中两个实例**没有** `APP STOP` 与 `observers_stopped`，即非正常终止：

| 实例 | 最后一条日志 | 正常退出标记 |
| --- | --- | --- |
| 89903 | `APP STOP` | 有 |
| 90106 | `APP STOP` | 有 |
| 94350 | `AUDIO CONFIGURE begin` | 无 |
| 35717 | `AUDIO REBIND begin` / `AUDIO CONFIGURE begin` | 无 |

两个实例都停在 `AUDIO CONFIGURE begin` 之后，且都没有配对的 `AUDIO READY`、
`AUDIO CONFIGURE failed` 或 `AUDIO REBIND finished`。这与栈上位置一致：
阻塞发生在 `CONFIGURE begin` 之后、`READY` 之前。

### 用户现场存在空闲重绑放大条件

同一份 `runtime.log` 在无语音、无播放状态下记录到音频恢复自维持闭环：

- `AUDIO RECOVERY begin reason=engine_configuration_change` 共 234 次，另有 `hardware_change` 18 次。
- 单分钟峰值 47 次（`14:23Z`），持续区间 `14:17Z`–`14:26Z`。
- 每圈形态为 `RECOVERY begin → REBIND → CONFIGURE → READY → REBIND finished → RECOVERY completed → ENGINE configuration_changed`。
- 全程 `engine_running=false`、`bound_to_selected=true`。

该形态与 `2026-09-05-idle-audio-rebind-loop.md` 记载的闭环逐字段吻合。

## C 根因

`Sources/RemoteMic/AudioOutput.swift` 的 `configureVirtualAudioOutput` 在主线程构造并配置引擎：

```swift
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: sourceFormat)   // ← 阻塞点
```

`mainMixerNode` 是惰性属性，首次访问会触发 `AVAudioEngineImpl::UpdateOutputNode`。
该调用通过同步栅栏下探到 HAL，属于**等待驱动 IPC 的同步调用**，返回时间不由应用控制。
把它放在主线程上，一旦 `coreaudiod` 或其代理插件无响应，主线程即被无限期占用，AppKit 无法派发事件。

同一函数内还有多处同类同步调用，同样位于主线程路径：
`ensureVirtualAudioDeviceAudible`、`engine.outputNode.audioUnit`、
`AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`、`engine.prepare()` 与 `engine.start()`。

### 与空闲重绑循环的关系

`2026-09-05-idle-audio-rebind-loop.md` 的修复（PR #362，`bb35d95b` 等，2026-09-29）只切断重绑循环的**触发**，
没有切断「一旦触发就阻塞主线程」。该文档的「未覆盖」已写明：
真实 CoreAudio 接线（需要真实 `AVAudioEngine`）从未验证。

用户运行版本发布于 `v1.9.21`（`d291e076`，2026-09-03），**早于**该修复。
现场同时缺少「不触发」与「不阻塞」两侧保护，属于放大条件成立。

真实拔插外接音频设备同样会走到该行，因此**本 Bug 在修复发布后依然存在**。

## D CPU 与风扇的归因边界

采样报告否定了「高 CPU 导致无响应」的推断：

| 指标 | 值 |
| --- | --- |
| `Total CPU Time` | 9.873s（进程整个生命周期，`Time Since Fork: 18588s`） |
| 主线程 `CPU Time` | 1.392s（4.1s 采样窗口内） |
| `Fan speed` | 2718 rpm → 2829 rpm（+111） |
| `ThermalPressure` | 0 |
| `Combined` advisory level | 2 |

进程总 CPU 时间极低，与阻塞等待一致，**不符合忙循环或 CPU 过载**。
「风扇变响」幅度也较小。

用户报告的「Mac CPU 占用 25%」**不能由本 App 解释**。
hang 报告的 `Binary Images` 显示该进程只加载 `CoreAudio`、`AVFAudio`、`AudioToolboxCore`，
未加载任何第三方音频插件；报告正文亦指出同批采样的 1Password 各进程均处于空闲状态。

因此「CPU 25% / 风扇响」与「App 无响应」应作为两个独立现象处理，不得合并归因。

## E 证据缺口

以下内容**尚未确认**，不得当作结论：

- 阻塞的是哪一路 HAL 代理未知。候选包括 `MiRemoteV 2ch`、聚合设备与外接显示设备麦克风；
  采样时的完整设备清单未记录，也无法从 hang 报告反推。
- 是否存在严格意义上的永久死锁未知。41 个采样点只证明「持续 772 秒不返回」，
  采样窗口本身仅 4.1 秒，不足以断言永不返回。
- `runtime.log` 中 4 次 `AUDIO CONFIGURE failed reason=set_current_device error_code=1852797029`
  （`0x6E6F7065`，ASCII `nope`）与本次 HAL 无响应是否同源，未确认。
- 两份材料不能按同一进程对齐。hang 报告 `Time Since Fork: 18588s`（约 5.2 小时）与
  `runtime.log` 中最后一个实例的存活时长（约 4.8 小时）不匹配，
  采样的可能是更早启动的实例，或运行日志存在轮转丢段。
- hang 报告原文在 300,000 字节处被截断，尾部不完整。
- 未取得崩溃报告；本次事件是 hang，不是 crash。

## F 修复方向

以下为待办方向，本次**未实施任何修复**：

| 位置 | 待办变化 |
| --- | --- |
| `Sources/RemoteMic/AudioOutput.swift` | 把 `mainMixerNode` 惰性访问、`outputNode.audioUnit`、`AudioUnitSetProperty`、`prepare()`、`start()` 移出主线程 |
| `Sources/RemoteMic/BridgeAppModel.swift` | 确认重绑入口的队列归属，并记录切换前后的线程标识 |
| `LOGGING.md` | 为音频重配增加线程标识与耗时字段，使阻塞可从日志直接识别 |
| `Testing/AudioConfigurationChangeRecovery.md` | 增加真实 `AVAudioEngine` 主线程阻塞用例 |

任何修复都必须先让「同一用例从失败变为通过」，并覆盖真实设备拔插与语音会话期间配置变化。

## G 验证边界

- 本次只做只读调查，未修改产品代码、测试、配置或依赖版本。
- 未运行构建、测试或发布脚本。
- 未取得用户现场设备的实时复现，本 Bug 依据官方 hang 采样与运行日志确认。
- 未定位具体 HAL 代理，也未验证修复后行为；修复尚未实现，因此无回归验证。
- 未做真机长时间运行、真实拔插与语音会话期间配置变化的现场验收。
- 未验证修复发布后用户现场条件消失；用户需升级到包含修复的版本后复测。
- 本文档不声称已完成真机验收。
