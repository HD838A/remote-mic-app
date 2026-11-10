# build 320 语音键回归：加密日志解密复核与待做实验

- 时间：2026-11-10
- 对象：`build 320`（App 2.0.0，`SayAllSourceCommit=adca8168`，`SayAllPrivatePlatformVersion=2.8.1`）对照 `build 289`
- 前置记录：[现场证据](./2026-11-10-build320-voice-key-no-fn-delivery.md)、[责任边界与 #909 排除分析](./2026-11-10-build320-voice-key-regression-analysis.md)
- 一句话：**320 的加密 `.rmlog` 已可解密。日志证明 289 与 320 在 `fn` 语义下走的是同一条路（都只写设备级映射、都没有软件注入），因此「289 有软件注入、320 丢失」这一根因表述不成立；两版之间作用于 fn 路径的功能增量只有映射表 12 → 13 条（`0x0C → Fn`）。该增量无法用 `hidutil` 在同机验证（语音键只在 App 运行时出事件，而 App 会覆盖手写表），只能由构建层对照判定。**
- 现场实测补充（同日 11:57）：本机设备级映射对普通目标是**有效**的，「映射不被系统采纳」这一前置结论已撤回；详见第八节。

---

## 一、本轮改变了什么

| 结论 | 原先（前置记录） | 本轮 | 依据 |
| --- | --- | --- | --- |
| 320 运行日志能否解密 | 不能（「本机不可解密」） | **能**，6 个会话全部通过完整性校验 | 第二节 |
| 289 与 320 是否可端点对照 | 靠 bundle 时间推断 | **是**，日志自带 `build=` 且互不重叠 | 第三节 |
| 289 在 fn 下是否另有软件注入 | 有（作为根因） | **没有**，两版同一 guard、同一诊断行 | 第四节 |
| 回归点是否在「软件注入丢失」 | 是 | **不是**，该支从未被调用 | 第四节 |
| #909 的「对称性反证」 | 成立 | **不成立**，见第七节 | 第七节 |
| `right_option` 可用能否证明映射表有效 | 能 | **不能**，该模式自带注入 | 第七节 |
| 唯一剩余功能增量 | 私有平台 2.8.1 | 另有 **12 → 13 条映射** | 第六节 |
| 本机设备级映射能否投递 | 不能（「回读 verified 但系统不采纳」） | **能**，普通目标实测生效；原判据是 App 退出态的空结果 | 8.1 / 8.2 |
| 语音键在 App 退出时是否产生事件 | 未区分 | **不产生**，退出态测量必为假阴性 | 8.1 |
| 手写映射表能否用于判定 | 能 | **不能**，已连接设备刷新不可靠，已作废 | 8.1 / 8.3 |

保留下来的有效结论（本轮未推翻）：

- 故障只在 `voiceKeyMode=fn` 一支；改 `right_option` 立刻可用。
- App 侧确实收到语音键触发（`reason=trigger_observed`），故障不在「键没收到」。
- 豆包、权限、音频设备均正常；Mac 自带 Fn 可正常唤起浮窗。
- 290–316 无构建可得，未做逐提交 bisect。
- 两版在 fn 语义下都没有软件注入（第四节）。

---

## 二、日志来源与可解密性

- 输入：现场导出的 `Diagnostics` 目录，含 6 个 `sayall.app-<date>-session-<id>.rmlog` 与一个 149 MB 明文 `runtime.log`。
- 解密：6 个 `.rmlog` 全部成功，`RMLG2` 文件头、会话密钥认证、逐条长度与 UTF-8、认证标签、`seq` 连续顺序全部通过，**共 10624 条记录**，无部分失败、无截断或乱序。
- 因此前置记录第八节「320 运行日志全部为 AES-GCM 加密，本机不能解密」这一验证边界已解除，相关结论改为以明文日志为准。

分文件记录数：

| 会话文件 | 记录数 | 归属构建 |
| --- | --- | --- |
| `2026-11-09-session-D68083BF` | 6975 | 289 |
| `2026-11-09-session-484113B1` | 612 | 289 |
| `2026-11-09-session-D8EE9534` | 524 | 289 |
| `2026-11-10-session-B738DDF1` | 1127 | 320 |
| `2026-11-10-session-CC476EEE` | 832 | 320 |
| `2026-11-10-session-AB83F8DA` | 554 | 320 |

---

## 三、这批日志本身就是一组 A/B 对照

每个会话内所有记录的 `ver=` / `build=` 字段完全一致，跨会话不混：

- **11-09 三个会话 = build 289**（8111 条）
- **11-10 三个会话 = build 320**（2513 条）

同一台 Intel 机器、同一支 RC003、同一偏好域的连续两天，因此不需要再依赖 bundle 时间或 Info.plist 有无私有平台字段来推断对照关系。

另需说明 `runtime.log`：它覆盖 build 268–336，**不含任何 `build=320` 记录**，末条为 11-10T00:05Z。原因是 320 每次启动都执行日志轮转（会话内 `LOG RETENTION retired_count=1 retired_bytes≈2.1 MB`），149 MB 那份是轮转前的旧档，320 当次写出的运行日志未随本次导出。映射与注入的判据因此只能取自 `.rmlog`。

---

## 四、两版在 fn 语义下逐项一致

以每次语音按键为单位，289（2 次）与 320（26 次）的记录结构相同，关键行逐字相同：

```
VOICE FN MAPPING applied=true neutralized=false power_suppressed=false suppression_scope=none matched=1 applied=1
ATVV AUDIO diagnostic phase=software_trigger edge=down mode=fn result=hardware_path_unobserved target_response=unknown physical_trigger=unobserved
ATVV AUDIO diagnostic phase=software_trigger edge=up   mode=fn result=hardware_path_unobserved target_response=unknown physical_trigger=unobserved
ATVV STREAM tail ... fn_pressed_at_stop=false
PUBLIC_EVENT component=voice action=session phase=started result=accepted reason=trigger_observed ... voice_tool=doubao
```

统计：

| 项目 | 289 | 320 |
| --- | --- | --- |
| `VOICE FN MAPPING applied=true ... matched=1 applied=1` | 有 | 有 |
| `phase=software_trigger ... result=hardware_path_unobserved` | 4 条（2 会话 × down/up） | 52 条（26 会话 × down/up） |
| `fn_pressed_at_stop` | 恒为 `false` | 恒为 `false` |
| `component=voice ... started/accepted/trigger_observed` | 2 | 26 |

`software_trigger ... hardware_path_unobserved` 这一行不是「注入后无法验证」，而是 **guard 命中后的跳过记录**。对应实现（`Sources/RemoteMic/BridgeAppModel.swift`，`updateVoiceKeyState`）：

```swift
guard forceSoftware || !mode.usesHardwareMapping else {
    keyDiagnostic?.softwareKey(edge: edge, mode: mode.rawValue, result: "hardware_path_unobserved")
    return true
}
```

`VoiceKeyMode.usesHardwareMapping` 仅对 `.function` 为 `true`，而遥控器语音链路调用 `updateVoiceKeyState` 时 `forceSoftware` 为 `false`（唯一传 `true` 的调用点是 `.mobile` 来源）。所以只要 `voiceKeyMode=fn`，这条 guard 必然命中、必然打这一行、必然 `return true` 而不注入。

**结论：该函数在 289 与 320 中实现相同，两版在 fn 语义下都没有软件注入。** 前置记录「289 在 fn 语义下另有软件注入，所以同样配置可用」缺少证据支持；把回归点归到「软件注入在 2.8.1 丢失或被跳过」与日志不符，应撤回。

必须说明的边界：本节只能证明**公开链路**同构。若 289 真的把 Fn 送到了系统，那它只能通过同一张设备级映射，或者通过不写诊断的私有路径；后者无法用现有日志排除（私有层不写 `ATVV`/`VOICE` 诊断）。这一点决定了 8.5 节构建层对照的必要性。

---

## 五、`fn_pressed_at_stop` 不能用作判据

全量检索：`.rmlog` 28 次、`runtime.log` 6 次，取值恒为 `false`；`hardware_function_state` 恒为 `unobserved`（390 次）。

说明 App 从来就没有观测到过真实硬件 Fn 状态，这是观测盲点，而不是「289 有、320 没有」的差异项。前置记录未把它当判据，本轮也不使用。

---

## 六、唯一剩余的功能增量：12 条 → 13 条

设备级 `UserKeyMapping` 的构成是可枚举的：

- `RemoteNativeKeyMapper.mappings` 固定 11 条中和项（`~`、`0x80`、`0x81`、Return、Home、四个方向键、App、Power），目标 `0`；该文件在 289→320 区间**未改动**。
- `RemoteVoiceFunctionMappingPolicy` 由 PR #909 从「单条 `0x3E → Fn`」改成数组，新增 `0x0C → Fn`。

叠加结果与现场 `hidutil` 读回精确吻合：

| 构建 | 11 条中和 + 语音条目 | 合计 | 含 `0x0C` |
| --- | --- | --- | --- |
| 289 | `0x3E → 0xFF000003` | **12** | 否 |
| 320 | `0x3E`、`0x0C → 0xFF000003` | **13** | 是 |

即：**两版之间唯一作用于 fn 投递路径的差异，就是多出的 `0x0C` 这一条。** 这与前置记录第二节的条目数佐证互相印证，但当时被三条反证判为「不是原因」，第七节复查其中一条不成立。

需要与结论一并记住的三点：

1. 现场已确认本机语音键发出的是 `0x3E`（8.1 节第 3 行）。因此 `0x0C` 条目如果影响结果，只能是通过「改变整张表的采纳/投递」这一间接方式，
   而不是它自己参与了这次按键。
2. 该条目的作用**无法在同机用 `hidutil` 验证**：App 退出时语音键不出事件，App 运行时又会覆盖手写表（8.3 节）。
3. 因此第六节是**候选增量**，不是已确认的元凶；判定方式见 8.5 节的构建层对照。

---

## 七、复查前置记录的三条反证

**第 1 条（改动性质不匹配）：保留。** #909 确实没有触碰 `neutralizeVoiceKey` 的判定，也没有改 guard。但它改变了映射表的**内容**，而 fn 一支的投递完全依赖映射表，所以「没改判定」不等于「不影响该支」。

**第 2 条（对称性反证）：不成立。** 原文论证是「`0x0C` 在两种模式里都存在，`right_option` 实测可用，故该条目不会让映射表整体失效」。

问题在于两种模式的投递结构不同：

| `voiceKeyMode` | 物理键处理 | 目标修饰键如何送达 | 映射表失效时的表现 |
| --- | --- | --- | --- |
| `fn` | 依赖映射改成 Fn | **只能**靠映射 | 完全无反应 |
| `right_option` | 映射改成 `Dst=0` 吞掉 | **软件注入**，不依赖映射 | 注入仍生效，语音条照起；物理键会漏出 `0x3E`/`0x0C` |

`right_option` 可用只证明了**注入通路**完好，不能证明**映射表**仍被系统采纳。只要没人验证「`right_option` 下物理键确实被吞掉」，这条反证就无效。对应 8.4 节的实验 0 / E。

**第 3 条（症状具有选择性）：同样依赖第 2 条。** 「fn 坏、right_option 好」在「映射表整体失效 + right_option 另有注入」的解释下同样成立，因此不构成选择性证据。

补充：#909 的合并时间是 `2026-11-09T02:58:33Z`（本地 11-09 10:58），build 289 的包是 11-07 22:54。11-09 的三个 289 会话全程运行在旧二进制上，不受该合并影响，A/B 归属成立。

---

## 八、现场实测结果与实验方案的修订

### 8.1 已完成的现场实测（2026-11-10 11:57，Intel / macOS 14.2.1 / RC003）

| 操作 | App 状态 | 结果 |
| --- | --- | --- |
| 映射 `0x3E → 6`、`0x0C → q`，按遥控器语音键 | **退出** | TextEdit 零字符 |
| 映射 `0x80 → 6`，按遥控器音量+ | **退出** | 落下 `6`，且原生音量被抑制 |
| 映射 `0x3E → 6`，按遥控器语音键 | **运行** | 落下 `6` |
| 映射 `0x80 → 6`，按遥控器音量+ | **运行** | 落下 `6` |
| 映射 `0x28(OK) → Fn`（回读确认已写入），按遥控器 OK | 运行 | 输入框仍**换行**，旧表未被替换 |

### 8.2 由此撤回或修正的结论

1. **撤回「设备级映射不被系统采纳」。** 上表第 2、3、4 行证明映射写入与投递在本机是通的。
   前置记录实验 3 得到的「零字符」是在 **App 退出态** 测的，属空结果，不能推出映射无效。
2. **撤回本文原第八节「先退出 App」的实验前置。** 语音键只在 App 运行时产生按键事件；App 退出时它**完全不产生键盘页事件**，
   同一张表下音量键却能出字符。因此退出态测语音键必然得到零字符，是假阴性。
3. **`0x0C` 不必再作为「可能多余的条目」处理**：本机语音键在 App 运行时发出的就是 `0x3E`（上表第 3 行）。
4. **新增一条限制**：`hidutil` 对已连接设备的表刷新不可靠（上表最后一行）。手写表不能作为判定手段。

### 8.3 为什么 App 写的表能生效、手写表不能

日志给出时序（两版一致）：

| 构建 | 写表 | 设备连接 | 间隔 |
| --- | --- | --- | --- |
| 289 | 13:30:21.213 | 13:30:21.610 | 397 ms |
| 320 | 02:26:51.274 | 02:26:51.734 | 460 ms |
| 320 | 02:26:54.712 | 02:26:55.469 | 757 ms |

App 在**设备枚举之前**写表，设备接入时自然读到新表；手写表发生在设备已连接之后，落在不可靠的刷新路径上。
这同时解释了第 5 行的「回读确认但按 OK 仍换行」：属性写成功了，投递层没有重新读取。

由此得出一个硬约束：**要测语音键，App 必须运行（否则键不产生事件）；App 一运行就会在连接时用自己那张表覆盖手写表。**
两者叠加使「12 条 vs 13 条」无法用 `hidutil` 在同机验证。

### 8.4 仍然值得做、且不依赖 hidutil 的实验

#### 实验 0（采纳探针，先做，约 1 分钟）

App 正常运行、`voiceKeyMode=fn`、**不要手写任何映射**。聚焦 TextEdit 空文档，按遥控器 **OK 键**。

| 结果 | 判定 | 下一步 |
| --- | --- | --- |
| **不换行** | App 自己写的 11 条中和表（含 `0x28 → 0`）已被系统采纳 | 表被采纳 → 故障只可能落在「`0xFF000003` 这个目标不被投放」上，走实验 E |
| **换行** | App 的表也未被采纳，写入/采纳时序才是问题 | 转实验 F，不再纠结条目数 |

依据：`RemoteNativeKeyMapper` 在两种语音键模式下都会把 `0x28` 映射为 `0`，与 `0x0C` 无关；因此这一条能独立回答「App 的表有没有生效」。

#### 实验 E（目标探针）

在实验 0 判定「表已被采纳」的前提下，App 运行、`voiceKeyMode=fn`，按住遥控器语音键，观察：

- 豆包浮窗 / 系统 Fn 行为是否出现；
- 若仍不出现，把同一支遥控器的 **OK 键**设为某个 App 自定义动作，确认 App 侧对 Fn 的观测是否同样失败。

结论分叉：表已采纳但 Fn 不出现 → `0xFF000003` 在本机不是可投放目标，fn 一支的映射方案不可行（对应第九节方案 2）。

#### 实验 F（时序探针）

在实验 0 判定「表未被采纳」的前提下：重启 App，**在 App 启动完成前**断开并重连遥控器，使设备在 App 写完表之后再枚举，然后按键。

- 变好 → 采纳时序问题，修复方向是推迟/重试写入或监听设备接入后重写；
- 不变 → 写入内容本身有问题，回到构建层对照。

### 8.5 「12 条 vs 13 条」只能用构建层验证

按 8.3 的硬约束，唯一不依赖 `hidutil` 刷新语义的对照是**同私有平台、仅差 `0x0C` 一条**的两个包：

| 包 | 映射表 | 用途 |
| --- | --- | --- |
| `f049d2e0^`（#909 之前） | 11 + 1 = 12 条 | 预期：与 289 一致，语音正常则 `0x0C` 为元凶 |
| 320 或 `f049d2e0` | 11 + 2 = 13 条 | 现状：fn 无反应 |

两者都在 `2.8.1` 上构建，可直接排除私有平台版本差异。这项对照需要 CI 出一个包，属于独立工作项，
不在本记录范围；需要时另开 PR 申请构建。原第八节的 `hidutil` 手写方案（实验 A/B/C）据此作废，不再执行，命令保留在下方仅供参考。

<details>
<summary>已作废的手写表命令（仅存档，勿直接执行）</summary>

原实验 A 的 12 条表：

```bash
hidutil property --set '{"UserKeyMapping":[
 {"HIDKeyboardModifierMappingSrc":0x700000035,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x700000080,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x700000081,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x700000028,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x70000004A,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x70000004F,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x700000050,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x700000051,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x700000052,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x700000065,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x700000066,"HIDKeyboardModifierMappingDst":0},
 {"HIDKeyboardModifierMappingSrc":0x70000003E,"HIDKeyboardModifierMappingDst":0xFF000003}]}'
```

作废原因：需 App 退出才不会被覆盖，而 App 退出时语音键不产生事件；App 运行时写入的窗口又无法命中。

</details>

## 九、修复方向（按实验结果选）

1. **构建层对照确认 `0x0C` 是元凶时**：不要直接删 `0x0C`（另一批固件确实发它）。改成按设备分别写映射——先读回该设备语音键实际产生的 usage，只写它对应的那一条；或在写入后校验「映射表是否被采纳」，不采纳则退回注入。判据不能用「回读 verified」，它在本机已经被证明与投递无关。
2. **实验 0/E 判定「表已采纳、只有 Fn 这个目标不被投放」时**：fn 语义改为「中和物理键 + 软件注入 Fn」。前提是确认注入的 Fn 能被豆包接受；PR #936 在 macOS 27.0.1 记录过注入 Fn 被系统听写忽略，对第三方输入法是否成立尚未验证，需一并测。
3. **实验 0 判定「App 的表也未被采纳」时**：问题在写入/采纳时序，不在条目内容。方向是写入后监听设备接入并重写、或按回报校验投递再补写；此时不应在公开层加注入，否则可能与私有层重复注入导致 Fn 两次。
4. **已撤回的方向**：原「设备级映射整体不可用，须先查私有层」不再成立——本机映射对普通目标是通的（8.1 节第 2–4 行），私有层差异不再是首要假设。

以上方向都不建议把默认键改成右 Option 绕开——那是把豆包的触发方式从「长按」变成「免按」，属产品行为变更。

---

## 十、验证边界

- 本轮结论来自同一台机器的 289/320 端点对照，**未做逐提交 bisect**（290–316 无构建可得）。
- 属性层已验证（macOS 26.5.2，`hidutil`）：`UserKeyMapping` 接受 12/13/14 条，也保留「两条 source 指向同一目标」，**不存在条目上限或去重**。
  但这只证明属性写入与回读；且现场已实测「回读确认的写入未必被投递层采纳」（8.1 节最后一行），故属性层结果不能作为判据。
- 手写表方案已作废：语音键只在 App 运行时产生事件，而 App 运行时会用自己那张表覆盖手写表，两者叠加使内容级对照在同机不可行。
- 公开诊断白名单不含「Fn 是否投递到系统」，`.rmlog` 无法直接观测系统侧是否产生 Fn；「320 未注入」可以证明，「320 是否产生过 Fn」不能证明。
- 私有层不写 `ATVV`/`VOICE` 诊断，因此无法用日志排除「289 通过私有路径投递 Fn」这一可能；该可能只能由 8.5 节的构建层对照排除。
- 320 当次的 `runtime.log` 未随本次导出（已轮转），`HID NATIVE MAPPING` 中 `native_delivery=unobserved`、`pending=1862` 等字段的完整上下文缺失，未用于结论。
