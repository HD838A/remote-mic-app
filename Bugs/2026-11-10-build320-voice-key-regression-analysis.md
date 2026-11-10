# build 320 语音键回归：责任边界与 #909 排除分析

- 时间：2026-11-10
- 结论对象：`build 320`（App 2.0.0，`SayAllSourceCommit=adca8168`，`SayAllPrivatePlatformVersion=2.8.1`）
- 对照对象：`build 289`（2026-11-07 22:54 的包，语音正常）
- 相关记录：[build320 语音键在 Fn 配置下完全无反应](./2026-11-10-build320-voice-key-no-fn-delivery.md)（实验过程与现场证据）
- 一句话：**PR #909 在时间上落在 289 之后（在窗口内），但不是本次回归的原因；回归点在「fn 语义只写设备级映射、没有软件注入」这一支，属私有平台。**

---

## 一、结论

| 问题 | 结论 |
| --- | --- |
| #909 是否在 build 289 之后合入？ | **是**。`merged_at = 2026-11-09T02:58:33Z`（本地 11-09 10:58），289 的包是 11-07 22:54 |
| #909 是否是本次语音键失效的原因？ | **不是**。三条独立反证见第三节 |
| 那问题在哪？ | 「fn（按住说话）」这一支只写设备级 `UserKeyMapping`、不做软件注入；本机 Intel 上设备级映射不被系统采纳，Fn 从未产生。同构建改「右 Option」立刻可用 |

> 需要注意：**290–316 之间的构建不可得，无法做逐包二分**。上面的定位基于「289 正常 / 320 失效」的端点对照 + 机制实验，不是逐提交 bisect。

---

## 二、时间线

| 事件 | 时间（本地） | 备注 |
| --- | --- | --- |
| build 289 的包（bundle mtime） | 11-07 22:54 | 语音正常；Info.plist 无私有平台字段 |
| **PR #909 合入** | **11-09 10:58** | `f049d2e0`，标题 `fix(hid): map the leaked letter-i voice key usage to Fn` |
| #950 收敛 Chromecast 语音键模式入口 | 11-08 15:58 | 引入 `chromecast.mode.toggle/hold` 语义 |
| 私有平台 pin 2.7.9 → 2.8.0 → 2.8.1 | 11-09 20:51 / 23:57 / 11-10 01:18 | 语音状态机所在层 |
| build 320 | 11-10 08:20 | 使用 2.8.1 |

补充佐证：289 运行期读回的 `UserKeyMapping` 是 **12 条、不含 `0x0C`**；320 是 **13 条、含 `0x0C → Fn`**。`0x0C` 正是 #909 加入的那一条，与时间线互相印证。

---

## 三、为什么不是 #909（三条反证）

**1）改动性质不匹配**

#909 对 `Sources/RemoteMic/RemoteVoiceFunctionMapper.swift` 的改动只有两类：

- 单条映射 → 映射数组（`remoteVoiceKey` → `remoteVoiceKeys`，`applying`/`restoring` 参数改为数组）；
- 把 `0x0C` 加入 source 集合，使 F5 与字母 i 两种用法都映射为 Fn。

决定「中和物理键 + 软件注入」还是「交给硬件映射」的开关是 `neutralizeVoiceKey`，它由 `BridgeAppModel.applyHIDSettings`
计算并传入（`BridgeAppModel.swift:3359/3383/3397/3437`），#909 没有触碰这条判定。

**2）对称性反证**

#909 新增的 `0x0C` 条目在两种语音键语义下同时存在：

| `voiceKeyMode` | 条目数 | `0x3E` / `0x0C` 的目标 |
| --- | --- | --- |
| `fn`（按住说话） | 13 | `0xFF000003`（Fn） |
| `right_option` | 13 | `0`（中和） |

现场实测 `right_option` 可用 → 多出的 `0x0C` 条目不会让映射表整体失效。若它是元凶，两种模式应当一起坏。

**3）症状具有选择性**

实际故障是「fn 坏、right_option 好」，而 #909 对两种模式完全对称，无法产生这种选择性。

**若要 100% 排除**：让 CI 各出一个包（`f049d2e0^` 与 `f049d2e0`）在同机对比。按第 2、3 条，预期两者表现一致。
本地无法编译验证（仓库要求 Swift tools 6.2，本机只有 Xcode 15.2 / Swift 5.9.2）。

---

## 四、已确认的根因链

1. 语音工具选豆包 + 绑定为「长按」时，App 推导出 `voiceFnTapModeEnabled=false`
   （`AppSettings.swift:1403`：`plan.fnTapModeEnabled && plan.binding.shortcut == .function`）。
2. `requestedFnTapMode = voiceFnTapModeEnabled && voiceKeyMode == .function` → 为 false。
3. 于是走 fn 的「非 tap 分支」：**只写设备级 `UserKeyMapping`（`0x3E`/`0x0C` → `0xFF000003`），不做软件注入**。
4. 本机为 Intel，独占打开返回 `kIOReturnNotPrivileged`，走 monitored；设备级映射**回读 verified 但系统不采纳**。
   现场判据：把语音键手写成 `0x3E/0x0C → i` 后按语音键，TextEdit 里**零字符**（映射若被采纳，至少会落一个 `i`）。
5. 结果：App 侧正常观测到触发（公开事件 35 次 `trigger_observed`），系统侧从未出现 Fn → 豆包收不到启动键 → 完全无反应。
6. 同一构建把语音键改成「右 Option」，映射变为全部 `Dst=0`（中和）+ 软件注入 → **遥控器能正常唤起语音条**，
   证明注入通路本身完好，坏的只有 fn 这一支。

与之同源的既有事实：2026-11-07 的方向键问题（Intel 上映射回读 verified、系统仍投递原生键，导致一次按下移动两格），
当时是靠 `directionalNativeFallback` 兜的。**同一台机器、同一类问题，只是这次没有兜底。**

---

## 五、待私有侧确认的问题

> build 320（私有平台 2.8.1）在 `voiceKeyMode=fn`、`voiceFnTapModeEnabled=false` 时，语音键只写设备级
> `UserKeyMapping`（`0x3E`/`0x0C → 0xFF000003`），没有软件注入。Intel + monitored 场景下映射不被系统采纳，
> Fn 从未产生，豆包收不到启动键。同一构建改 `right_option`（映射全部 `Dst=0` + 软件注入）立刻可用；
> build 289 在 fn 语义下正常。请确认：
>
> 1. 2.8.1 是否把 fn 语义的软件注入合并进了 `voiceFnTapMode` 开关（即非 tap 模式下不再注入）；
> 2. 若不是，289 在 fn 语义下是通过哪条路径把 Fn 投出去的，该路径在 2.8.1 中是否被移除或前置 return。

---

## 六、与 PR #936 的关系（同一机制族，不是同一工作项）

[#936 docs(bugs)：记录注入 Fn 无法驱动系统听写的实测结论](https://github.com/HD838A/remote-mic-app/pull/936)（Open / Draft，2026-11-08）
记录：在 **macOS 27.0.1** 上，软件注入的 **Fn 被系统听写忽略**（单击、双击 80 ms、`cgSessionEventTap`、两种事件源全部无效），
把听写快捷键改成「连按两下 Control」后注入两次左 Control 可稳定启停。

差异：

| 维度 | #936 | 本记录 |
| --- | --- | --- |
| 目标消费者 | macOS 系统听写 | 豆包输入法（第三方 IME） |
| 系统版本 | macOS 27.0.1 | macOS 14.2.1（Intel） |
| 结论 | Fn 注入无效；Control 注入有效 | fn 一支无反应；改右 Option 走注入即刻可用 |

**对本记录修复建议的影响（必须一并考虑）**：如果「注入的 Fn 被忽略」对第三方输入法同样成立，那么「给 fn 补软件注入」
并不能修好问题，修复方向要改成——要么用系统级按键投递让系统产生真实 Fn（而非 `CGEvent` 注入），要么产品层接受
「Fn 这一支靠注入不可行」，改由其它修饰键或工具侧配合。

本记录**尚未验证**「豆包是否接受注入的 Fn」，因此「320 在 fn 分支没有注入」这个结论保持不变，但把它标注为待确认项。

## 七、修复建议

1. **首选**：fn 语义与其它修饰键走同一条路——中和物理键 + 软件注入 Fn，即把当前 `right_option` 的实现套到 Fn 上。
   这样不依赖设备级映射，Intel / Apple Silicon 行为一致。
2. **兜底**：保留硬件映射作为快路径，但补一层「回读 verified ≠ 系统采纳」的注入回退，与方向键的
   `directionalNativeFallback` 保持同一套判据风格。
3. **不建议**把默认键改成右 Option 绕开：那会把豆包的触发方式从「长按」变成「免按」，是产品行为变更，不是修复。

**验收判据**：`voiceKeyMode=fn` + 豆包长按 → 按住遥控器语音键应起浮窗并出字；同时 `hidutil` 读回映射仍为 13 条。
**回归面**：Apple Silicon 上原硬件映射路径是否仍为首选，避免修复后 Fn 被注入两次。

**现场规避（不修代码）**：遥控器语音键设为「右 Option」+ 豆包切「免按 / 按一次」，已实测可用；
代价是手感从「按住说话」变为「按一下开始、再按一下结束」。

---

## 八、验证边界

- 290–316 之间没有可得构建，**本次没有做逐提交 bisect**，「289 正常 / 320 失效」是端点对照。
- 320 的运行日志全部为 AES-GCM 加密 `.rmlog`，本机不能解密；明文 `runtime.log` 中不存在任何 `build=320` 记录
  （该文件只覆盖 268–336 等未注入公钥的构建）。
- 公开诊断事件白名单不含「Fn 是否投递到系统」这类字段，事件层无法给出成败判据
  （320 与 289 都只写 `started`、都没有终态，该字段不可用于判别）。
- 沙箱内无法做事件 tap：`CGEvent.tapCreate` 可创建但收不到任何事件，`CGEventSource.flagsState` 也读不到 Fn，
  因此「Fn 是否真的到达系统」只能通过豆包行为间接判定。
- 289 的包已被 320 覆盖，无法再做双版本二进制对比。
