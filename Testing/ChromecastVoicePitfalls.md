# Chromecast 语音链路踩坑清单（2026-09-15 验收日）

按踩到的时间序记录，供后续回顾与避免。根因详情见
`Testing/ChromecastHardwareInterface.md` 的「根因 #1~#5」小节。

## 协议与固件

- **HTT 流进行中补发 `MIC_OPEN` 会被样机拆流**：本型号协商 `interaction=0x03`（HTT），
  远端按下即自行推流。规范 4.7.5 要求远端对打断只回 `MIC_OPEN_ERROR`，本机样机不遵守——
  直接拆流且此后零音频。HTT/PTT 下一律不补发 `MIC_OPEN`。
- **手势时长不是意图信号**：同一操作者「按一次」的自然时长在 1.1~5.8 秒间跳动
  （20 次采样），任何阈值（0.55s / 2.0s）都误伤且误伤方式是「立刻结束收音」。
  模式语义应由显式开关决定；连按防抖（latch 后 0.6s 内的再按不作为「关闭」）安全得多。
- **固件固定窗口是软件不可修的硬边界**：物理按下 → 固件上报按键（Δ，日志不可测）→
  再 ~330ms 才送首个音频帧（前两帧还是静音填充）。窗口内说的话遥控器根本没发，
  表现为「按下即说丢 1~3 字」。排查丢字先用「按住 2 秒沉默后再说话」的对照实验
  分离固件窗口与宿主问题。
- **轻点（<1s）固件完全不上报事件**：所有上报手势 ≥1.1s（vRemoter 真机日志同样），
  「轻点没反应」不是宿主 bug。
- 松键后 30~60ms 有一条幽灵 `opcode=0x04`（reason 非 0x03），Arbiter 静默忽略，无害。

## 音频链路

- **音频出口引擎会启动失败且无自愈**：AVAudioEngine 偶尔 startup 时没起来（`engine_running=false`），
  之后每次 REBIND 都无法恢复，`enqueue_failures` 恒等于 `audio_batches`（100% 丢弃）。
  对策：链路就绪即预热（`reason=chromecast_link_ready`），别等首次按键。
- **BlackHole 型环回设备没有回放缓冲**：写入端（宿主写虚拟设备输出端）比读取端（输入法
  打开输入流）先启动，读端开流之前写入的数据直接消失。对策：音频预卷缓冲——会话开头
  0.5s 先攒在宿主内存，到期一次性排入 AVAudioPlayerNode（按实时消费排队 buffer，
  不会倾倒覆盖 ring），读端开读时从人声开头读到。代价是识别出字整体晚 0.5s。
  已验证：豆包转写与宿主录音完全一致。
- **远端 HTT 流按人声门控（VAD）**：按下即开麦，但检测到人声才推帧（首帧距按下
  230~330ms）。按下期间没人声就是 0 帧，不是缺陷；「按住能用、按一次不能用」的观感
  差异来自说话时机，与按键时长无关。

## 工程与验证方法

- **`strings` 验证二进制对 Swift 短字面量完全失效**：≤15 字节的字符串字面量被
  small-string 优化编码成指令立即数（`debounced`、`hold_release` 均搜不到），险些误判
  「改动没编进包」。验证编入用 `nm` 查 mangled 符号，或搜 >15 字节的日志/中文长字面量；
  资源文案要搜 `.lproj` 资源文件而不是主二进制。
- **构建源必须核验包含目标提交**：`git merge-base --is-ancestor <commit> HEAD`；
  同一包/仓被并行会话编辑时用 `git worktree add --detach` 出已提交副本隔离构建，
  提交时只 add 自己的文件。
- **宿主自己的诊断目录不能用来断言第三方应用**：`Transcripts/` 为 0 条 ≠ 豆包没出字
  （那只是文本快照抓取）。第三方行为的证据以用户观察 + 录音资产等直接产物为准，
  用户的实测观察优先于间接证据。
- **按键页档案选择**：设备档案注册后必须 `selectRemoteProfile`（与小米链路的
  `activateRemoteProfile` 对齐），否则按键页停留在上一次选中的遥控器画布。
- **用户换音频设备环境会引入新变量**：戴着蓝牙耳机（默认输入+输出）测试时，语音输入
  激活可能把耳机切到免提（HFP）模式，输出变呲呲白噪声——与软件改动无关。
  排查「新出现的声音/现象」先问「这次和上次的设备环境有什么不同」。

## 硬件真伪

- **当前用于真机实验的 Chromecast 遥控器是假冒品**（2026-09-15 确认）。本文档与手册中
  所有「固件行为」结论（330ms 推流窗口、VAD 门控、<1s 轻点不上报、幽灵 0x04、拆流不回
  `MIC_OPEN_ERROR` 等）均基于该假冒品的实测。**之后需要换真货重新验证**，上述结论在真货上
  可能不成立，验收前先确认手里的遥控器是否为正品。

## HID 按键链路

- **manager 级独占打开会被系统拒绝**：`IOHIDManagerOpen(manager, kIOHIDOptionsTypeSeizeDevice)`
  返回 `kIOReturnNotPrivileged(0xE00002C1)`，桥永远不就绪、按键事件零到达（按键映射完全失效）。
  正确结构（对齐小米链路 `HIDRemoteMonitor`，真机验证过）：manager 用 `None` 打开只做设备发现
  与报告回调，在设备匹配回调里对**每个匹配的 HID collection** 执行
  `IOHIDDeviceOpen(device, seize)`——该遥控器暴露多个 collection，只独占第一个时其余的媒体
  用法仍会被系统消费（确认键会打开「音乐」）。
- **设备级 seize 在这台（假冒）遥控器上同样被拒**（同错误码，而小米链路同调用成功）。
  疑因：本地包反复重签名后输入监控 TCC 绑定失效，或假冒设备接口差异。已实现降级：
  seize 失败 → `IOHIDDeviceOpen(None)` 观察模式打开（`seized=false`），报告仍能驱动按键
  映射，代价是系统同时消费按键。若要恢复独占，先到「系统设置 → 隐私与安全性 → 输入监控」
  重置授权再试；换正品遥控器后重验。
- **最终结论（2026-09-15 19:40）**：观察模式（非独占打开）下 HID 报告回调**一次都不触发**
  （加了逐条日志实测，用户按多个按键 report 行为 0）——macOS 不向非独占客户端发送输入报告；
  而独占（seize）在 manager 级与设备级都被 `NotPrivileged` 拒绝。**同一进程对小米遥控器
  （HIDRemoteMonitor）的 seize 是成功的**，排除进程/TCC 权限问题 → 这台假冒遥控器的蓝牙
  HID 通道不允许 macOS 独占采集，**按键映射在该设备上不可用**，换正品遥控器是唯一解。
  语音链路（ATVV over BLE GATT 通知）不受影响。输入监控里加「无线麦.app」授权也无济于事。

### 正品遥控器实测（2026-09-16，替换假冒品后）

- **正品可被独占采集**：`CHROMECAST HID phase=connected mode=mapped seized=true`，管理级与设备级
  seize 均成功——假冒品做不到（两级都被 `NotPrivileged` 拒绝）。**seize 能力差异是真伪的判据之一**。
- **报告格式**：`reportID=0x01 len=3 head=01 XX 00`（首字节是 reportID，第二字节 usage，
  第三字节 0），与 `ChromecastHIDUsage` 表完全对得上（0x06=right / 0x08=mute / 0x0a=home /
  0x0e=youtube）。按键映射执行链路 `CHROMECAST ACTION phase=completed result=dispatched` 正常。
- **seize 不足以阻止系统消费按键**：正品在 `seized=true` 下，静音/左右等键仍会触发系统原本行为
  （系统静音、焦点移动）。必须叠加第二道保险——与小米/苹果链路一致，在按键边沿调用
  `hidEventSuppressor.arm(nativeEvents:edge:)` 让 CGEventTap 吞掉随之到达的原生事件。
  **Chromecast 链路此前漏了这一步（HID FILTER 从未启动）**，修复见 build 186。

### 正品按键的原生事件实测表（2026-09-16，`HID FILTER arm/miss/suppressed` 日志为证）

| 按键 | 通用表（小米 RC003） | 正品 Chromecast 实测 | 结果 |
| --- | --- | --- | --- |
| 音量 +/− | `systemKey(0/1)` | `systemKey(0/1)` | 抑制命中（`suppressed`），无系统副作用 |
| **静音** | `systemKey(3)` | **`systemKey(7)`** | 沿用通用表必然 miss → 系统音量 HUD 照常出现 |
| 方向（上/下/左/右） | `keyCode 126/125/123/124` | 系统侧**不产生事件** | tap 零记录，无副作用，无需抑制 |
| 确认（OK） | `keyCode 36` | 系统侧**不产生事件** | 同上 |

- 修复：静音按设备单独映射 `chromecastNativeEvents(for:)`（build 190）。
- 教训：**通用 `RemoteButton.nativeEvent` 表是小米 RC003 的实测值，换遥控器必须重新实测**；
  诊断「抑制无效」时，命中与未命中都要留日志（`suppressed`/`miss`），只看 miss 会漏掉
  「键码完全对不上」的情况。**注意区分「自定义动作效果」与「系统原本功能」**——本次
  用户报告的「左/右/OK 也执行了原本功能」，实为自定义动作 arrowLeft/returnKey 在特定 App 里的
  效果，系统侧并无事件。

### 按键「自定义动作 + 系统原本功能同时执行」的根因：Apple 配件协议（AACP，2026-09-16）

症状：正品遥控器上左右键切歌、OK 播放/暂停、静音出音量 HUD，**同时**自定义映射正常执行。
对照实验：**键盘方向键不切歌**（排除「注入方向键在音乐 App 里的效果」这一解释）。

ioreg 取证（VID 0x18D1/PID 0x9450）：

```
"Transport" = "BT-AACP"                  ← Apple 配件协议
"HIDVirtualDevice" = Yes                 ← Apple 给配件暴露的虚拟 HID
"PrimaryUsagePage" = 0xFF0C（Apple 私有）
"InputReportElements" = ReportID 1(24bit，Array) / 4(8bit) / 8(168bit)
"DeviceOpenedByEventSystem" = Yes
```

- 报告是 **Array** 类型（字节=usage 索引）：索引 5/6/7 在系统眼里是 **Menu Up/Down/Left**，
  索引 2 是 **Play/Pause**，8 是 Mute，12/13 是 Volume ±。
- 系统配件服务（AACP）**直接**消费这些 usage → 媒体/导航行为，
  **不经 CGEvent**（cghid 层只读探针实测零记录）、**不是标准 HID 客户端**（`seized=true` 也拦不住）、
  **不读 HID 设备属性**（`hidutil --set HIDDefaultBehavior=0` / AppleVendorSupported 均无效）。
- 我们的读取只是 Apple 为配件暴露的虚拟 HID 旁路——**能读，不能阻止系统那一侧**。

可用/不可用手段一览：

| 手段 | 结果 |
| --- | --- |
| `IOHIDDeviceOpen(seize)`（设备级独占） | ❌ 只挡标准 HID 客户端 |
| CGEventTap 吞事件（session / cghid 两层） | ❌ 事件不经过 CGEvent |
| `hidutil` 改设备属性 | ❌ 行为由 AACP 服务控制 |
| 静音/音量键的抑制 | ✅ 例外：这两个 usage 恰好产生 NX_SYSDEFINED（走 CGEvent） |
| DriverKit 系统扩展（Karabiner 方案） | ⚠️ 理论可行，需安装驱动 + 用户批准，工程量大 |
| 系统蓝牙中移除设备 | ⚠️ 会同时失去虚拟 HID 报告源（按键数据也没了） |

**结论**：这是 macOS 对 Apple 配件协议遥控器的系统级行为，用户态 App 无法拦截。
需要产品决策：接受现状，或投入 DriverKit 扩展方案。

**补充（2026-09-19，新款遥控器 + 豁免开关实测后）**：最后一种未试过的用户态手段——
`hidutil` **UserKeyRemapping**（usage 级重映射，consumer 0x44/0x45/0x41 → F13/14/15）——也已验证无效：
按 VID/PID、全局、`Transport=BT-AACP` 三种 matching 写入，回读均为 `(null)`，属性根本挂不到
AACP 侧的虚拟 HID 事件服务上。至此用户态手段全部穷尽（seize / CGEventTap 两层 /
hidutil 设备属性 / hidutil usage 重映射），结论不变：**要消除三键的系统侧行为只有 DriverKit
系统扩展（Karabiner 方案）一条路**。三键在 App 内的自定义映射一切正常
（`CHROMECAST ACTION result=dispatched` 全部命中）。

系统副作用的实际边界（2026-09-19 用户实测更正）：**不只在播放时**——OK 键（Menu Left）被
AACP 当作播放/暂停，**没有媒体会话时会拉起音乐 App**；左/右（Menu Up/Down → 上一首/下一首）
只在有播放会话时可感知。因此三键的代价不同：左/右 = 播放时切歌；OK = 任何时候拉起音乐。
据此把豁免做成按键级（`chromecast.systemReservedExceptions`，CSV），可按键取舍。

### 补充：参考实现要点与「删除系统配对」实验结论（2026-09-16）

参考文档：私有包 `packages/audio-input-kit/chromecast/Referance/google-tv-remote.md`
（Vokie `google-tv-remote-helper` 的实机记录），可直接采纳的结论：

- **HID 采集不可靠**：该设备的 HID 接口被 macOS HID 事件服务占用，用户态
  `IOHIDDeviceOpen`（含 seize）拿不到输入；文档明确**禁止**再用 IOHID 回调采集其按键。
  按键的权威路径是**蓝牙 GATT 通知**（新款 A0：中间键 `0x0029` 值 `07 00 00 00 00 00 00 00`、
  返回键 `0b 00 …`、语音键 `0x003f` 值 `04 03 02 xx`；旧款 hid_mouse 表不通用）。
- **「轻点无反应」的真因是深度休眠**：遥控器闲置数分钟后短按无任何上报，
  需**长按任意键约 3 秒**唤醒（唤醒期第一个按键被设备自己消耗）。
  另有「已连接但不上报」假死态：取电池 5 秒或系统蓝牙删除重配可恢复。
  → 本文档早前「固件不上报 <1s 按键」的说法应以此更正。
- **语音音频走 GATT（0x003c/0x0054）**：IMA ADPCM 16 kHz / 4 bit / 128 字节帧、无帧头、
  编码器每次语音会话重置（我们的 ATVV 实现与之等价，可作交叉验证）。
- **移除系统配对不可行（2026-09-16 实测）**：本仓库 `ChromecastAdapter` 早就注释过
  「已被系统持有的遥控器不再广播，`scanForPeripherals` 永远发现不了它」，只能靠
  「系统已连接的设备」取回。删除配对后设备既不广播也不在系统列表 → App 完全够不着，
  **语音链路一并失效**，实测确认。排查此类问题前不要动系统配对；恢复方法是系统蓝牙
  重新配对（同时按住 Home + Back 3~5 秒进配对模式）。

#### 逐键对照：我们的映射 vs 系统的 standard consumer usage（2026-09-16 实测确认）

| 我们的映射 | 报告字节（Array 索引） | 系统眼里的 usage | 系统行为 | 可否拦截 |
| --- | --- | --- | --- | --- |
| left | 0x05 | Menu Up `0x44` | 切歌（上一首） | ❌ 不走 CGEvent |
| right | 0x06 | Menu Down `0x45` | 切歌（下一首） | ❌ |
| ok | 0x07 | Menu Left `0x41` | 播放/暂停 | ❌ |
| mute | 0x08 | Mute `0xE2` | 系统静音 | ✅ `suppressed sys7` |
| volume ± | 0x0C/0x0D | Volume ± `0xE9/0xEA` | 无异常 | ✅ `suppressed sys0/1` |
| up/down | 0x03/0x04 | Menu `0x42` / Menu Pick `0x43` | 待测 | 预期 ❌ |
| home/back | 0x0A/0x0B | AC Home `0x0223` / AC Back `0x0224` | 待测 | 预期 ❌ |

- 结论：**同一物理键被两套语义解读**——我们按 vRemoter 实测字节值映射（正确），系统按 HID 描述符的
  标准 consumer usage 解读（Menu Up/Down/Left → 媒体控制）。出问题的三键都是标准媒体/导航 usage，
  能拦的静音/音量恰好走 NX_SYSDEFINED（CGEvent）通道——**这是路径差异，不是键位差异**。
- **参考实现（Vokie）的对照**：它只映射「中间圆键=确认发送 / 返回键=撤销 / 花瓣键=录音」三键，
  其余（含方向键、音量键）**明确忽略并交给系统**——等于"避开"而不是"解决"。
  我们要求"所有键都归映射且不触发系统行为"，因此需要 DriverKit 级别的拦截。
- **DriverKit 可行性初判**：ioreg 显示该设备在 `IOHIDEventService` 层有 `AppleUserHIDEventDriver`
  + `IOHIDEventServiceUserClient`，正是 Karabiner-Elements 系列拦截的层级，因此技术路径存在；
  代价是需要自研 DriverKit 驱动 + 系统扩展授权 + 签名公证 + 后续系统版本维护（独立立项级别）。

#### 影响面结论：只有 left/right/ok 三颗键（2026-09-16 全键实机验证）

用户逐键验证后的完整结果：

| 分组 | 按键 | 系统 usage | 系统副作用 |
| --- | --- | --- | --- |
| **受影响（3 键）** | left / right / ok | Menu Up `0x44` / Menu Down `0x45` / Menu Left `0x41` | 切歌、切歌、播放暂停 |
| 可拦截（2 键） | mute / volume ± | Mute `0xE2` / Volume `0xE9/0xEA` | 已抑制（走 CGEvent） |
| 无副作用 | ↑/↓ | Menu `0x42` / Menu Pick `0x43` | 无 |
| 无副作用 | back / home | AC Back `0x0224` / AC Home `0x0223` | 无 |
| 无副作用 | power / youtube / netflix / input | `0x019E` / `0x77` / `0x78` / `0x89` | 无 |

- **规律**：只有 **Menu Up / Menu Down / Menu Left** 这三个「方向性 Menu usage」被系统映射为媒体控制
  （上一首 / 下一首 / 播放暂停）；Menu、Menu Pick、AC Back/Home 等都不会。
- **影响面很小**：三键，且只在音乐/视频播放时才会被察觉。
- **现实可行的缓解（配置层规避）**：把最常用的自定义动作挪到无副作用的键上，
  受影响的三键按需使用——不需要任何代码改动。
- 根治仍需 DriverKit（见上一节的可行性初判）。

### 「按一次说话」（toggle 持续收音）在正品上失败（2026-09-16，build 198→199）

现象：**按住说话正常，按一次说话时豆包电平图不动**（用户实测）。

日志判据（同一实例 build 198，`ATVV` 全链路）：

```
[按住] 远端自行推流：STREAM START reason=0x03(HTT) → 松键 STREAM STOP reason=0x02(physicalVoiceKeyReleased)
[按一次] 松键 → 宿主 latch → MIC_OPEN written(0c00) → STREAM STOP reason=0x02
         → 之后**没有任何宿主发起的流**：当天 39 条 STREAM START 全是 reason=0x03
         → 远端不推流 = 无音频 = 豆包电平图不动
```

- **对照（假冒品，09-14/15）**：`MIC_OPEN written` → `STREAM STOP` → **`STREAM START reason=0x00
  stream=0 origin=hostRequested`** → 音频连续（该机型累计 54 次 host-requested 流建立）。
  → **主动请求持续流在假冒品上可行，在正品上从未成功**（当天 0 次）。
- 两条独立原因都会造成失败，build 199 同时处理：
  1. **时序**：松键那一刻远端正在收尾它自己的 `AUDIO_STOP`，宿主在同一毫秒发 `MIC_OPEN`
     是抢跑 → 先静默 `openSettleDelay = 0.25s` 再发；
  2. **写成功但远端不回**：旧实现只在传输层写失败时重试，`pendingLatchRequest` 会一直挂着，
     界面显示「持续收音中」而远端根本没推流 → 新增响应超时重试
     （`openResponseTimeout = 0.4s`，最多 `maximumOpenWriteAttempts = 3` 次），
     用尽后记 `ATVV MIC_OPEN no_response` 留证。
- **若重试仍无流** → 判定该硬件为 **HTT-only（不响应宿主 `MIC_OPEN`）**，
  「按一次持续收音」在协议层无法实现 → 应改为对该型号隐藏/禁用 toggle，只保留「按住说话」。
  判据就是日志里有没有 `origin=hostRequested` 的 `STREAM START`。

#### 结论：该型号 HTT-only，toggle 改为不提供（2026-09-18，build 199 验证 → build 200 落地）

build 199（延迟 0.25s + 超时重发）实测两次，用户按正确方式操作（短按一次、松手后立即说话、
8 秒内不再按键）：

```
04:57:04.493 ATVV MIC_OPEN written attempt=1 bytes=0c00
04:57:04.911 ATVV MIC_OPEN retry=2 reason=no_stream
04:57:05.327 ATVV MIC_OPEN retry=3 reason=no_stream
04:57:05.747 ATVV MIC_OPEN no_response attempts=3          ← 远端一次都没回
latch 期间 ATVV AUDIO notify = 1 条；audio_batches=24/11520 ≈ 0.36s（会话 9.5s）
全天 STREAM START 全部 reason=0x03 origin=remoteInitiated   ← 0 条 hostRequested
```

用户观感：「豆包电平图起来了（合成语音键 + 虚拟麦已打开），但一个字都没有」——电平图来自
宿主的合成语音键，文字要靠远端推流，而远端在松键后不推流。

- **判定**：本遥控器 `interaction=0x03`（HTT），规范 4.5.2 / 4.7.5 下宿主 `MIC_OPEN` 属于被
  禁止的打断，正品**直接忽略**（连 `MIC_OPEN_ERROR` 都不回）。**「按一次持续收音」在协议层
  无法实现**；按住期间音频正常（远端自行推流）。
- **产品处理：build 200 曾把「语音键模式」选择器摘掉、运行时钉死按住——这是错误的，已回退**
  （用户明确要求「按一次说话」是必须实现的功能，不得删除入口）。当前界面与设置照旧，
  模式仍由用户选择；未实现的是该硬件上的持续收音。
- **后续尝试（build 202~205）**：按规范用 `GET_CAPS` 的「宿主支持的交互模型」字段把模型切到
  On-request / PTT（二者都由宿主 `MIC_OPEN`/`MIC_CLOSE` 掌控麦克风，正是「按一次持续收音」）：
  - 声明 `0x00`（仅 On-request）→ 远端**不回应** `GET_CAPS`（两次尝试后回退 caps-less）；
  - 声明 `0x01`（PTT + On-request）→ 同样**不回应**；
  - 声明 `0x03`（含 HTT）→ 立刻应答 `CAPS_RESP raw=0b0100020300f001001a`，采用 HTT。
  **A/B 结论：该固件只在声明包含 HTT 时才完成能力协商**，即它拒绝离开 HTT；
  单方向切换模型的路走不通。On-request 的客户端语义已实现并保留（第 1 次按下开麦、
  第 2 次按下关麦），换到支持 On-request/PTT 的遥控器或固件即可直接生效。
- **与参考实现（vRemoter）的对照**：把同一台正品接到 vRemoter 上、用它的 Mac 端触发键
  （右 Option）发起开麦，日志为
  `TX micOpen requested by gesture` → `MIC_OPEN sent attempt=1/2/3` →
  `MIC_OPEN confirmation timeout` ×3 → `MIC_OPEN retries exhausted`。
  **vRemoter 的「短按切换」在这台正品上同样失败**（它的成功记录是 2026-09-14 的假冒品，
  设备 UUID `5B693D81…`；正品为 `CB1FC712…`）。→ 不是本仓库实现缺陷。
- **保留的能力**：build 199 的「延迟 0.25s + 超时重发 3 次」留在协议层——它对任何
  On-request 链路仍然必要，且 `ATVV MIC_OPEN no_response` 是判定「该设备是否支持宿主开流」
  的唯一判据。
- 注：本文档早前记录的假冒品 **54 次 `hostRequested` 流**说明「非同型号固件行为不可互推」——
  假冒品容忍了违规 `MIC_OPEN`，正品按规范拒绝。

#### 声明值可测：`/tmp/chromecast_declared_models`（2026-09-18，build 208→209）

规范 3：`GET_CAPS` 末字节是**宿主声明支持的交互模型**（`0x00` 仅 On-request、`0x01` PTT+On-request、
`0x03` HTT+PTT+On-request），远端在 `CAPS_RESP` 里回报它**实际采用**的模型——即模型由宿主声明、
远端选一个。这是唯一可能让远端离开 HTT 的入口，而「按一次持续收音」在 HTT 下不可能实现
（规范 4.5.3：HTT 松键即 `AUDIO_STOP`）。

**已证伪、不要重复的两条路径**：

1. **「跳过能力协商，让远端留在默认模型」**（build 208）：不发 `GET_CAPS` 时远端仍按 HTT 运行
   （`AUDIO_START reason=0x03`、松键 `AUDIO_STOP reason=0x02`），且拒绝 `MIC_OPEN`——说明它默认就是
   HTT，而不是规范 4.5 所述「连接后默认 On-request」。同期音频上行只覆盖两次按压窗口
   （stream 11/12/13 共 ≈1.75 s，按压之间的 5.15 s 零音频），与「松手后说话没有字」完全一致。
2. **「HTT 流进行中补发 `MIC_OPEN`」**：规范 4.7.4/4.7.5 规定远端只应回 `MIC_OPEN_ERROR(0x0F80)`，
   且**不得打断正在进行的流**——即便回的是错误码，也拿不到持续流。

**诊断开关**：`/tmp/chromecast_declared_models` 内容为 `00`/`01`/`03` 时覆盖声明值（默认 `0x03`）；
覆盖期间不再发 0x00 重协商探针（两条冲突声明会污染实验）。声明值同时进入**回退能力**——
远端在声明非 HTT 时完全不回 `CAPS_RESP`（实测），若回退退回 HTT，客户端就永远按 HTT 处理，
「声明 PTT 后按键会怎样」根本走不到。

**客户端已实现 PTT 语义（build 209）**：`AUDIO_START reason=0x01` 视为「语音键按下」→ 远端持续推流
（宿主每 4 s `MIC_EXTEND` 续期，规范 4.6.1 的音频传输超时 15 s~1 min）；**结束收音由宿主
`MIC_CLOSE(0xFF = 任意当前流)` 收尾**（规范 4.4：`0xFF` 可关任意流），因为 PTT 下远端不会因松键停流；
PTT 期间宿主绝不补发 `MIC_OPEN`。判定远端实际模型只看 `AUDIO_START reason`：`0x01`=PTT（松键不停流）、
`0x03`=HTT（松键即停流）。

### 与外部同款实现的对照（2026-09-18，build 210~212）

对照对象：`anyshu/vokie-plugin-chromecast-remote`（README 明示适配 **同一 VID/PID** `0x18D1/0x9450`
的 Google Chromecast Voice Remote，含 A0 / 26.2 与旧款 `hid_mouse`），即「别人能实现短按」的来源。

**逐条比对结果——写入帧集合与流程完全一致**：

| 项目 | 外部实现 | 本仓库 |
| --- | --- | --- |
| `GET_CAPS` | `0a 01 00 00 03 03` | 同 |
| `MIC_OPEN`（v1.0） | `0c 00`（播放模式） | 同（本次改为可参数化） |
| `MIC_CLOSE` | `0d <streamId>` | 同 |
| `MIC_EXTEND` | `0e <streamId>`（宿主流 4s、物理流 10s） | 宿主流 4s；**物理流此前不发** |
| 短按（tap）流程 | 松键 → `MIC_OPEN` → 1s 确认超时 ×3 → 失败即取消 | 同（延迟 0.25s、0.4s 超时） |
| 关流时机 | 每次手势收尾都 `MIC_CLOSE(<精确 id>)` | 只关宿主流；**物理流从不关** |

**本机逐变体实测（自动探针，无按键的干净链路）**：`0c 00` / `0c 01`（采集）/ `0c 00 02`（v0.4 payload）/
先 `0d ff` 再开 / 先 `0e ff` 再开 / 重复开 —— **6 个变体全部未建立宿主流**（判据 `AUDIO_START reason=0x00`
计数恒为 0）。远端唯一会推流的仍是物理按键（`reason=0x03`），且松键即停（`reason=0x02`）。

**由此新增的两条事实**：

- 这台设备的固件**不响应宿主 `MIC_OPEN`**（两种 mic mode 都忽略），因此「按一次持续收音」在这台
  设备上无法通过遥控器麦克风实现；外部实现的短按可用性来自**其手上的机型**（聊天中演示的
  天长天利达 A/B 款），其 spec 也自述「未因此次迁移获得 A0 真机长时间保活验收结论」。
- `MIC_CLOSE(0xFF)` 停不掉本机的物理流：远端会持续推流，**甚至跨 App 重启仍在推**（build 210/211
  日志可证）——本固件只认**精确 stream id**（规范 4.4 里 `0xFF` = 任意当前流，它没实现）。

#### 根因确认：物理流必须用「精确 stream id」关掉，`MIC_OPEN` 才被接受（2026-09-18，build 212→213）

**修复**：物理流（HTT/PTT）在 `AUDIO_STOP` 时，宿主用它的**精确 stream id** 补一条 `MIC_CLOSE`，
且必须在 latch 的 `MIC_OPEN` **之前**（`ChromecastAudioClient` 的 `.audioStop` 分支，build 213 起为默认行为）。

**机制**：不关流时遥远端一直停留在「助手键按下」状态，此后所有 `MIC_OPEN` 都被**静默忽略**——
连规范 4.7.5 要求的 `MIC_OPEN_ERROR(0xF80)` 都不回。这正是此前「远端从不响应宿主开麦」的真因，
也与外部同款实现（vokie-plugin-chromecast-remote）在每个手势收尾都用精确 id 关流的做法吻合。

**真机证据（build 212，用户实测「按一次说话 → 豆包出字成功」）**：

```
28.411  STREAM START reason=0x03 stream=50        ← 用户按下
28.579  松键 → MIC_CLOSE(stream=50) origin=physical_close  ← 新增动作：正式关掉这次会话
28.841  MIC_OPEN written bytes=0c01
28.879  STREAM START stream=51                    ← 立刻起来的流
   此后 7.1 秒无任何松键，音频连续（会话 117600 样本 = 7.35 s，普通按住最多 1~2 s）
36.814  用户第二次按下 → 松键 → 结束收音（audio_batches=245，正常排空）
```

- 更长的一次会话拿到 `audio_batches=948`（**28.4 秒连续音频**），说明「按一次持续收音」成立；
- 该固件把宿主 `MIC_OPEN` 换来的流仍报成 `reason=0x03`（不是规范里的 `0x00`），**判据要看行为
  （松键后是否继续推流），不能只看 reason 字节**；
- 回归用例：`testPhysicalStreamEndClosesWithExactStreamIDBeforeOpening`（私有包）。

**遗留的 A/B（未做，不影响功能）**：`MIC_OPEN` 的 mic mode 同时从播放（`0x00`）改成了采集（`0x01`），
两者在本机「未关流」状态下都被忽略；关流修好后是哪个模式在起作用尚未单独验证，当前取采集模式。

#### 「说完之后结束收音困难」＝宿主流的开通被误判成物理按下（2026-09-18，build 214）

现象（用户实测 build 213）：唤起、收音都顺利，但**说完后要按好几次才停得下来**。

日志（同一会话内两次「结束」各按了两次）：

```
10:39:10.827  STREAM START reason=0x03 stream=65 origin=remoteInitiated   ← 宿主 latch 的 MIC_OPEN 换来的持续流
10:39:13.692  STREAM START reason=0x03 stream=66                          ← 用户第 2 次按下（远端另起一条流）
10:39:13.917  MIC_CLOSE(66) + gesture duration_ms=3090 action=debounced   ← 被判成连按防抖 → 不结束 ✗
10:39:15.417  STREAM START reason=0x03 stream=67                          ← 用户第 3 次按下
10:39:15.597  MIC_CLOSE(67) + action=stop                                 ← 这一次才结束 ✓
```

另一次会话更极端：`gesture duration_ms=3181134`（53 分钟）——那条「过期的手势」从上一次 latch 一直挂到第二次按下。

**机制（两个缺陷叠加）**

1. 本固件把宿主 `MIC_OPEN` 换来的流**同样用 `reason=0x03` 上报**（与物理按下在字节上完全一致），
   客户端据此把它当成「一次新的物理按下」，创建了一个**永远等不到松键的手势**（这条流不会 `AUDIO_STOP`）；
2. 用户第 2 次按下时该手势仍在 → `gesture != nil` 让新按下被忽略，松键时沿用**旧手势**（其按下时刻
   就在 latch 前后 0.3 秒内）→ 落入连按防抖窗口 → `action=debounced`，会话保持；
3. 直到第 3 次按下（旧手势已被松键清空）才正常结束。

**修复（build 214）**

- `consumeHostStreamGrant()`：`MIC_OPEN` 写出后 `hostStreamGrantWindow`（1.5 s；实测远端回帧约 40 ms）
  内到达的 `AUDIO_START` 认作**宿主流的开通**，不派发 `physicalDown`。一次请求只消费一次，因此
  紧随其后的用户第 2 次按下仍按物理按下处理。日志新增 `ATVV MIC_OPEN accepted host_stream_granted`，
  该流的 `STREAM START` 记为 `origin=hostRequested`（不再伪装成 user press 的 `remoteInitiated`）。
- **结束收音的关流目标改为远端为宿主流分配的精确 id**（`hostRequestedStreamID`），不再用 `0x00`：
  本固件只认精确 id，`0d00` 发出去远端仍继续推流（用户观感「收音停不下来」）。
- 回归：`testHostRequestedStreamOnHTTReasonDoesNotSwallowTheEndingPress`——宿主流开通不得产生新手势、
  第 2 次按下必须立刻结束、关流必须用精确 id。
- 复测判据：结束那次按下应直接出现 `action=stop`（前面不再夹一条 `action=debounced`），
  且 `MIC_CLOSE written … origin=host_requested` 里的 stream id 与宿主流一致。

#### 遗留远端流会让按键「失灵」——必须清干净（2026-09-18，build 216）

现象：用户反馈「开始要按 2 次、结束也要按 2 次」；而同一时段的日志里，6 次会话**全部是「一次按下
即生效」**——说明问题发生在日志之外的那段时间。

根因链（build 215 新补的诊断抓到）：

- 上一实例被关闭时若**没有关远端流**，遥控器会把麦继续开着推流。实测：新实例就绪后 **30ms** 即收到
  240 字节音频帧，**持续 4 分 39 秒 / 9284 帧**（30ms 一帧，`ATVV AUDIO dropped_stream_absent`），
  直到用户第一次按下才停。该实例之前的一次会话（gen8）**开了就没结束**，遥控器在宿主未运行期间
  空推约 **14 分钟**（跨 App 存活）。
- 这种「助手键已按下 + 正在推流」的残留状态会让按键上报行为异常（用户感知的「要按 2 次」正出现在
  这段时间），同时浪费电量、且意味着无人使用时麦克风是开着的。

修复（build 216）：

- 断开链路**之前**先关远端麦（日志 `origin=host_shutdown`）；
- **持久化最后一个远端 stream id**（`UserDefaults`，键 `chromecast.lastRemoteStreamID`）：本固件只认
  精确 id（`0x00`/`0xFF` 都关不掉），App 重启后必须能拿回它才能关掉遗留流；
- 启动/连接后若检测到「宿主无会话却在推流」，用该 id 关闭一次并留证（`origin=stale_stream_cleanup`）；
- 该丢弃路径的日志改为节流（首 3 条 + 每 500 条），不再刷屏。

验证（build 216，用户连续 16 次会话）：全部「一次按下开始 + 一次按下结束」；
`dropped_stream_absent=0`（每轮结束后远端确实停流）、`down_deduped=0`、`down_no_intent=0`、
`gesture unmatched=0`、`small_notify=0`、`dropped_decode_empty=0`。

**排查教训**：遇到「按键反应不正常」，先看有没有 `ATVV AUDIO dropped_stream_absent` ——
它意味着远端有遗留流、状态不干净，此时任何按键现象的结论都不可靠；先清干净再测。

#### 「结束收音」后豆包面板不消失——结束逻辑没缺步骤，是 Fn 通道语义不匹配（2026-09-18 夜，build 219 现场）

现象（用户报告）：按一下结束 → 遥控器灯灭，但豆包语音面板（电平图）仍在；必须再按一下面板才消失，
而这时遥控器灯又亮了。用户怀疑「结束的逻辑有问题」，实测结论是：**结束逻辑一步不缺，缺的是「豆包是否
把这次松开当作结束」**。

日志事实（实例 pid 54307，6 次会话，12 次按键）：

- 每次结束，宿主侧步骤齐全、顺序正确、无失败：`MIC_CLOSE(精确 physical stream id)` →
  `MIC_CLOSE(0d00 origin=host_requested)` → 排空 `playback_stop phase=completed result=drained
  pending_before_buffers=0` → `VOICE KEY mode=fn edge=up` → `CHROMECAST VOICE phase=completed
  result=stopped`（`enqueue_failures=0`）；停止后 ATVV 音频帧计数不再增长（远端确实停流）。
- 12 次按键只对应 **6 次 Fn down + 6 次 Fn up**：一次「按下」落在 latch（会话开始），一次「松开」
  落在 stop（会话结束）。**每个会话只发一次 Fn 按下**。

直接实测（不依赖遥控器，工具见 `Testing/VoiceKeyFnPanelProbe.swift`）：

| 注入 | 豆包语音面板（豆包进程 layer=3 的窗口） |
| --- | --- |
| Fn 按下 | 出现（≤250ms） |
| Fn 松开（保持 2.5s） | **不消失** |
| 再按一次 | ~750ms 后消失 |
| 又按一次 | 再次出现 |

两种注入方式（`keyDown/keyUp` 与 `flagsChanged`）结果完全一致 → 与「我们怎么发 Fn」无关，
**当前生效的豆包语音键是「按一下开始 / 再按一下结束」（点按）语义，不理会松开**。

因果链（与用户描述逐条对应）：宿主「按一次开始、再按一次结束」只发一次 Fn down，于是豆包的开关
每 **两** 次按键才翻转一次：

- 第 1 次按下（会话开始）→ 豆包开麦、面板出现 ✓
- 第 2 次按下（宿主判为结束并补发 Fn up）→ 豆包不理会 → **面板不消失** ✗
- 第 3 次按下（下一次会话开始）→ 豆包按「按下」切换为关闭 → **面板消失**；同时遥控器因新会话亮灯 ✗

⇒ 用户说的「再按一下」其实已经是「下一次开始」；且豆包只录到**隔一个**的会话（另一半会话的音频
被丢弃，不会出字）——这是历史上「要按 2 次才生效」的强候选根因，值得优先复核。

判据与下一步（二选一，取决于**实体** Fn 键的行为）：

- 实体 Fn 长按、松开后面板消失 → 豆包是「长按模式」，问题在我们的注入不等价于真实 Fn
  （宿主自己的 Fn 监视器今晚 12 次注入 **0 次**观察到，而实体按键每次都能观察到）→ 去修注入，
  让它产生真正的修饰键转移。
- 实体 Fn 长按、松开后面板也不消失 → 豆包当前绑定的是「点按」模式 → 两条路：
  ①把豆包「长按模式」快捷键设为 fn、清空点按绑定（产品既有设计就是按住—松开）；
  ②宿主侧把 Chromecast 的 toggle 模式改为「成对 Fn 点按」驱动（仓库已有 Fn 点按机制可复用）。

排查纪律：遇到「结束后面板/收音不消失」，先用 `Testing/VoiceKeyFnPanelProbe.swift` 量一次
「按下 / 松开 / 再按下」三态，确认豆包当前是长按还是点按语义，再决定改哪一侧；不要先改宿主结束逻辑
（本案例里它是完整的）。

#### 「结束收音」后豆包面板不消失——根因是语音键语义与豆包模式不匹配（2026-09-18，build 220 修复）

现象（用户报告）：按一下结束 → 遥控器灯灭、豆包语音面板（电平图）不消失；再按一下 → 面板消失，
但遥控器灯亮（那一次已经是下一个会话的开始）。

**先说结论（三态判据）**：宿主结束逻辑一步不缺——每次结束都完成 `MIC_CLOSE(精确 physical id)` →
`MIC_CLOSE(0d00 host_requested)` → 排空 → `VOICE KEY edge=up` → `phase=completed result=stopped`，
`enqueue_failures=0`，停止后 ATVV 帧计数不再增长。问题在**语音键语义**：宿主对目标工具只有一条通道，
即模拟 Fn；而目标工具分两类，语义相反：

| 豆包模式 | 语义 | 对「按下」 | 对「松开」 |
| --- | --- | --- | --- |
| 长按模式 | 按住说话，松手结束 | 开始收音 | **结束收音** |
| 免按模式 | 按一次开始说话，**再按任意键结束** | 切换（开↔关） | **无任何作用** |

**决定性实测（不需要遥控器）**：`Testing/VoiceKeyFnPanelProbe.swift` 按 `postKeyState` 同法注入 Fn，
每 250ms 采样豆包 layer=3 面板窗口：

```
Fn 按下            → 面板出现
Fn 松开（等 2.5s） → 面板仍在        ← 免按模式忽略松开
再按一次           → ~750ms 后消失
又按一次           → 再次出现
```

两种注入方式（`keyDown/keyUp` 与 `flagsChanged`）结果一致，说明与注入细节无关，是**目标工具的模式**决定的。

**因果链（与用户描述逐条对应）**：宿主 toggle 模式一个会话只发**一次**按下，于是豆包的状态每**两**次按键
才翻转一次——第 2 次按键（我们判定的「结束」）被忽略，第 3 次按键（下一次开始）才让它关闭。
⇒ 用户看到的「必须再按一下」就是下一次开始；同一机制还让豆包只录到**隔一个**的会话。

**修复（build 220/221）**：`ChromecastFunctionKeyDrive` 把语音键驱动分成两态，驱动方式由
**遥控器自己的语音模式 + 目标工具是否支持长按**推导（单一事实源：
`Sources/RemoteMic/VoiceInputCapabilityMatrix.swift` 与公开仓 `remote/遥控器与输入工具能力矩阵.md`）：
- `taps`：遥控器「按一次说话」；或工具根本不吃长按（Typeless）——开始一次点按、结束再一次点按；
- `hold`：遥控器「按住说话」且工具支持长按——开始按下、结束松开。
Chromecast 页面**不再出现**「语音键模拟 Fn 点按」：那个开关只为「只能按住收音」的遥控器
（小米/苹果 + Typeless 这类工具）存在。开始的点按必须自己松开，否则 Fn 修饰位在整个会话期间被按住
（用户此时打字会变 Fn 组合键）。

**接线盲区（build 220 一并补上）**：该开关此前只接在**小米蓝牙**链路（`VoiceFnTapSessionController` 的调用点
全在 `bluetoothVoice*`），Chromecast 的 ATVV 语音链路**从未读取它**——所以开关开着也不生效。
现在 `beginChromecastVoice` / `completeChromecastVoiceStop` 走同一套驱动决策，日志留痕
`CHROMECAST VOICE fn_drive=taps phase=start_tap|start_released|stop_tap`。build 221 起该驱动
不再读那个开关，改由能力矩阵推导（界面对应地不再在 Chromecast 页面显示它）。

**排查纪律**：报告「结束不生效」时，先问目标工具当前是哪一种模式（豆包设置里就是这两个开关），
再用探针量三态，最后才动代码——本次若先猜「关流/排空/防抖」都会改错地方。

#### 「left/right/select 被系统占用」的豁免开关（2026-09-19，build 224）

旧款遥控器真机实测：这三颗键的 HID usage 是 Menu Up/Down/Left，macOS 配件服务（BT-AACP）
在 CGEvent 之外直接消费成媒体控制，用户态无法拦截——因此默认置灰 + 运行时跳过
（`ChromecastRemoteControl.systemReservedControls`）。

该结论是**按遥控器型号/固件而定**的，不是协议常态。新款遥控器是否真的被系统占用只能真机验证：
`defaults write com.hd838a.RemoteMic chromecast.allowSystemReservedKeys -bool YES` 后重启，
画布三键不再置灰、运行时不再跳过（`CHROMECAST ACTION result=system_reserved` 不再出现）。

判据：若系统仍在消费 → 按一下出现**双执行**（App 自定义动作 + 系统媒体控制各一次），
此时应关回开关；若无系统反应且自定义动作正常 → 该遥控器可以接管，考虑按能力位放开。
