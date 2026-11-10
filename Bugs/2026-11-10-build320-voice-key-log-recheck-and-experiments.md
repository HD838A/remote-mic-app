# build 320 语音键回归：加密日志解密复核与待做实验

- 时间：2026-11-10
- 对象：`build 320`（App 2.0.0，`SayAllSourceCommit=adca8168`，`SayAllPrivatePlatformVersion=2.8.1`）对照 `build 289`
- 前置记录：[现场证据](./2026-11-10-build320-voice-key-no-fn-delivery.md)、[责任边界与 #909 排除分析](./2026-11-10-build320-voice-key-regression-analysis.md)
- 一句话：**320 的加密 `.rmlog` 已可解密。日志证明 289 与 320 在 `fn` 语义下走的是同一条路（都只写设备级映射、都没有软件注入），因此「289 有软件注入、320 丢失」这一根因表述不成立；两版唯一的功能增量是映射表从 12 条变成 13 条（`0x0C → Fn`）。**

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

保留下来的有效结论（本轮未推翻）：

- 故障只在 `voiceKeyMode=fn` 一支；改 `right_option` 立刻可用。
- App 侧确实收到语音键触发（`reason=trigger_observed`），故障不在「键没收到」。
- 豆包、权限、音频设备均正常；Mac 自带 Fn 可正常唤起浮窗。
- 290–316 无构建可得，未做逐提交 bisect。

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

必须说明的边界：本节只能证明**公开链路**同构。若 289 真的把 Fn 送到了系统，那它只能通过同一张设备级映射，或者通过不写诊断的私有路径；后者无法用现有日志排除（私有层不写 `ATVV`/`VOICE` 诊断）。这一点决定了第八节实验 A 的必要性。

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

---

## 七、复查前置记录的三条反证

**第 1 条（改动性质不匹配）：保留。** #909 确实没有触碰 `neutralizeVoiceKey` 的判定，也没有改 guard。但它改变了映射表的**内容**，而 fn 一支的投递完全依赖映射表，所以「没改判定」不等于「不影响该支」。

**第 2 条（对称性反证）：不成立。** 原文论证是「`0x0C` 在两种模式里都存在，`right_option` 实测可用，故该条目不会让映射表整体失效」。

问题在于两种模式的投递结构不同：

| `voiceKeyMode` | 物理键处理 | 目标修饰键如何送达 | 映射表失效时的表现 |
| --- | --- | --- | --- |
| `fn` | 依赖映射改成 Fn | **只能**靠映射 | 完全无反应 |
| `right_option` | 映射改成 `Dst=0` 吞掉 | **软件注入**，不依赖映射 | 注入仍生效，语音条照起；物理键会漏出 `0x3E`/`0x0C` |

`right_option` 可用只证明了**注入通路**完好，不能证明**映射表**仍被系统采纳。只要没人验证「`right_option` 下物理键确实被吞掉」，这条反证就无效。对应待做实验 D。

**第 3 条（症状具有选择性）：同样依赖第 2 条。** 「fn 坏、right_option 好」在「映射表整体失效 + right_option 另有注入」的解释下同样成立，因此不构成选择性证据。

补充：#909 的合并时间是 `2026-11-09T02:58:33Z`（本地 11-09 10:58），build 289 的包是 11-07 22:54。11-09 的三个 289 会话全程运行在旧二进制上，不受该合并影响，A/B 归属成立。

---

## 八、待做实验（Intel 机器上执行）

所有实验前先退出 App，让映射归零；实验后还原并重启 App。

```bash
killall SayAll 2>/dev/null; killall RemoteMic 2>/dev/null
# 确认已归零
hidutil property --get UserKeyMapping
```

### 实验 A（决定性）：手写 12 条，即 289 的那张表

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

按遥控器语音键，观察豆包浮窗。

若该机 `hidutil` 报 JSON 解析错误（部分版本对 `0x` 字面量更严格），用下面这条生成十进制等价命令：

```bash
python3 -c 'import json;print(json.dumps({"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":(7<<32)|s,"HIDKeyboardModifierMappingDst":d} for s,d in [(0x35,0),(0x80,0),(0x81,0),(0x28,0),(0x4A,0),(0x4F,0),(0x50,0),(0x51,0),(0x52,0),(0x65,0),(0x66,0),(0x3E,0xFF000003)]]}))'
```

把输出整串传给 `hidutil property --set` 即可；条目数与目标完全一致（12 条）。

| 结果 | 判定 | 后续 |
| --- | --- | --- |
| **浮窗起、出字** | `0x0C` 条目是元凶，PR #909 为回归点 | 走实验 C 收尾，按第九节方案 1 修 |
| **无反应（与 13 条一致）** | 条目数不是变量，设备级映射在本机整体不被采纳 | 走实验 B |

前置记录做过「13 条」和「13 条改目标」，**唯独没做过 12 条**。这是整条链路里唯一没被覆盖的一格，也是能直接二分掉「#909 是不是元凶」的一格。

### 实验 B（判别）：单条 `0x3E → i`

把变量压到最小：一张只有一条、目标是普通字符的表。

```bash
hidutil property --set '{"UserKeyMapping":[
 {"HIDKeyboardModifierMappingSrc":0x70000003E,"HIDKeyboardModifierMappingDst":0x70000000C}]}'
```

在 TextEdit 里聚焦一个空文档，按遥控器语音键。

| 结果 | 判定 |
| --- | --- |
| 落下 `i` | 设备级映射**被采纳**；问题限定在「目标是 Fn（`0xFF000003`）」这一种目标上，与条目数无关 |
| 零字符 | 设备级映射**整体不被采纳**；fn 一支在这台机器上没有活路，修复必须改成注入或改键 |

这一条同时修正前置记录实验 3 的干扰：那一次虽然把目标改成了 `i`，但表里仍有 13 条，无法区分「条目数」与「目标类型」两个变量。

### 实验 C（实验 A 成功后做）：确认这台遥控器的语音键实际 usage

```bash
hidutil property --set '{"UserKeyMapping":[
 {"HIDKeyboardModifierMappingSrc":0x70000000C,"HIDKeyboardModifierMappingDst":0x700000023}]}'
```

按语音键，看是否落下 `i`。

- 落下 → 这台遥控器语音键发的是 `0x0C`，`0x3E` 那条与它无关，`0x0C` 必须保留，修复方向改为「拆分设备映射 / 分设备写入」而不是删除 `0x0C`。
- 不落 → 语音键发的是 `0x3E`，`0x0C` 在**这台机器上**是纯多余条目，可按第九节方案 1 处理。

### 实验 D（补前置记录的空白）：`right_option` 下物理键是否真被吞掉

在 build 320 里把语音键设为「右 Option」，聚焦 TextEdit 空文档，**只按遥控器语音键、不按键盘**。

| 结果 | 判定 |
| --- | --- |
| 文本文档无任何字符，豆包浮窗起 | 映射表有效；前置记录第 2 条反证**成立**，`0x0C` 不是元凶 |
| 文档漏出字符（`i`、或 F5 的系统行为），浮窗仍起 | 映射表**未生效**，浮窗全靠注入；第 2 条反证**作废**，`0x0C` 仍是首要嫌疑 |

### 收尾（每个实验后都要做）

```bash
hidutil property --set '{"UserKeyMapping":[]}'
```

确认 `hidutil property --get UserKeyMapping` 为空后重启 App（App 启动时会重新写入自己的表）。

### 结果如何决定修复方向

| A | B | 结论 | 修复方向 |
| --- | --- | --- | --- |
| 起 | — | `0x0C` 是元凶 | 方案 1 |
| 不起 | 落 `i` | 只有「目标 Fn」这一种投递失效 | 方案 2：Fn 改用注入，或按 #936 结论换触发方式 |
| 不起 | 零字符 | 本机设备级映射整体不可用，289 的 Fn 另有来源 | 方案 3：先查私有层，勿改公开代码 |

---

## 九、修复方向（按实验结果选）

1. **`0x0C` 确认为元凶时**：不要直接删 `0x0C`（另一批固件确实发它）。改成按设备分别写映射——先读回该设备语音键实际产生的 usage，只写它对应的那一条；或在写入后校验「映射表是否被采纳」，不采纳则退回注入。判据不能用「回读 verified」，它在本机已经被证明不可靠。
2. **只有 Fn 这个目标失效时**：fn 语义改为「中和物理键 + 软件注入 Fn」。前提是确认注入的 Fn 能被豆包接受；PR #936 在 macOS 27.0.1 记录过注入 Fn 被系统听写忽略，对第三方输入法是否成立尚未验证，需一并测。
3. **设备级映射整体不可用时**：先查私有层 2.8.1 与 289 对应版本在 fn 语义下的差异，再决定是否需要公开层改动；此时不应在公开代码里加注入，否则可能与私有层重复注入导致 Fn 两次。

三条方向都不建议把默认键改成右 Option 绕开——那是把豆包的触发方式从「长按」变成「免按」，属产品行为变更。

---

## 十、验证边界

- 本轮结论来自同一台机器的 289/320 端点对照，**未做逐提交 bisect**（290–316 无构建可得）。
- 属性层已验证（macOS 26.5.2，`hidutil`）：`UserKeyMapping` 接受 12/13/14 条，也保留「两条 source 指向同一目标」，**不存在条目上限或去重**。但这只证明属性写入与回读，**不证明投递生效**；目标机是 macOS 14.2.1，结论不能直接外推，仍以第八节真机实验为准。
- 公开诊断白名单不含「Fn 是否投递到系统」，`.rmlog` 无法直接观测系统侧是否产生 Fn；「320 未注入」可以证明，「320 是否产生过 Fn」不能证明。
- 私有层不写 `ATVV`/`VOICE` 诊断，因此无法用日志排除「289 通过私有路径投递 Fn」这一可能，这正是实验 A 的作用。
- 320 当次的 `runtime.log` 未随本次导出（已轮转），`HID NATIVE MAPPING` 中 `native_delivery=unobserved`、`pending=1862` 等字段的完整上下文缺失，未用于结论。
