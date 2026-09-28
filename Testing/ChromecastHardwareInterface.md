# Chromecast 遥控器（ATVV）实机测试手册

## 适用范围

- 日期：2026-09-15。
- 目标硬件：Chromecast 语音遥控器（ATVV over BLE，广播名含 `Chromecast Remote`）。
- 当前状态：宿主接线已完成并通过自动化验证（协议、解码、仲裁、会话策略、语音键隔离）。本手册覆盖的**真机连接、语音链路与安装包验收尚未执行**，未通过前不得声明该硬件正式受支持。
- 第一版范围：**只做语音**。不含普通按键边沿、触摸面、电池状态；这些能力在代码里明确缺席，不得伪造。
- 跨平台基础约束见 [`Testing/HardwareCompatibilityContract.md`](HardwareCompatibilityContract.md)；语音完整性门槛见 [`Testing/HardwareVoiceAudioContract.md`](HardwareVoiceAudioContract.md)。本手册不重新定义通用行为，只增加该硬件的实机步骤。
- **与 Siri Remote 完全隔离**：两者互不 `import`、不共享全局状态、不共用语音键 owner。用户可能只有其中一个、两个都有，或都没有。

## 本地测试包

| 项目 | 值 |
| --- | --- |
| App | `/Users/andy/MySrc/remote-mic-app-chromecase/dist/SayAll.app` |
| 构建时间 | 2026-09-16 19:17（CST） |
| 配置 | Release，Apple Silicon `arm64`，最低 macOS 14.0 |
| 版本 | 1.9.21（197） |
| Bundle ID | `com.hd838a.RemoteMic` |
| 宿主源码基线 | 分支 `codex/chromecast-voice-hardware` 合并 `origin/main`（`bc19f79`）：PR #445 已并入 main（`e46348d`），本次再把 main 的 13 个新提交（Right Option 语音键、未连接设备时灰化状态栏图标、README 视频等）合入。基线 `origin/main` `014d2b2`。 |
| 私有包基线 | `SayAllChromecast` @ 私有仓 `main`（合并 `origin/main` `1c949ea`「merge Chromecast adapter package」后的 `0e7ec51`）；相对远端 main 的差异仅 3 个文件（`ChromecastMappingPage` / `ChromecastHardwareContract` / `ChromecastRemoteHIDBridge`，+59/−7）。 |
| 主程序 SHA-256 | `f277b8568cc22ab84b1e1bbb6aa189f7fb79209ab6f9737fe826df30a1694986` |
| 包体积 | 约 `15 MB` |
| 签名 | Developer ID Application `L3QHLDRPAY`；`codesign --verify --deep --strict` 已通过 |
| Info.plist 标记 | `SayAllChromecastIncluded=true`，其余可选组件均为 `false` |

### 隔离性验证（2026-09-16，build 197）

「加 Chromecast 是否影响小米 / Siri Remote」的核查证据（合并 main 后重新出包时执行）：

| 项目 | 结果 |
| --- | --- |
| 小米 / Siri 源文件改动 | **零改动**——`AppleSiriRemoteAdapter` / `SiriRemoteFeatureIntegration` / `SiriRemoteCursorFeedbackController` / `XiaomiBluetoothBridge` / `HIDRemoteMonitor` / `HIDRemoteScheduler` 均不在 diff 内 |
| 改动文件清单（相对 `origin/main`，共 8 个） | `Info.plist`、中英 `Localizable.strings`、`BridgeAppModel`（+36，全部在 chromecast 专属分支内）、`ChromecastFeatureIntegration`（+9）、`SettingsView`（chromecast 卡片移除 + 槽位文案）、`KeyboardEventSuppressor`（+122）、本手册与踩坑文档 |
| `KeyboardEventSuppressor` | **纯追加日志与只读探针**：`handle(type:event:)` 的所有 `return true/false` 判定与 main 逐行一致，未改抑制语义 |
| 测试 | 宿主 **583 项 / 45 套件全绿**（含 `RC003 hardware Fn mapping`、`Siri Remote cursor feedback`、`Remote buttons`、`Remote hardware input contract`）；私有包 106 项全绿 |
| 运行时（build 197 启动，实例 pid 95137） | Chromecast 正常（`seized=true`、`ATVV READY frame=240`、`AUDIO READY engine_running=true`）；小米链路照常被扫描并连接（`BLE CONNECTING name=小米蓝牙语音遥控器`、`HID UPDATE RECOVERY applied`），日志行与合并前各版本逐字一致；无新增错误行 |
| 私有仓影响面 | 相对远端 main 仅 3 个 chromecast 包内文件，未触碰会员中心等其他包/应用 |

> **同一台机器上还有一份 `/Applications/SayAll.app`（1.9.21 build 181，无 Chromecast）。**
> 它的构建号比本测试包更大，但没有 `SayAllChromecastIncluded` 标记，从启动台或 Spotlight
> 打开它**不会出现该遥控器**（没有 `SayAllChromecastIncluded` 标记）。测试必须显式打开本表的 `dist/SayAll.app`。
>
> 版本历史（每一步都对应一次真实缺陷）：
> - `bc0dac56…`（00:25）：缺少「取回系统已连接设备」的发现路径，遥控器一旦在系统蓝牙里配对上就连不上。
> - `b9f31c0e…`（01:01）：补上该路径，但设置页两项控件只写偏好、不推运行时；模式选项仍叫「点按开关」。
> - `8a35cbb8…`（01:18）：纳入设置同步修复与「按住说话 / 按一次说话」用语。
> - `4865dbe7…`（01:25）：只加了诊断日志。
> - 本版（01:28）：修掉**连错设备**——准入规则曾把「同一 ATVV 服务」当成型号身份，会连上
>   小米语音遥控器并在界面上显示「已连接」。旧包均已由构建脚本移入废纸篓。
> - 当前版（01:46，`e38b8b14…`）：修掉**语音流零音频**——HTT 交互模型下宿主补发 `MIC_OPEN`
>   被样机当成新请求，正在推送的流被拆掉。详见下文「语音流根因」。
>   01:50 已启动该版并确认连接阶段能产出新增证据行（`ATVV CAPABILITIES DETAIL … raw=…`、
>   `BLE LINK maxWriteNoResp=…`）；`ATVV AUDIO notify` 与 `ATVV MIC_OPEN skipped` 两行**需要按一次语音键**
>   才会出现，属用例 2 的待验项。
> - 02:03 复测（同一版，4 次**按住**）：`ATVV MIC_OPEN skipped reason=remote_initiated_stream` 已按
>   预期出现，但 `ATVV AUDIO notify` 仍为 0（`audio_batches=0`）。当时据此写下的「本型号的 HTT 流
>   本身不带音频」**已被 02:13 的复测推翻，不要沿用该结论**。
> - 02:13 复测（同一版，8 次点按 + 1 次按住）：8 次点按全是 **1.319~1.335 秒**、音频帧全为 0；
>   唯一成功的是 **4.470 秒的按住**——按住期间说话拿到 `audio_batches=100 audio_samples=49400`
>   并转文字成功。由此定位真正的根因是**长按阈值 0.55 秒在真机上不可达**：点按被判成 HOLD、
>   松键即结束，`MIC_OPEN` 在这 9 次操作里**一次都没写出去**。详见「根因 #2」。
> - `3243c4ef…`（02:24，1.9.21 build 175）：`holdThreshold` 0.55 → 2.0 秒，并新增
>   `ATVV VOICE gesture duration_ms=… judged=tap|hold mode=… threshold_ms=…` 留证。
>   02:24 复测**已确认点按路径是通的**（`audio_batches=139 audio_samples=68666`），
>   但 20 次按下里仍有 6 次被判成 hold（尤其 2070/2312/2328 ms 这几次只超阈值一点点）。
> - 当前版 `7ad2c4aa…`（09:15，1.9.21 build 176）：**彻底移除按键时长判定**——模式语义完全由
>   设置页开关决定，第 1 次按下松键一律进入持续收音、第 2 次一律结束，与按了 1.1 秒还是 5.7 秒无关。
> - 12:38 复测（同一版，AirPods 断开后）：**语音链路全通**——按下 230ms 内即有首帧
>   （`accepted=true`），松键 latch 后宿主流接上，`audio_batches=121 audio_samples=59774
>   enqueue_failures=0`。11:29 那轮的「无波动」根因是**音频出口引擎未运行**（与 AirPods 相关，
>   见「根因 #4」），与协议无关。同时证实**远端 HTT 流按人声门控（VAD）**，按下即说即有帧。
> - 用户随后反馈 AirPods 连接下也正常——根因 #4 的 AirPods 相关性**被削弱**，更可能是
>   「启动竞态：engine 在 startup 时没起来且后续 REBIND 无法自愈」，待复现定位。
> - 12:52 反馈「短按快放无法触发电平图」：根因 #5——latch 后 1ms 到达的第 2 按被 toggle
>   语义当成关闭。修复为连按防抖（0.6 秒窗口，见「根因 #5」，私有包 `d25948c`）。
> - 当前版 `401e1166…`（13:11，1.9.21 build 177）：含连按防抖。13:15 启动（pid 71447），
>   AirPods 连接下 startup 引擎即 `engine_running=true`，链路 `frame=247`。
>   **待真机确认：快速连按两下后说话，电平图应波动（第 1 按开启不被第 2 按关闭）。**
>   删除 `holdThreshold` 与 `lastGestureWasHold`；日志改为
>   `ATVV VOICE gesture duration_ms=… action=latch|stop|none mode=…`。详见「根因 #3」。
>
> ⚠️ 因此 01:18 那一版记录在案的真机证据（`frame=120`）**实际是小米语音遥控器的协商结果**，
> 不能当作 Chromecast 已验证。本型号的协商结果是 `frame=247`。

### 连错设备的教训（2026-09-15）

`AB5E0001-5A21-4F05-BC7D-AF01F617B664` 是**通用 ATVV 服务**，不是本品专有：同一仓库的
小米语音遥控器用的就是它。因此 `retrieveConnectedPeripherals(withServices:)` 会一次取回
**两台**遥控器；若把「服务存在」当成型号身份，就会连上错误的设备——界面显示「已连接」，
而真遥控器按语音键毫无反应。

区分设备只看 `name=` 与 `frame=`：

| 设备 | 名字 | 协商 frame |
| --- | --- | --- |
| Chromecast 语音遥控器（本型号） | `Chromecast Remote` | `247` |
| 小米蓝牙语音遥控器 | `小米蓝牙语音遥控器` | `120` |

正确的准入规则是**名字匹配优先**，名字存在但对不上就忽略（即使服务存在）；只有在完全没有名字
可用时才退回按服务采纳。冻结来源 vRemoter 1.1.1 正是这么做的（它的发现谓词把服务判断显式
丢弃，注释写明「多款语音遥控器会广播同一个 ATVV 服务 UUID」）。

### 语音流根因：HTT 下补发 `MIC_OPEN`（2026-09-15 01:32 真机）

现象：按语音键后豆包输入法的电平图**有反应但没有波动**；整段收音在日志里是
`CHROMECAST VOICE phase=completed … audio_batches=0 audio_samples=0`，录音资产只有 557 字节。

关键日志（`pid=83434`，一次 1.33 秒的按住）：

```
ATVV CONTROL source=control opcode=0x04 bytes=4      ← 远端 AUDIO_START(reason=0x03, codec=2, stream=14)
VOICE INTENT start generation=2
ATVV MIC_OPEN written attempt=1 generation=2         ← 宿主在 11ms 后补发 0x0c00
ATVV STREAM START reason=0x03 stream=14 codec=2 generation=2
ATVV CONTROL source=control opcode=0x04 bytes=4      ← 远端改发 AUDIO_START(reason=0x00, stream=0)
ATVV STREAM START reason=0x00 stream=0 codec=2 generation=2
…（此后 289ms 到松键，AB5E0003 上一个字节都没有）…
ATVV CONTROL source=control opcode=0x00 bytes=2      ← 远端 AUDIO_STOP(reason=0x02)
CHROMECAST VOICE phase=completed … audio_batches=0 audio_samples=0
```

对照 Google *Voice over BLE* 1.0 规范（来源文件 `Google_Voice_over_BLE_spec_v1.0.pdf`；
排查时提取的纯文本副本放在 `/tmp/atvv-spec.txt`，属临时文件，**不入库**——该 PDF 为 Google
发布的公开规范，许可证未随文说明，不放公共仓库），根因是**宿主在 HTT 流进行中补发了 `MIC_OPEN`**：

| 事实 | 规范出处 | 含义 |
| --- | --- | --- |
| `AUDIO_START.reason` 是**交互模型**，不是「谁按了键」 | 4.3.1 | `0x00`=`MIC_OPEN` 触发、`0x01`=PTT、`0x03`=HTT |
| `CAPS_RESP.interaction` = `0x00`/`0x01`/`0x03` | 3 | 本机样机协商值为 **`0x03`（HTT，按住说话）** |
| HTT 下「按下即发 `AUDIO_START` 并开始推流，松键即 `AUDIO_STOP`」 | 4.5.3 | 远端**自己**开麦，宿主只需消费 |
| HTT/PTT 进行中收到 `MIC_OPEN`，远端只应回 `MIC_OPEN_ERROR(0x0F80)`，**不得打断音频** | 4.7.5 | 宿主补发 `MIC_OPEN` 是非法打断 |
| `AUDIO_START` 的 `stream id`：`reason=0x00` 时固定 `0x00`，否则远端自增 `0x01..0x80` | 4.3.1 | 日志里 `14`→`15` 逐次自增，`0` 是宿主请求流的专用值 |
| `MIC_CLOSE`/`MIC_EXTEND` 的 `stream id`：`0x00`/`0x01..0x80`/`0xFF` 三类语义 | 4.4 | 关错了流只会被远端忽略 |

即：远端**已经在推** `stream=14` 的 HTT 流，宿主 11ms 后补发的 `MIC_OPEN` 让它改成了
`stream=0` 的宿主请求流，此后一个音频帧都不再来。规范假设远端会回 `MIC_OPEN_ERROR`
且不打断，本机样机不遵守这一点，因此**只能由宿主不补发**。

修复（私有包 `dbfdce9`）：

1. HTT/PTT（`reason=0x01`/`0x03`）下**不补发 `MIC_OPEN`**；只有 On-request（`startSearch`，`opcode=0x08`）
   与「点按保持持续流」两条路径才发 `MIC_OPEN`。
2. `MIC_CLOSE` 只关闭**宿主打开且尚未关闭**的流，`stream id` 用 `0x00`；远端发起的流由远端
   用 `AUDIO_STOP(0x02)` 自行停止，不再补发（多发的会被远端按 4.7.3 忽略）。
3. 续流改用 `MIC_EXTEND` 并按流来源取 `stream id`（宿主 `0x00`，远端用远端分配值）。
   规范 4.6.1 的「音频传输超时」建议 15 s~1 min，长按必须靠它顶回去。
4. 补上此前完全缺失的证据链（见下节新增日志行）。

> ⚠️ 修复前记录的 `audio_batches=0` 不能用来判断「远端没有推流」——当时 AB5E0003 上的通知
> 既没有计数也没有日志。修复后的日志会直接给出 `ATVV AUDIO notify count=` 与 `total=`。

### 根因 #2：长按阈值 0.55 秒在真机上不可达，toggle 的点按从未走到持续流（2026-09-15 02:13 真机）

修掉 #1 之后复测，用户按了 8 次仍是「有电平图、无波动」，**但改成按住就有波动、还转文字成功了**，
看起来像模式写反。日志（pid=87091）说明没有写反，只有一个阈值定错了：

| # | 按下时刻 | 时长 | 判定 | `ATVV AUDIO notify` |
| --- | --- | --- | --- | --- |
| 1–8 | 18:03:03 ~ 18:13:02 | **1.319~1.335 秒** | `reason=hold_release` | **0**（`dropped_phase=0`，可排除本地丢弃） |
| 9 | 18:13:05 | **4.470 秒** | `reason=hold_release` | **100**（`audio_batches=100`、`audio_samples=49400`、转文字成功） |

9 次全是 `mode=toggle`。第 9 次之所以成功，是因为**用户在整个按住期间都在说话**，远端那条 HTT 流
（`reason=0x03 stream=24`）在按键期间就推了音频（首帧延迟 330 ms，`head` 前两帧全零、第 3 帧起有数据）。
所以**「按住期没有音频」不成立**——那是上一轮只看到 1.3 秒样本得出的错误结论，此处更正。

真正的分界线是 `ChromecastVoiceArbiter.holdThreshold = 0.55` 秒：

```swift
case .toggle:
    if isHold { return finish(end: .holdRelease) }   // ← 8 次点按全掉进这里
    if gesture.recognitionWasOpenAtDown { return finish(end: .toggleSecondTap) }
    isLatched = true
    return [.latchStream(sequence: nextSequence())]  // ← 唯一会写 MIC_OPEN 的路径
```

操作者能做到的**最快点按是 1.32 秒**（8 次高度一致），永远 ≥ 0.55 秒，于是：

- 每一次「按一次」都被判成 HOLD，**松键立即结束识别**；
- 用户松手之后才说话，此时识别已关闭 → 零音频；
- `latchStream`（写 `MIC_OPEN`、请求宿主持持续流）这条**唯一能持续产音频的路径，在 9 次真机操作里一次都没被触发过**。

旁证（冻结来源 `~/Library/Logs/vRemote/vRemote.log`，2026-09-14，同一台 `remote=chromecast`）：

| 流 | 发起方 | 真机结果 |
| --- | --- | --- |
| `reason=0x00 streamID=0` | 宿主 `MIC_OPEN` | `AUDIO_FRAMES count=1→1600`，`recentPeak` **7919~10533**（真实人声，持续 30 秒） |
| `reason=0x03 streamID=42`，duration=**1.320 s** | 远端物理按住 | `frames=0 samples=0` ← 与我们那 8 次完全一致 |
| `reason=0x03 streamID=40`，duration=1.183 s | 远端物理按住 | `frames=11 peak=104 rms=27`（11 帧、静音级） |

即：**1.3 秒级的物理流在这台遥控器上确实拿不到有效音频，而宿主 `MIC_OPEN` 流能稳定拿到**。
所以修复方向不是「别按太久」，而是**让 1.3 秒的点按被判为点按**。

修复（私有包 `bdc27fe`）：`holdThreshold` 0.55 → **2.0 秒**（点按侧余量 0.68 s，按住侧余量 2.47 s），
并新增手势时长留证：

```
ATVV VOICE gesture duration_ms=1320 judged=tap mode=toggle threshold_ms=2000
```

修复后两种手势各归其位：

1. **点按**（< 2 秒，实测 ≈1.3 秒）→ TAP → 第 1 次松键即写 `MIC_OPEN`（`bytes=0c00`）→ 远端回
   `AUDIO_START reason=0x00 stream=0` → **松键之后持续有音频**，靠 `MIC_EXTEND stream=0` 续流，
   再点按一次才 `MIC_CLOSE`；
2. **按住**（≥ 2 秒）→ HOLD → 按住期间说话即有音频（第 9 次实测 100 批），松键结束。

> ⚠️ 不要把「按住」当本型号主路径：它虽然实测可用，但音频只覆盖按键时长、首尾易丢字；
> 可持续可续流的是点按之后的 `MIC_OPEN` 宿主流。

> 02:24 复测已验证这条路径是通的：`judged=tap` → `ATVV MIC_OPEN written bytes=0c00` →
> `ATVV STREAM START reason=0x00 stream=0 origin=hostRequested` → `ATVV AUDIO notify count`
> 一路涨到 250+，一次会话收尾 `audio_batches=139 audio_samples=68666`。
> 但阈值判定本身的问题也随之暴露，见下一条「根因 #3」。

### 根因 #3：时长判定本身是多余的（2026-09-15 02:30 真机）

上一版把阈值从 0.55 调到 2.0 秒后，点按路径确实通了。但真机复测的 **20 次按下里仍有 6 次被判成
hold**：

| 判定 | 次数 | 时长 |
| --- | --- | --- |
| `tap` | 14 | 1124 / 1125 / 1155 / 1305 / 1319 / 1320 ×4 / 1334 / 1335 ×2 / 1440 ms |
| `hold` | 6 | **2070** / **2312** / **2328** / 3030 / 5756 ms |

其中 2070 / 2312 / 2328 ms 只比 2.0 秒阈值超一点点——用户显然是想「按一次」，却被判成按住并在
松键时立即结束收音，收尾日志就是 `reason=hold_release audio_batches=0`（多次零音频）。用户原话：

> 「我们通过开关来控制是按住还是按一次了，不需要这个延迟判断。有了这个延迟判断，使用体验太差了。」

这个判断是对的：用户已经显式选定了模式，**时长不携带任何额外意图信息**——
「按一次」的自然时长在这台遥控器上在 **1.12~5.76 秒**之间跳动，那是人手抖动，不是信号。
任何阈值都只是把一部分正常操作误判掉，而它的误伤方式（松键即结束）恰好把用户随后说的话全部丢掉，
症状看起来像「功能没生效」，而不是「判定偏了」。

修复（私有包 `52e88ce`）——**彻底移除时长判定**：

```swift
case .toggle:
    if gesture.recognitionWasOpenAtDown {
        return finish(end: .toggleSecondTap)   // 第 2 次按下：关，与按多久无关
    }
    isLatched = true
    return [.latchStream(sequence: nextSequence())]   // 第 1 次按下：开，与按多久无关
```

- 删除 `holdThreshold`（0.55 与 2.0 两版阈值一并撤掉）与 `lastGestureWasHold`；
- `hold` 模式语义不变（按下开始、松键结束）；
- `lastGestureDuration` 保留，但只用于日志取证；日志由 `judged=tap|hold` 改为
  **`action=latch|stop|none`**——它直接说「这次松键做了什么」，比一个需要二次解释的判定值更有用。

> 教训：**能用显式开关表达的语义，别再叠一层启发式规则去猜。** 启发式规则在真机上必然误伤一部分
> 正常操作；这里它的误伤方式是「立刻结束收音」，把用户后续输入全部丢掉，症状被误读成「协议不通」，
> 白绕了两轮才定位到。

### 根因 #4：音频出口引擎未运行，远端音频被 100% 丢弃（2026-09-15 11:29 真机）

时长判定移除后复测（build 176），用户反馈「按一次后豆包电平图能显示但无波动」。ATVV 侧**完全正常**：
`action=latch` → `MIC_OPEN written bytes=0c00` → `STREAM START reason=0x00 stream=0 origin=hostRequested`
→ `ATVV AUDIO notify count` 涨到 850+。但三次会话的 `enqueue_failures` **恒等于 `audio_batches`**
（114/114、626/626、476/476），配套 98 条：

```
AUDIO WRITE rejected count=… reason=playback_not_ready state={engine_running=false player_playing=true …}
CHROMECAST AUDIO routed … accepted=false first_batch_samples=494
```

判据在 `AudioOutput.swift` 的 `VirtualAudioHealthPolicy.isPlaybackReady =
hasSelectedDevice && engineRunning && playerPlaying`——本会话 `engine_running` **124 次采样全为
false**（`player_playing=true`，即 player 起了但引擎没跑），所以每个音频包都被拒。
对照 175 版成功那次（同一路径）是 `engine_running=true`、`accepted=true`、`enqueue_failures=0`。

**强相关因素：默认输出是 AirPods 时引擎起不来。**

| 会话 | 默认输出 | `engine_running` | 结果 |
| --- | --- | --- | --- |
| 失败（03:23） | Andy AirPods Pro 3 | false ×124 | enqueue_failures=100% |
| 成功（昨日 18:24） | MacBook Pro 扬声器 | true | enqueue_failures=0 |
| 重启后（03:33，AirPods 已断开） | MacBook Pro 扬声器 | true | 正常 |

失败会话的输出列表里还多出一个 App 自建的 `CADefaultDeviceAggregate-<pid>-0`。
**是否 AirPods 必现、还是启动竞态，尚待复现定位**；但验收时若见
`enqueue_failures` 持续增长 + `playback_not_ready`，先查 `engine_running` 与默认输出设备，
**不要往协议层查**。

**12:38 复测（AirPods 断开后）全部通过**：`accepted=true`、`audio_batches=121
audio_samples=59774 enqueue_failures=0`，且**按下后 230ms 内即有首帧**
（用户按住期间说话）——同时证实了下述 VAD 结论。

### 远端 HTT 流按人声门控（VAD），不是按时长（2026-09-15 12:38 真机证实）

一个重要修正：曾根据「8 次 1.3 秒按下 0 帧、4.47 秒按住 100 批」推断「远端需要约 1.5 秒才真正
开麦、短按拿不到音频」——**这个结论是错的**，它把「按时长」当成了因果，实际差的是
「按住期间有没有人声」。决定性反例（pid=87091，18:13:05 那次 4.47 秒按住）：

```
18:13:05.169  STREAM START reason=0x03 stream=24   ← 按下
18:13:05.490  ATVV AUDIO notify count=1            ← 首帧距按下仅 321ms
```

以及 12:38 复测：按下后 **230ms** 内 `accepted=true`（用户按住期间说话）。

正确模型：**远端 HTT 流按下即开麦，但只在检测到人声时推帧（VAD 门控）**；没人声就一帧不发。
「按住能用、按一次不能用」的观感差异来自两种手势下说话时机不同，与按键时长无关。
由此得出验收判据：**判定「没波动」之前，先确认「按键期间/松键后有没有说话」**——
按下期间说话则远端流应有帧，松键后说话则宿主流应有帧；两者都没说话时零帧是正常的。

### 根因 #5：快速连按被 toggle 语义当成「开了立刻关」（2026-09-15 12:52 真机）

用户反馈「短按快放，无法触发豆包电平图」，并确认操作是**短按一下没反应、又按了一下**。
日志（04:51:46，generation=3 会话）：

```
04:51:46.381  按下 #1（stream=5）
04:51:47.708  松键 #1 → action=latch → MIC_OPEN written   ← 会话已开启
04:51:47.709  按下 #2（stream=6）                          ← 距 latch 仅 1ms
04:51:49.014  松键 #2 → action=stop                        ← 第 2 按把会话关了
04:51:49.027  completed audio_batches=0
```

toggle 语义本身没错（第 1 按开、第 2 按关），但**快速连按的两下之间不存在有意的「开了立刻关」**——
真想关的人至少会先说一句话。第 1 按其实已经成功开启持续收音，用户「没反应」是因为第 2 按紧跟着
把它关了。修复（私有包 `d25948c`）：**连按防抖**——

- `latchGraceInterval = 0.6` 秒：latch 之后 0.6 秒内到来的再次按下，整个手势标记
  `withinLatchGrace`，其松键**不执行 stop**、收音保持；
- 窗口判定用**按下时刻**与 latch 时刻的间隔（松键可能延迟很久才来）；
- 日志 `action=` 新增 `debounced`，区分「连按被防抖」与「无动作」；
- 窗口外的第 2 次按下（≥0.6 秒）仍正常关闭，防抖不得扩大成「一段时间内无法关闭」。

### 已确认（2026-09-15 01:29:01，本机真机）

遥控器已配对至系统蓝牙的前提下启动本包，链路在 **0.2 秒内**自动打通，**不需要先断开系统蓝牙**：

```
BLE SYSTEM CONNECTED CANDIDATES count=2 names=Chromecast Remote | 小米蓝牙语音遥控器
BLE SYSTEM CONNECTED ADOPTED model=chromecast-voice-remote
CHROMECAST CONNECTION state=connecting model=chromecast-voice-remote sequence=1
BLE CONNECTING source=connected_peripheral model=chromecast-voice-remote
BLE CONNECTED model=chromecast-voice-remote
BLE CHARACTERISTIC uuid=AB5E0002 props=write,writeNoResp
BLE CHARACTERISTIC uuid=AB5E0003 props=read,notify
BLE CHARACTERISTIC uuid=AB5E0004 props=read,notify
ATVV CAPABILITIES requested attempt=1
ATVV CONTROL source=control opcode=0x0b bytes=9
ATVV CAPABILITIES version=0x0100 codec=2 frame=247
ATVV CAPABILITIES DETAIL interaction=0x03 remote_mic=true raw=0b0100020300f70100
ATVV READY version=0x0100 codec=2 interaction=0x03 remote_mic=true frame=247 fallback=false
BLE LINK maxWriteNoResp=182 maxWriteResp=512
CHROMECAST CONNECTION state=available model=chromecast-voice-remote sequence=3
CHROMECAST LINK state=connected(displayName: "Chromecast 语音遥控器")
CHROMECAST STATUS Chromecast 语音遥控器 已连接
```

两条关键事实：
1. **ATVV 服务是通用的**：本机同时命中两台遥控器（`count=2`），身份只能由名字决定。
2. 该服务真实暴露**三个特征**，没有额外的按键通道——`…0002` write、`…0003` notify、
   `…0004` notify。语音键事件只可能从 `…0004` 来。

其中 `interaction=0x03` 与 `remote_mic=true` 是本型号语音链路的关键参数：它声明
**HTT（按住说话）** 交互模型，即远端按下语音键后**自己**开麦并推流（规范 4.5.3）。
`ATVV CAPABILITIES DETAIL` 的 `raw=` 是 9 字节原始 payload
（`opcode(1)+version(2)+codecs(1)+interaction(1)+frame(2)+extraConfig(1)+reserved(1)`），
按日志原样（无空格）摘录。2026-09-15 01:50 实测值为 `0b0100020300f70100`，即
`version=0x0100`、`codecs=0x02`、`interaction=0x03`、`frame=0x00f7=247`、`extraConfig=0x01`、`reserved=0x00`。
**这一行必须整段原样留证**，不要拿「协商值」去还原原始字节。

`BLE LINK maxWriteNoResp` 是本链路单包真实容量（≈ATT_MTU−3），要与 `frame=` 对照着看：
`frame=247` 大于该值时，远端「期望的包大小」在这条链路上无法整包发送。
但注意它**不是常数**：同一台样机 01:29 会话是 `182`、01:50 会话是 `244`（`frame` 始终 `247`），
说明每次连接的 ATT MTU 协商结果会变，每轮都必须重读，不能沿用上一轮的数字。

这证明：发现路径、BLE 连接、服务发现与 ATVV 能力协商（v1.0 / 16 kHz IMA ADPCM / 247 字节帧、
HTT 交互模型）在真实硬件上全部可用。**它不等于语音链路已验收**——用例 2 起的收音、首字、
尾字与异常路径仍待执行。

> 日志前缀分工：包内只写 `BLE …` 与 `ATVV …`；`CHROMECAST …` 全部由宿主写出。
> 因此排查协议问题看 `BLE`/`ATVV`，排查宿主接线与语音会话看 `CHROMECAST`。

**当前生效的语音键模式可以在日志里直接读到**，每次开始收音都会带上：

```
CHROMECAST VOICE phase=started result=triggered audio_source=chromecast_microphone route=MiRemoteV_2ch mode=toggle
```

末段 `mode=` 就是运行时实际采用的模式（`toggle` / `hold`），与界面选择应当一致；不一致即为接线缺陷。

此包只用于本机候选功能测试，不可作为正式发布包分发。

**它不需要任何 helper、LaunchDaemon、安装器组件或 root 授权**——ATVV 是标准 BLE GATT，标准用户即可。这与 Siri Remote（依赖私有 HCI 与 PacketLogger helper）是本质区别，因此本包用 ad-hoc 或 Developer ID 普通签名即可，不要求特权组件。

### 重新构建

```sh
cd /Users/andy/MySrc/remote-mic-app-chromecase
SAYALL_CHROMECAST_PACKAGE_PATH=/Users/andy/MySrc/sayall-private-platform/packages/audio-input-kit/chromecast \
CODE_SIGN_IDENTITY="Developer ID Application: lei qian (L3QHLDRPAY)" \
  ./scripts/build-app.sh
```

不带 `SAYALL_CHROMECAST_PACKAGE_PATH` 时，构建产物与未接入该硬件前完全一致（`SayAllChromecastIncluded=false`，界面不出现该型号的任何入口）。这是必须回归的约束。

⚠️ **`CODE_SIGN_IDENTITY` 必须显式给**：`build-app.sh` 里 `SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"`，
不传就打成 adhoc 签名，与历史真机包不一致（会引入额外的权限/授权变量）。

⚠️ **并行改包隔离**：若该私有包工作区正被另一个会话编辑（未提交的新文件与 `Package.swift` 改动），
**不要**直接指向工作区构建——那会把半成品打进真机包（本次就撞到：某次构建会因新文件用了
`Bundle.module` 而 `Package.swift` 尚未声明 `resources:` 直接编译失败）。改用已提交的干净副本：

```sh
cd /Users/andy/MySrc/sayall-private-platform
git worktree add --detach /private/tmp/chromecast-<shortsha> <commit>
cd /Users/andy/MySrc/remote-mic-app-chromecase
SAYALL_CHROMECAST_PACKAGE_PATH=/private/tmp/chromecast-<shortsha>/packages/audio-input-kit/chromecast \
CODE_SIGN_IDENTITY="Developer ID Application: lei qian (L3QHLDRPAY)" \
  ./scripts/build-app.sh
```

构建完成后用 `strings dist/SayAll.app/Contents/MacOS/RemoteMic | grep -c <并行开发的新类型名>`
确认产物里**没有**混入那些改动（应为 `0`）。用完 `git worktree remove /private/tmp/chromecast-<shortsha>`。

## 测试前准备

1. 退出其他无线麦SayAll.app 实例，只保留待测包。
   - 特别注意别打开 `/Applications/SayAll.app`（构建号更大但**不含 Chromecast**）。用
     `open /Users/andy/MySrc/remote-mic-app-chromecase/dist/SayAll.app` 显式打开本表那份。
2. 确认已安装 `MiRemoteV 2ch` 音频设备（侧边栏「连接」→「连接与语音」页的「音频输入与兼容」面板应显示已就绪）。本次不安装任何 helper。
3. 在侧边栏「设置」页的「权限与隐私」区授予蓝牙、输入监控和辅助功能权限，然后完全退出并重新打开 App。
4. 打开 `~/Library/Logs/RemoteMic/runtime.log`，保留现有文件，不清空、不覆盖。
   - 建议直接双击 `Testing/启动Chromecast真机测试.command`，它会实时过滤出本手册用到的日志行，并在桌面留一份会话记录。
5. 进入侧边栏**「连接」**（链接图标，页面标题「连接与语音」）：**左列的设备面板**显示当前遥控器、照片与三行状态（连接状态 / 语音状态 / 语音快捷），**「重新连接」按钮也在这块面板上**。
   - ⚠️ 侧边栏**没有**单独的「Chromecast 遥控器」面板，也没有总开关：总开关已按产品要求移除，**恒为常开**；语音键模式**不在这一页**，在「按键映射」页底部（见用例 2）。
   - 界面长相见 `Testing/artifacts/chromecast-layout/`（由 App 自带离屏渲染导出，非截图拼贴）：
     `connection-zh-Hans-light-1400x2000.png` 是「连接与语音」页，
     `mapping-zh-Hans-light-1400x2000.png` 是「按键映射」页——语音键模式在该页底部。两张图都按
     `REMOTE_MIC_SETTINGS_SCREENSHOT_*`（light / zh-Hans / 1400x2000 / `CHROMECAST=1`）导出。
6. 确认遥控器可被 App 发现。**这里有两种情况，都必须能连上**：

   | 情况 | 遥控器状态 | App 应走的发现路径 |
   | --- | --- | --- |
   | A | 未与 Mac 建立连接，正在广播 | `BLE SCANNING` → `BLE CONNECTING source=scan` |
   | B | **已在「系统设置 → 蓝牙」里配对/连接**（或已被系统当作 HID 设备占用） | `BLE SYSTEM CONNECTED CANDIDATES` → `BLE SYSTEM CONNECTED ADOPTED` → `BLE CONNECTING source=connected_peripheral` |

   情况 B 是被动出现的：BLE 设备一旦与主机建立连接就**停止广播**，只靠扫描的链路会永远停在
   「正在搜索遥控器」。App 必须能取回系统已连接的设备并主动连上它。

   ⚠️ 情况 B 有一个必须核对的点：**ATVV 服务是通用的**，本机若同时接着小米语音遥控器，
   `BLE SYSTEM CONNECTED CANDIDATES count=` 会是 `2`。此时必须确认紧接着那句
   `ATVV CAPABILITIES … frame=` 是 **`247`**；如果是 `120`，说明连上的是小米遥控器，
   本遥控器的语音键不会产生任何事件（见上文「连错设备的教训」）。
7. 状态应从「正在搜索遥控器」变为「已连接」。**没有 `state=available`、或 `frame=` 不是 `247`，
   就不要往下测。**
8. 若长时间停在「正在搜索遥控器」，先看日志：
   - 完全没有 `BLE DISCOVERED UNMATCHED`、也没有 `BLE SYSTEM CONNECTED CANDIDATES`：遥控器既没广播、也没被系统连接，多半是没唤醒或不在配对模式。
   - 有 `BLE DISCOVERED UNMATCHED name=...`：设备在广播但名字对不上，记下该名字（匹配规则冻结自 vRemoter，不得擅自放宽）。
   - 有 `BLE SYSTEM CONNECTED CANDIDATES count=1 names=小米蓝牙语音遥控器`：只有小米那台被系统连接，本遥控器需要先唤醒或重新配对。

## 隔离组合

| 组合 | 期望行为 |
| --- | --- |
| 只有 Chromecast | 该遥控器可被发现、连接与收音；Siri Remote 相关界面与代码路径完全不存在（本包 `SayAllSiriRemoteIncluded=false`）。 |
| 两个都有 | 两套链路各自独立工作；同时收音时语音键按引用计数保持按下，互不取消。 |
| 都没有 | `SayAllChromecastIncluded=false`，界面不出现该型号入口，启动、运行、打包与未接入前一致。 |

## 实机测试矩阵

### 用例 1：连接、重连与设备识别

1. 启动 App，等待状态从「正在搜索遥控器」变为「已连接」。
2. 在「连接」页左列的设备面板上点「重新连接」。
3. 关闭再打开遥控器，观察是否自动恢复。
4. **系统已连接场景**：在「系统设置 → 蓝牙」里把遥控器连上（或先移除再重新配对），回到 App 点「重新连接」。

预期：状态依次经过 `discovering → connecting → available`；重连期间活动收音必须先被结束。日志出现 `CHROMECAST LINK state=` 与 `CHROMECAST CONNECTION state=available`。

第 4 步的发现路径必须是 `connected_peripheral`，不是 `scan`：遥控器被系统连上后**不再广播**，扫描不可能发现它。若这里只有 `BLE SCANNING` 而没有 `BLE SYSTEM CONNECTED ADOPTED`，说明该发现路径失效——这正是本用例要盯的回归点。

**同时必须核对连上的是本型号**：`ATVV CAPABILITIES … frame=` 应为 `247`。若为 `120`，说明采纳了同协议的小米语音遥控器，本用例不通过。

失败判定：状态长期停在「正在搜索」；或断连后仍显示已连接；或第 4 步只能靠先断开系统蓝牙才能连上；或 `frame=` 是 `120`。

### 用例 2：toggle 模式——按一下开始、再按一下结束（默认模式）

确认语音键模式为「按一次说话」：在侧边栏**「按键映射」**页底部（选中本遥控器档案时才出现该区）。

1. **点按**遥控器语音键（按下后立刻松开，**全程短于 2 秒**；真机实测最快约 1.3 秒），
   **松键之后**再说一句话，说完停顿几秒（**先不要**再按）。
2. 观察录音/识别是否持续进行（这正是与 Siri Remote 的核心差异）。
3. 再点按一下语音键结束。

预期：
- 第 1 次按下即开始收音，且**不结束**；用户可见"正在收音"状态保持。
- 第 2 次按下才结束。
- 日志出现 `ATVV CONTROL source=control opcode=0x04 bytes=4`（本型号是 HTT：远端按下即自行起流），
  随后才是 `CHROMECAST VOICE phase=started`。
- **每次松键都必须有** `ATVV VOICE gesture duration_ms=… action=…`：第 1 次松键应为 `action=latch`、
  第 2 次为 `action=stop`；`action=debounced` 表示 latch 后 0.6 秒内的连按被忽略（收音保持，
  详见「根因 #5」）。**时长只作记录，不参与判定**（本版已彻底移除时长判定，详见「根因 #3」）。
- **按下期间不得出现 `ATVV MIC_OPEN written`**：本型号远端自己开麦，宿主补发会被样机当成新请求、
  拆掉正在推送的流（规范 4.7.5 明令禁止，详见上文「语音流根因」）。
- **按下期间 `ATVV AUDIO notify count=` 可能非零也可能为零**：远端 HTT 流是否推音频取决于按住
  期间有没有人声，为零不算缺陷（详见「根因 #2」）。
- **松键后必须看到** `ATVV MIC_OPEN written … bytes=0c00`（这一步才是宿主主动请求持续流），紧随
  `ATVV STREAM START reason=0x00 stream=0 origin=hostRequested`；**从这一刻起**
  `ATVV AUDIO notify count=` 应持续增长，电平图应波动。这就是本用例真正的通过判据。
- 后续每 4 秒一条 `ATVV MIC_EXTEND stream=0`（把远端的「音频传输超时」顶回去）。
- 完整序列：`CHROMECAST VOICE phase=started` → `CHROMECAST VOICE phase=sustain result=no_visible_change`（可能有多次）→ `CHROMECAST VOICE playback_stop phase=waiting_for_drain` → `CHROMECAST AUDIO playback_stop phase=completed result=drained`。

✅ **按多久都可以**：本版已彻底移除按键时长判定——模式由「按键映射」页底部的「语音键模式」决定，时长不再是判据。
历史上一版用 0.55 秒、下一版用 2.0 秒，两次都在真机上误伤了「按一次」（用户的自然按下时长在
1.12~5.76 秒之间跳动），详见「根因 #3」。第 1 次按下松键一律进入持续收音，第 2 次一律结束，
与你按了 1.1 秒还是 5.7 秒无关。

**若按了键却连一条 `ATVV CONTROL` 都没有**，说明远端压根没发出控制帧——此时不要继续测语音，
把该次日志（含 `BLE CHARACTERISTIC` 与 `BLE SYSTEM CONNECTED CANDIDATES` 两行）整段留证。
反过来，有 `ATVV CONTROL` 但没有 `CHROMECAST VOICE`，是宿主接线问题；有 `CHROMECAST VOICE` 但
`ATVV AUDIO notify` 从不出现，**先看 `ATVV VOICE gesture` 那行的 `action=` 与 `duration_ms=`**：
`action=stop` 说明这是「关」的那一次（本就不该有音频）；`action=latch` 却没有后续的
`reason=0x00` 宿主流，才是宿主接线问题。三者必须分清。

失败判定：第 1 次点按后立刻结束收音；持续收音期间输入法识别被反复关闭（说明换流被当成了新的
用户动作）；或**松键后**（已出现 `ATVV MIC_OPEN written` 与 `reason=0x00` 的 `ATVV STREAM START`）
`ATVV AUDIO notify` 仍恒为零。

### 用例 2b：`frame=` 与链路容量的对照（本版新增的判断题）

修复后，连接阶段会多出两行：`ATVV CAPABILITIES DETAIL … raw=…` 与 `BLE LINK maxWriteNoResp=…`。

1. 记录 `frame=`（远端期望的音频包大小）与 `maxWriteNoResp=`（本链路单包真实容量 ≈ ATT_MTU−3）。

预期：`frame` 大于 `maxWriteNoResp` 时属于**正常但需要留意**的情况——规范 4.2.2 说明 `frame` 只是
「用于音频帧计数的期望值，可以是任意值」，本实现按 v1.0 连续字节流解码，不依赖整包到达。
只要 `ATVV AUDIO notify` 非零且电平有波动，即视为通过。

失败判定：`ATVV AUDIO notify` 一直为零（远端据此拒绝推流）——这时要把两行数值一并留证，
它是把「远端不发」与「链路装不下」分开的唯一依据。

### 用例 3：hold 模式

把模式切到「按住说话」（「按键映射」页底部）。切换后**立即生效**，无需重启（改动会即时同步到运行时）。

1. 按住语音键说话，中途松开。

预期：按住期间收音，松开即结束；`completion=normal reason=hold_release`。

- 按住期间远端那条 HTT 流**会推音频，前提是按住时你在说话**：真机实测 4.47 秒按住拿到
  `audio_batches=100 audio_samples=49400` 并转文字成功。本模式在本型号上**可用**，
  只是音频只覆盖按键时长，首尾容易丢字；可持续可续流的是用例 2 的 `MIC_OPEN` 宿主流。
- 日志应出现 `ATVV VOICE gesture duration_ms=… action=stop mode=hold`（时长任意）。
- 按下瞬间不得补发 `MIC_OPEN`（应有 `ATVV MIC_OPEN skipped reason=remote_initiated_stream`）。

切换后先核对运行时是否真的换了模式：开始收音那行日志的末段应为 `mode=hold`。若界面已切而日志仍是 `mode=toggle`，即为接线缺陷，本用例结论无效。

失败判定：松开后仍在收音；或按住期间没有开始。

### 用例 4：首字完整性（最关键）

在 toggle 模式下，**点按**语音键（**时长不限**，真机自然时长 ≈1.1~1.4 秒），**松键之后立刻**说第一个字（例如「测试」，不要先停顿）。

1. 重复 10 次，每次换一个首字（如「你好」「今天」「帮我」）。
2. 检查识别结果与录音资产的首字是否完整。

预期：10 次首字全部完整。设计上宿主是在包写 `MIC_OPEN` 之前备好音频出口的，因此最早几帧不应丢失。

失败判定：出现首字缺失或吞字。⚠️ 本型号的风险点从「包内换流」变成了**松键→远端开始推流之间的启动延迟**
（远端收到 `MIC_OPEN` 后才真正开麦，实测首帧在同秒内出现，但存在间隙）。因此这一条要按**松键即说**来测，
并同时比对 `ATVV MIC_OPEN written` 与第一条 `ATVV AUDIO notify count=1` 的时间差。

### 用例 5：尾字完整性（正常停止不 flush）

1. toggle 模式下**快速点按**开始收音，说完一句结尾有力的短句（例如「今天天气很好」），
   再**快速点按**结束。
2. 检查最后两个字是否完整。

预期：尾字完整。正常结束路径只做自然排空（`maximumDelay: nil`），不得 flush。

失败判定：末字被截断；或日志出现 `AUDIO PLAYBACK interrupted`。

> hold 模式也可以测尾字（真机已确认按住期间有音频），但音频只覆盖按键时长，松手后的话必然丢失，
> 因此尾字完整性以用例 2 的 `MIC_OPEN` 宿主流为准（再点按一次才结束，尾字有自然排空窗口）。

### 用例 6：断连、蓝牙关闭与系统休眠

分别在**收音进行中**的三种情况下操作：

1. 关掉遥控器电源。
2. 在系统里关闭蓝牙。
3. 让 Mac 进入休眠并唤醒。

预期：三种情况都必须立即结束收音并释放语音键，日志为 `completion=forced`；**不得**自动改用电脑内置麦克风，也不得继续向 `MiRemoteV 2ch` 送无效音频。唤醒后应能重新连接。

失败判定：收音卡住不结束；语音键保持按下；或回退到电脑麦克风。

### 用例 7：8 kHz 样机必须被拒绝

若有 RemoteG10（只有 8 kHz 语音）样机：

1. 让它进入广播范围。

预期：在**扫描阶段**就被判为不支持并拒绝连接；日志为 `state=unavailable` 并给出拒绝原因。不得静默升采样，也不得把它当成受支持型号连上（界面不得把它显示成已识别的型号）。

失败判定：连接成功但没有声音；或出现升采样后的可用音频。

### 用例 8：快速连续点按

在 toggle 模式下快速连按两次以上。

预期：不产生重复触发；换流期间不重复合成用户可见动作；最终状态与物理按键状态一致（不能出现"以为在收音其实已停"）。

失败判定：输入法被反复开关；或最终状态与实际不符。

### 用例 9：与 Siri Remote 并存（仅当包同时包含两者）

本测试包只包含 Chromecast。要验证并存，需同时带 `SAYALL_SIRI_REMOTE_PACKAGE_PATH` 构建（另需 `libopus` 与 Developer ID 签名）。

1. 两个遥控器都连接。
2. 用 Chromecast 开始持续收音，期间按下 Siri 键。
3. 先松开其中一个，再松开另一个。

预期：语音键按引用计数保持按下，只有最后一个 owner 释放时才真正抬起；两路音频各自路由到 `MiRemoteV 2ch`；任何一方结束都不会取消另一方。

失败判定：一方结束导致另一方收音中断；或语音键提前抬起。

### 用例 10：打包可选性回归

**注意：这一步会在同一个 `dist/` 里重建 App，覆盖上面的真机测试包。请在跑完用例 1–9 之后再执行；**
或者先 `cp -R dist/SayAll.app /tmp/SayAll-chromecast.app` 留一份。

```sh
cd /Users/andy/MySrc/remote-mic-app-chromecase
env -u SAYALL_CHROMECAST_PACKAGE_PATH -u SAYALL_ENABLE_SIRI_REMOTE \
  SAYALL_CHROMECAST_PACKAGE_PATH= ./scripts/build-app.sh
plutil -extract SayAllChromecastIncluded raw -o - "dist/SayAll.app/Contents/Info.plist"
```

预期：未提供私有包时构建仍然成功，输出 `false`，App 正常启动，界面不出现该型号的任何入口。

若要同时确认"没有私有仓库权限"的场景，应在一个只有公开仓库访问权限的账号或干净机器上完成
resolve、测试与 Release 构建；本机已持有私有包路径，不能替代该验证。

失败判定：构建报错，或缺少私有包时启动异常、界面出现该型号的空壳入口。

### 用例 11：普通按键与键位映射页（新增能力，未上真机）

前置：侧边栏「按键映射」总开关**打开**（默认关闭；只有打开时本遥控器才会被独占）。
遥控器连接后按键页应自动出现「Chromecast 遥控器」档案并可选中。

1. 逐个按下 14 个普通按键（电源、方向×4、确认、返回、Home、静音、YouTube、NETFLIX、信源、音量±）。
2. 给「确认」键配一个可观察的动作（例如自定义快捷键），再按一次确认。
3. 给「确认」键配一个双击动作，连续按两次确认。
4. 关闭「按键映射」总开关后再按确认。
5. 按下期间观察按键页：被按下的键卡片应点亮橙色。

预期：
- 第 1 步每个键都出现 `CHROMECAST ACTION phase=completed result=dispatched button=…`，且 `button=`
  与遥控器上物理键位一一对应（出现错位就是 usage 表错了，不是映射错了）。
- 第 2 步执行配置的动作；第 3 步只执行双击动作，不额外触发单击。
- 第 4 步日志为 `CHROMECAST ACTION phase=completed result=system_managed control=…`，且按键**回到系统行为**
  （例如确认键会触发系统默认动作）——这证明独占只在映射开启时发生。
- 第 5 步对应卡片进入 `activeChromecastControlIDs`。

**已知边界（本工作项不覆盖）**：这颗遥控器不发自动重复包，宿主也没有为它实现**按键重复**（长按方向键连续滚动），
与小米遥控器链路不同；若需要，应作为独立工作项补，并在本手册新增用例。

失败判定：按了没有任何日志（区分「报告没到」与「usage 认错」：前者没有
`CHROMECAST CONTROL` 行，后者有行但 `button=` 与物理键不符）；或映射关闭时按键仍被宿主独占。

## 日志关键行

| 阶段 | 关键字 |
| --- | --- |
| 链路 | `CHROMECAST LINK state=`、`CHROMECAST CONNECTION state=` |
| 发现（扫描） | `BLE SCANNING`、`BLE CONNECTING source=scan` |
| 发现（系统已连接） | `BLE SYSTEM CONNECTED ADOPTED model=`、`BLE CONNECTING source=connected_peripheral` |
| 发现（扫描未匹配，诊断用） | `BLE DISCOVERED UNMATCHED name=` |
| 链路单包容量（MTU 代理） | `BLE LINK maxWriteNoResp=` |
| 能力协商原文 | `ATVV CAPABILITIES DETAIL interaction=`、`ATVV READY … interaction=… remote_mic=…` |
| 远端是否在推音频（最关键） | `ATVV AUDIO notify count=… bytes=… total=… head=…`；被丢弃时为 `ATVV AUDIO dropped_phase=` |
| 开始收音 | `CHROMECAST VOICE phase=started` |
| 持续收音（不得有用户可见动作） | `CHROMECAST VOICE phase=sustain result=no_visible_change` |
| 音频路由 | `CHROMECAST AUDIO routed source=chromecast_microphone route=virtual_audio device=MiRemoteV_2ch` |
| 结束与排空 | `CHROMECAST VOICE playback_stop phase=waiting_for_drain`、`CHROMECAST AUDIO playback_stop phase=completed result=drained` |
| 结束原因 | `completion=normal`（hold 松键 / 第二次点按）、`completion=forced`（断连、取消、宿主关闭） |
| 手势动作（最关键） | `ATVV VOICE gesture duration_ms=… action=latch\|stop\|debounced\|none mode=…` |
| 包内协议 | `ATVV MIC_OPEN written`（含 `bytes=`）、`ATVV MIC_OPEN skipped reason=remote_initiated_stream`、`ATVV MIC_CLOSE written` / `skipped`、`ATVV MIC_EXTEND stream=`、`ATVV STREAM START/STOP`（含 `origin=`）、`VOICE INTENT` |

判读要点：`ATVV VOICE gesture` 的 `action=` 决定后面一切——`latch` = 本次松键开始了持续收音
（后面就该有音频），`stop` = 本次是「关」，`none` = 无匹配手势。`duration_ms` 只记录用户按了多久，
**不参与判定**：`action` 完全由「语音键模式」决定。

`ATVV MIC_OPEN written` 与 `ATVV AUDIO notify` 是两条互相独立的证据：前者只说明宿主发了命令，
后者才是远端真的在推流。**toggle 的通过路径是：`action=latch` → `ATVV MIC_OPEN written bytes=0c00`
→ `ATVV STREAM START reason=0x00 stream=0 origin=hostRequested` → `ATVV AUDIO notify count` 持续增长。**

⚠️ 时点判定：

- `reason=0x03 origin=remoteInitiated` 的物理流开着时：`ATVV AUDIO notify` 非零或为零**都可能正常**
  ——取决于按住期间有没有人声（实测 1.3 秒按住多为 0 帧，4.47 秒按住说话有 100 批）；
- 真正该盯的是 `action=latch` 之后写出的 `reason=0x00 stream=0 origin=hostRequested` 宿主流：
  **它必须持续增长**，电平图也才应波动；
- 若 `action=stop` 之后没有音频，那是正常的「关」动作，不是缺陷。
- 若那条 `reason=0x00` 的宿主流一直零帧，才判定为缺陷（把 `frame=`、`maxWriteNoResp=`、
  两条 `STREAM START` 一并留证）。

合同要求异常原因必须出现在日志里，因此断连原因以稳定 token 输出（如 `disconnected.adapterStopped`）。

## 记录表

| 用例 | 结果 | 证据（日志时间戳 / 录音 / 备注） |
| --- | --- | --- |
| 1 连接与重连 | 部分通过 | 2026-09-15 01:01 本机真机：配对状态下启动即走到 `state=available`（见上文「已确认」）。步 2「重新连接」、步 3 遥控器关开恢复、步 4 系统蓝牙断开/重配对后重连**未执行**。 |
| 2 toggle 开始/结束 | 未执行 | |
| 3 hold | 未执行 | |
| 4 首字完整性（10 次） | 未执行 | |
| 5 尾字完整性 | 未执行 | |
| 6 断连/蓝牙关闭/休眠 | 未执行 | |
| 7 8 kHz 样机拒绝 | 未执行 | 无样机；准入判定已由包内单元测试覆盖（`.rejectUnsupported`），但**不替代真机**。 |
| 8 快速连续点按 | 未执行 | |
| 9 与 Siri Remote 并存 | 未执行 | 本包不含 Siri Remote（`SayAllSiriRemoteIncluded=false`）。 |
| 10 打包可选性回归 | 部分通过 | 不带私有包：`swift build` 通过、项目自检 44/44 通过。**未执行**的是完整 `build-app.sh` 无包出包与 `plutil` 读取 `SayAllChromecastIncluded=false`，以及无私有仓库权限账号的验证。 |
| 11 普通按键与键位映射 | 未执行 | 离线渲染已确认按键页版式与连线锚点（见 `Testing/artifacts/chromecast-mapping/`）；**真机按下生效未验证**。 |

**结论必须分开记录**：自动化测试结论、真机结论、安装包验收结论不能互相替代。本手册只覆盖真机部分。
本轮自动化结论（本次改动后）：包内 104 项 XCTest 全绿；宿主项目自检 44 项、SwiftPM 574 项全绿（带包与不带包两种配置）。
