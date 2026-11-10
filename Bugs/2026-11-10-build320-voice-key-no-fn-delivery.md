# Build 320 语音键在 Fn（按住说话）配置下完全无反应

- 时间：2026-11-10 10:06–11:05
- 状态：**已定性。fn 语义在 build 320 只走设备级 `UserKeyMapping`、没有软件注入；本机 Intel 上映射不被系统采纳，因此 Fn 从未产生。换用右 Option 语义（中和键 + 软件注入）立刻可用。**
- 影响范围：App 2.0.0 build 320（`SayAllPrivatePlatformVersion=2.8.1`）；MacBook Pro 16,2（Intel，macOS 14.2.1，x86_64）；小米 RC003；豆包输入法
- 功能点：遥控器语音键 → Fn → 豆包输入法浮窗 / 语音识别
- 简单描述：build 320 在「按住说话」配置下按住遥控器语音键，豆包浮窗完全不出现、无任何文字；同一机器同一遥控器换回 build 289 立即恢复。现场换键实验把范围压到 Fn 一支：把语音键改成「右 Option」后同一台遥控器立刻能唤起语音条（映射变为全部 `Dst=0` + 软件注入）。
- 原始记录：`~/Library/Application Support/SayAll/Diagnostics/public-events.json`；手工映射实验、换键对照实验（见下）

## 现象与现场证据

### A/B 对照（同一机器、同一遥控器、同一偏好域）

| 构建 | 包 | 按住遥控器语音键 |
| --- | --- | --- |
| 320 | root 属主，安装于 10:50:02，`SayAllSourceCommit=adca8168`（PR #979）、`2.8.1`、channel=release | 豆包浮窗**完全不出现**，无文字 |
| 289 | tina 属主，bundle 时间 2026-11-07 22:54，Info.plist 无私有平台/构建通道字段 | 浮窗正常起，**正常出字** |
| — | Mac 键盘自带 Fn/地球键（320 运行期间） | 浮窗正常起，出字正常 |

第三行排除豆包侧、系统 Fn 通路与前台输入框；第一、二行把问题锁死在「SayAll 把语音键变成 Fn 交给系统」这一段。

### 换键对照（决定性实验）

在 build 320 上把遥控器语音键从 Fn 改成「右 Option」，豆包切到对应触发方式（免按 / 右 Option）：

- **遥控器能唤起语音条。** 同一台遥控器、同一个构建、同一个注入通路，只是目标修饰键不同。
- 对应的 `UserKeyMapping` 也随之变化（见下表）。

这条实验把「整条语音键注入通路坏了」排除掉，范围收窄到 **Fn 这一支**。

### 两种语音键语义的映射差异（同一构建、同一设备，实测）

| `voiceKeyMode` | 条目数 | 语音键 `0x3E` / `0x0C` 的目标 | 投递方式 | 实际结果 |
| --- | --- | --- | --- | --- |
| `fn` | 13 | `0xFF000003`（Fn） | **仅设备级 `UserKeyMapping`，无软件注入** | **无反应** |
| `right_option` | 13 | `0`（吞掉） | 物理键中和 + **软件注入右 Option** | 正常唤起 |

其余 11 条在两模式下一致，均为 `Dst=0` 的中和项（Return、`~`、Home、四个方向键、App、Power、音量±）。

结论：**fn 语义把投递责任完全交给了硬件映射；右 Option 语义才是「中和物理键 + 软件注入」。** 前者在本机不成立。

### 手工映射实验（证明本机设备级映射不生效）

App 退出、映射由 `hidutil` 手写：

1. **App 退出时映射归零。** `killall RemoteMic` 后条目数 = 0 → 映射由 App 独占写入并还原。
2. **手写 13 条（`0x3E→Fn`、`0x0C→Fn`）→ 按语音键：无浮窗、无字符。**
3. **改成 `0x3E→i`、`0x0C→i`（读回 13 条、Fn 目标 0 条）→ 按语音键：TextEdit 里一个字符都没有。**

第 3 组是判据：若设备级映射被系统采纳，语音键无论发 `0x3E` 还是 `0x0C` 都该落下 `i`。实际零字符。

与 2026-11-07 方向键问题的既有结论一致：Intel 独占打开失败（`kIOReturnNotPrivileged`）走 monitored 后，
**设备级映射回读 verified，但系统仍旧按原生键值投递**（当时表现为方向键一次移动两格）。

因此「fn 模式依赖硬件映射」在本机是一条死路；289 能用，说明它在 fn 语义下还有软件注入这一层，320 没有。

### 构建身份

- 320：`CFBundleVersion=320`、`SayAllBuildChannel=release`、`SayAllSourceCommit=adca8168…`（PR #979，2026-11-09T23:58Z）、
  `SayAllPrivatePlatformVersion=2.8.1`（PR #970，2026-11-09T17:18Z 固定）、`SayAllPrivateArtifactsIncluded=1`、
  `SayAllAIIncluded=0`、`SayAllChromecastIncluded=1`
- 289：Info.plist 中没有上述任何私有平台字段，属更早的非官方构建

### 两版本共存、已实测正常的环境

- 遥控器在线：`hidutil list` 有 `0x2717:0x32b8 小米蓝牙语音遥控器`（BLE）
- 豆包输入法：Carbon TIS 实测 `com.bytedance.inputmethod.doubaoime.pinyin` **已启用且为当前输入源**，进程在跑
  （`defaults read com.apple.HIToolbox AppleEnabledInputSources` 里没有豆包，是过期缓存，不能作判据）
- 权限：`permission.input_monitoring=granted`、`permission.accessibility=granted`
- 音频：`MiRemoteV 2ch` 在位，`audio.configure completed ready`
- 偏好：`voiceKeyMode=fn`（故障态）/ `right_option`（可用态）、`voiceFnTapModeEnabled=false`、`onboarding.voiceTool=doubao`、
  `onboarding.verifiedVoiceBinding={"gestureMode":"hold","shortcut":"fn","tool":"doubao","validationState":"verified"}`

### 公开事件层（`component=voice`）

按每次 `app_launch` 切片：

| 构建 | 启动次数 | `started accepted trigger_observed` | 终态事件 |
| --- | --- | --- | --- |
| 320 | 5（末次为对照实验后重启，未按键） | 35 | 0 |
| 289 | 2 | 6 | **0** |

两版都没有终态事件 → **该字段不能作为判别信号**。但它证明：**320 确实观测到了语音键触发**
（`reason=trigger_observed`），故障不在「键没收到」，而在「键值没有变成系统可见的 Fn」。

## 已验证不成立的判断（含本轮自己的弯路）

1. **「0 终态 = 状态机卡死」——不成立。** 289 语音正常时同样只有 `started`、没有终态；RC003 这条链路本来不写终态公开事件。
2. **「`voiceFnTapModeEnabled` 是软件 Fn 注入开关」——不成立。** 写 `true` 后重启，App 立即写回 `false`，它是派生值不是开关。
3. **「映射写对了就会生效」——不成立。** 手写 `0x3E/0x0C → i` 后按语音键在 TextEdit 里零字符（实验 3）。
4. **「豆包 / 权限 / 音频设备不可用」——不成立。** 三项均实测正常，且 Mac 自带 Fn 可正常唤起浮窗。
5. **「切到免按模式后浮窗起来了 = 遥控器链路恢复」——假阳性，作废。** 那次语音条是用户按键盘右 Option 唤起的，
   与遥控器无关；豆包免按模式的触发键就是右 Option，不能作为遥控器侧的证据。
6. **「Fn 投递通路整体损坏」——不成立。** 同一构建改成右 Option 后遥控器可正常唤起，说明注入通路本身完好。
7. **「胶囊式修饰键探针可读全局 Fn 状态」——不成立。** `CGEventSource.flagsState(.hidSystemState)` 在本沙箱进程里
   连 Mac 自带 Fn 都采不到；`CGEvent.tapCreate` 可创建但收零事件（含自注入）。两条均未用于结论。

## 根因

语音键在**中等化物理键 + 软件注入**的方式下工作正常（右 Option 已验证）。而 `fn` 语义在 build 320 里被实现成
**「只写设备级 `UserKeyMapping`（`0x3E`/`0x0C` → `0xFF000003`），不做软件注入」**。

这台 Intel 机器上 App 走 monitored（独占打开返回 `kIOReturnNotPrivileged`），设备级 `UserKeyMapping`
回读 `verified` 但不影响系统实际投递，于是：

- App 侧：正常观测到语音键触发，开语音会话（事件层 35 次 `trigger_observed` 可见）；
- 系统侧：从未出现 Fn，豆包收不到启动键 → 完全无反应。

build 289 在 fn 语义下另有软件注入，所以同样配置可用。**回归点是 fn 语义的软件注入在 320（私有平台 2.8.1）丢失或被跳过。**

## PR #909 排查（结论：时间上落在窗口内，但不是本次原因）

- **合入时间**：PR #909 `fix(hid): map the leaked letter-i voice key usage to Fn`，`merged_at = 2026-11-09T02:58:33Z`（本地 11-09 10:58），merge commit `f049d2e0`。
  工作树里对应的提交是 `b78491aa`（2026-11-06 13:47 +0800 创作，11-09 合入）。
- **build 289 早于 #909**：289 的 bundle 时间是 2026-11-07 22:54。独立佐证：289 运行期读回的映射只有 12 条、没有 `0x0C` 条目；
  320 是 13 条（含 `0x0C`）。所以「#909 在 289 之后合入」成立。

**但不是本次故障的原因**，三条理由：

1. **改动性质**：#909 对 `RemoteVoiceFunctionMapper.swift` 只做「单条映射 → 映射数组」重构，并把 `0x0C` 加进 source 集合；
   决定「中和物理键 + 软件注入」还是「交给硬件映射」的 `neutralizeVoiceKey` 来自 `BridgeAppModel.applyHIDSettings`，#909 未触碰。
   其余改动集中在 Onboarding 的手输门禁与测试。
2. **对称性反证**：#909 新增的 `0x0C` 条目在 fn 表和 right-option 表里同时存在（两种模式都是 13 条）。
   实测 right-option 表可用 → 这条条目不会让映射表整体失效；若它是元凶，两种模式应当一起坏。
3. **症状具有选择性**：故障只出现在 fn 一支，right-option 正常。`#909` 的改动对两种模式完全对称，无法产生这种选择性。

窗口内更值得怀疑的变更是（全部晚于 289）：

| 变更 | 时间 | 与本故障的关系 |
| --- | --- | --- |
| #950 收敛 Chromecast 语音键模式入口 | 11-08 15:58 | 引入 `chromecast.mode.toggle/hold` 这套语音键语义 |
| 私有平台 pin 2.7.9 | 11-09 20:51 | 语音状态机所在层 |
| 私有平台 pin 2.8.0 | 11-09 23:57 | 同上 |
| 私有平台 pin 2.8.1 | 11-10 01:18 | 320 实际使用的版本 |

补充事实：公开代码里 `requestedFnTapMode = voiceFnTapModeEnabled && voiceKeyMode == .function`，且该值由语音工具绑定推导
（`AppSettings.swift:1403`，`plan.fnTapModeEnabled && plan.binding.shortcut == .function`）。豆包走「长按」→ `fnTapModeEnabled=false`
→ **fn 语义只写硬件映射、不做软件注入**，这是既有设计，不是 #909 引入。真正待查的是「在同一设计下 289 为何还能出声」，
这只能在私有平台里比对。

**若要 100% 排除 #909**：让 CI 各出一个包（`f049d2e0^` 与 `f049d2e0`）在同机对比；按上面第 2、3 条，预期两者表现一致。

## 修复建议

1. **首选**：fn 语义与其它修饰键走同一条路——中和物理键 + 软件注入 Fn（即把当前右 Option 的实现套到 Fn 上）。
   这样不依赖设备级映射，Intel/Apple Silicon 行为一致。
   **前提待确认**：PR #936 记录「注入的 Fn 被 macOS 系统听写忽略」（macOS 27.0.1）。若该结论对第三方输入法同样成立，
   这一条会失效，需要改为系统级按键投递方案，或产品层换键。详见
   [回归分析文档第六节](./2026-11-10-build320-voice-key-regression-analysis.md)。
2. **兜底**：保留硬件映射作为快路径，但必须按「映射回读 verified ≠ 系统采纳」的现实补一层注入回退；
   本地已有先例：2026-11-07 方向键问题就是靠 `directionalNativeFallback` 兜的。
3. 不建议把默认键改成右 Option 绕开——那会改变豆包的触发方式（长按 → 免按），是产品行为变更，不是修复。

## 现场可用规避（不修代码）

把遥控器语音键设为「右 Option」并把豆包切到「免按 / 按一次」：已实测遥控器可正常唤起语音条。
代价是手感从「按住说话」变成「按一下开始、再按一下结束」。

## 待办

1. 私有平台 diff `2.8.1` 与 289 对应的更早 Tag，定位 fn 语义下软件注入被移除/跳过的提交；
   日志关键字：`VOICE FN MAPPING`、`VOICE MODE`、`ATVV VOICE gesture`、`voice_key_press_failed`。
2. 修复后验收判据：`voiceKeyMode=fn` + 豆包长按 → 按住遥控器语音键应起浮窗并出字；
   同时确认映射仍为 13 条（防止修复顺手改坏映射层）。
3. 回归面：Apple Silicon 上原硬件映射路径是否仍然首选（避免重复注入导致 Fn 两次）。

## 验证边界

- 320 的运行日志全部为 AES-GCM 加密 `.rmlog`，本机不能解密；明文 `runtime.log` 中不存在任何 `build=320` 记录
  （该文件只覆盖 268–336 等未注入公钥的构建）。
- 现场只能证明「设备级映射不产生可见系统效果」，无法区分「映射被系统忽略」与「语音键发出的 usage 既不是 0x3E
  也不是 0x0C」；两者对修复方向影响一致（都不能依赖映射，必须软件注入），故未进一步区分。
- 无事件 tap 能力：沙箱内 `CGEvent.tapCreate` 返回值正常但收不到任何事件（含自身注入的事件），无法直接观测 Fn。
- 本机只有 Xcode 15.2 / Swift 5.9.2，仓库 `swift-tools-version` 为 6.2，无法本地重编；工作树停在 #901，
  落后 320 对应提交 #979 共 78 个 PR，无法直接 diff 语音链路。
- 289 的包已被 320 覆盖，无法再做双版本二进制字符串对比（289 二进制 36.7 MB vs 320 的 19.2 MB，本就不是同一种构建配置）。
