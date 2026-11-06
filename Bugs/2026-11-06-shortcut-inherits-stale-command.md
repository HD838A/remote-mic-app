# 常用语粘贴后，自定义 Return 继承残留 Command 变成换行

- 时间：2026-11-06
- 状态：根因已定位到代码路径，**未用运行日志实测**；按用户要求本次不修改代码
- 基线：公开仓库 `upstream/main` `64c382ac`；私有包 `origin/main` `ab9c0980`
- 影响范围：macOS；所有「自定义快捷键」在**无修饰键**配置下，紧随任一「合成 ⌘ 组合」动作之后触发时。内置基本按键动作不受影响
- 功能点：常用语插入 / 自定义快捷键 / 按键注入
- 简单描述：用常用语插入文字后，配置成「快捷键 Return」的 OK 单击在微信里变成换行；把同一格换成内置「回车」动作则正常发送。两者键码都是 36
- 原始记录：用户反馈「为什么使用常用语在微信中输入文字以后，配置的回车键可以发送，但是快捷键 Return 却不能发送，而是换行？如果正常输入文字以后，两个是都可以发送的，这两个有什么差别」，并附两张键位方案截图（OK 单击分别为「快捷键 Return」与「回车」）

## 现象

微信默认「Return 发送、⌘/⇧ + Return 换行」，用户未改动该设置。同一台机器、同一个微信输入框，只切换 OK 单击的配置：

| OK 单击配置 | 直接输入文字之后 | 用常用语插入文字之后 |
| --- | --- | --- |
| 内置「回车」 | 发送 | **发送** |
| 自定义快捷键 Return | 发送 | **换行（失败）** |

关键点：**差别不在键码，而在事件上的修饰键标志（flags）从哪来**。两条路径投递的都是 keyCode 36，但一条强制清空 flags，另一条会并入事务开始时的 HID 快照。

## 与既有记录的区别

- `Bugs/2026-09-16-custom-shortcut-missing-modifier-release.md` 与 #361 解决的是「快捷键自己该释放的修饰键没有释放」，为有修饰键的路径引入完整按下 / 释放。
- `Bugs/2026-10-19-shortcut-modifier-feedback.html` 引入「事务开始读一次 HID 快照」，解决了同一事务内的回显，但按设计保留事务开始前已按住的修饰键。
- 本文描述的是**无修饰键**的快捷键继承了**其他动作**（常用语 `Cmd+V`、内置 ⌘ 动作）留下的修饰键，属于跨事务污染，不是上述两项的重复。

## 两条路径的差异

| 维度 | 内置「回车」 | 自定义快捷键 Return |
| --- | --- | --- |
| 动作类型 | `ButtonAction.returnKey`（hostAction） | `.customShortcut`（显示为「⏎」） |
| 实现入口 | `KeyboardInjector.swift:393-394` → `postKey` | `KeyboardInjector.swift:463-472` → `ShortcutEventSequence.send` |
| flags 来源 | 调用方直接传 `[]`，`postKey` 显式写入 down/up（`KeyboardInjector.swift:2131-2132`） | 读 `CGEventSource.flagsState(.hidSystemState)` 后并入每个事件（`ShortcutEventSequence.swift:305-306`、`:372`） |
| 残留修饰键 | 不可能带入 | 会把上一次合成事件的回显当作物理按住 |
| 按住连发 | 支持 | 默认不连发，导航键例外（`RemoteButtons.swift:642`、`:1107`） |
| 诊断日志 | 无 `SHORTCUT SEQUENCE` 事务行 | 有 operation_id，但裸 Return 不输出 flags 字段（见「诊断缺口」） |

## 根因

### 1. 常用语粘贴只发 keyDown / keyUp，没有 Command 的 `flagsChanged` 生命周期

`packages/macos-common-phrases/Sources/SayAllCommonPhrases/CommonPhraseInserter.swift:51-53` 的默认 `postPaste` 是：

```swift
CommonPhraseKeyboardInjector.postKeyState(code: 9, isDown: true, flags: .maskCommand) &&
    CommonPhraseKeyboardInjector.postKeyState(code: 9, isDown: false, flags: .maskCommand)
```

两个事件的 flags **都带 `.maskCommand`**，中间没有 Command 的按下/释放 `flagsChanged` 事件，keyUp 仍在声明 Command 处于按住状态。

`CommonPhraseSupport.swift:81-88` 的 `postKeyState` 也不做补偿：它只构造 `keyDown` / `keyUp`，既不发 `flagsChanged`，也**不设置** `eventSourceUserData = KeyboardInjector.syntheticEventMarker`。

对比主仓库同功能实现：`KeyboardInjector.swift:2139-2151` 的 `postKeyState` 会打 marker，`ShortcutEventSequence.emit` 在需要修饰键时会成对发 `flagsChanged`。私有包这条路径少了两道约束。

### 2. 自定义快捷键把 HID 快照当作物理真值

`ShortcutEventSequence.send` 在事务开始时读一次 `CGEventSource.flagsState(.hidSystemState)`，取它与修饰键掩码的交集作为 `physicalAtStart`（`ShortcutEventSequence.swift:305-306`），然后：

```swift
event.flags = synthetic.union(physicalAtStart)   // ShortcutEventSequence.swift:372
```

设计意图是保留用户真实按住的修饰键（组合键需要）。代价是：只要事务开始那一刻 HID 状态里还有上一次合成事件留下的位，它就会被当成「用户按住」并原样并进本次事件。

内置「回车」不走这条路：`postKey` 直接 `down.flags = flags`、`up.flags = flags`，裸 Return 的 flags 恒为 `[]`，所以不受残留影响。这就是「为什么同样按 Return，一个发送、一个换行」。

### 3. 这不是新缺陷，是 10-19 已撤销假定的实现残留

`Testing/CustomShortcutLifecycle.md:151-155`（2026-10-19 修饰键回显）已经写明：

> 单次同步事务读取一次物理修饰键快照，避免将合成事件回显当作物理按住。
> 旧版测试中的「实时快照一定纯物理」假定已撤销。

但实现只对 **Fn** 补了真实边沿验证：`ShortcutHardwareModifierState.observe`（`ShortcutEventSequence.swift:11-19`）只处理 `flagsChanged` + keyCode 63，并明确忽略合成 marker；`snapshot`（`:27-50`）只对 Fn 做 `functionFlagUnverified` 判断。**Command / Shift / Option / Control 仍直接采信 `flagsState`**，没有任何「这个位是否有真实边沿佐证」的检查。

也就是说：文档声明撤销了那个假定，代码里只撤销了 Fn 那一条。这是文档与实现的不一致，不是新发现的行为。

### 4. 交叉证据：同一仓库已经修过同类实例，但没有沉淀成通用约束

2026-11-05 的「聚焦输入框后光标落在文字之前」修复已通过 PR #886（合入提交 `efa09bc3`）进入上游 main，它踩过并解决了同一个问题：

- `KeyboardInjector.swift:1570-1596` 的 `postComposerCaretEndKey` 注释写明：
  > Without the trailing Command release the system modifier state would keep Command held after the action, **which poisons every later key event in the session**.
- 实现是四事件完整和弦：Command 按下（`flagsChanged`）→ 主键 down → 主键 up（带 Command）→ Command 释放（`flags = []`），且每个事件都设置 `syntheticEventMarker`。
- 当日记录写明该结论是「单测 `sessionObservationBounds` 稳定失败、上游对照通过、二分确认」得出的，不是推测。

也就是说：**正确写法已经在仓库里存在，只是没有抽成共享约束，常用语粘贴这条路径没有复用它。** 这既提高了根因的可信度，也说明方案 A 不需要重新设计事件序列——照抄这段即可。

### 5. 残留源不止常用语

`KeyboardInjector.swift:395-420` 的内置组合动作同样是「keyDown 和 keyUp 都写 flags、没有配对 `flagsChanged`」：

`commandReturn`、`shiftReturn`、`commandCopy`、`commandPaste`、`commandCut`、`commandSelectAll`、`commandUndo`、`commandRedo`、`commandFind`、`commandSave`、`commandClose`、`commandQuit`、`commandDelete`。

它们都会留下同类残留。**只修常用语粘贴，换个入口（例如先用遥控器内置「复制」再触发自定义 Return）问题会复现。**

## 为什么现有测试没拦住

1. `Tests/RemoteMicTests/ShortcutLifecycleTests.swift:159-186`（`syntheticFeedbackDoesNotKeepModifiersPressed`）**已经模拟了合成回显**（`systemSnapshot = event.flags`），但它第二次调用 `send` 时用的是 `modifiers: .maskCommand` 的快捷键——这条路径会自己 own 并释放 Command，所以断言通过。
   **没有覆盖的组合是：`modifiers: []` + `hardwareFlags` 里残留 Command。** 用现有替身装置就能复现，不需要真实 HID。
2. 私有包 `CommonPhraseTests.swift` 已有 4 个 `CommonPhraseInserter` 事务测试（日志脱敏、剪贴板拒绝、剪贴板保留、选区保持），但 `postPaste` **全部以替身注入**，没有一个断言默认实现的 `Cmd+V` 事件序列与 flags。测试装置已经存在，只差一个用例。
3. 既有验收条款只要求「粘贴后文字上屏」，没有要求「粘贴后合成修饰键状态回到基线」。`Testing/CommonPhrases.md` 的「剪贴板、失败与恢复」一节覆盖了剪贴板恢复与失败恢复，未覆盖修饰键残留。

## 影响面

以下动作之后，紧接着触发**无修饰键**的自定义快捷键，都可能带上前一次残留：

| 前置动作 | 残留来源 | 说明 |
| --- | --- | --- |
| 常用语插入 | `CommonPhraseInserter.swift:51-53` | 用户实际遇到的场景 |
| 内置复制/粘贴/剪切/全选/撤销/重做/查找/保存/关闭/退出/删除 | `KeyboardInjector.swift:395-420` | 同为 down/up 带 flags、无 `flagsChanged` |
| App 切换器（⌘Tab） | `KeyboardInjector.swift:447` | 同上 |
| 自定义组合快捷键 | `ShortcutEventSequence` | 正常，事务内会自己 own 并释放，且已有测试覆盖 |
| 语音键 Fn 注入 | `VoiceKeyMode.swift` | 10-29 的 Fn 过滤已覆盖，暂不在此列 |

反向影响：用户**真实按住**修饰键时触发自定义快捷键，`physicalAtStart` 会保留它（这是当前设计的有意行为）。任何修复都必须保留这条语义，不能简单删掉物理快照。

## 建议修复（未实施）

| 方案 | 改动位置 | 代码量 | 影响面 | 主要风险 |
| --- | --- | --- | --- | --- |
| A. 补齐粘贴的 Command 生命周期 | 私有包 `CommonPhraseInserter.swift:51-53` + `CommonPhraseSupport.swift:81-88` | 约 25 行 + 测试；事件顺序照抄第 4 节 | 仅常用语粘贴 | 私有包缺少针对默认 `postPaste` 的断言；发版要重出 xcframework + bundle；只治一处 |
| B. 无修饰快捷键不并入未经边沿验证的修饰键 | 公开仓库 `ShortcutEventSequence.swift:305-317` | 约 5 行 + 单测 | 全部无修饰自定义快捷键（三个入口） | 改变「实体键盘按住 ⌘ 时触发裸快捷键」的行为；需回归 `CustomShortcutLifecycle.md:190-191` |
| C. 用真实边沿重构物理修饰键状态机 | `ShortcutHardwareModifierState` + HID 监听 + 1248 配置矩阵 | 约 80 行 + 大量测试 | 所有快捷键 | 会动 10-29 刚通过真机验收的 Fn 逻辑，风险最高 |

不做一次性 C 的理由：10-29 的 Fn 修复虽已合入，`Testing/CustomShortcutLifecycle.md:36-37` 仍列着 Apple 芯片、实体键盘按住 Fn、语音 Fn 注入、PageUp/PageDown/End/Forward Delete 四项未验证。此时叠状态机重构，出问题无法归因。

方案 A 的具体坑，落地时必须逐条处理：

1. 补发的 Command `flagsChanged` 必须设置 `syntheticEventMarker`，否则会被 `KeyboardEventSuppressor.swift:341` 当成物理事件进入 HID 配对逻辑。
2. 若用户此刻正用实体键盘按住 Command，补发的 `flagsChanged up` 会把它「松掉」，导致粘键或后续输入丢修饰。需要先判断该位是否由本进程注入。
3. 左右 Command 的设备位（`NX_DEVICELCMDKEYMASK` / `NX_DEVICERCMDKEYMASK`）要与侧别逻辑一致，不能只发通用位。
4. 只修粘贴不够，第 5 节的 13 个内置组合动作要一并处置，或明确接受「仅常用语已修」的边界。
5. 事件序列可直接复用第 4 节的四事件顺序，但要注意 `KeyboardInjector` 属于公开宿主，私有包不能反向依赖；需要由宿主通过窄回调把「发一次带修饰键的按键」注入给 `CommonPhraseInserter`，不能把 App 内部实现复制到私有包后各维护一份。

## 建议的回归断言（未落地）

对应方案 B，可直接加进 `ShortcutLifecycleTests`，用现有替身装置即可复现，不需要真实 HID：

```swift
@Test func unmodifiedShortcutDoesNotInheritStaleCommand() {
    var events: [Edge] = []
    // 上一次常用语粘贴只发 keyDown/keyUp 且都带 Command，HID 状态因此残留。
    // 裸 Return 不得把这份残留当作物理按住。
    #expect(ShortcutEventSequence.send(
        keyCode: 36, modifiers: [],
        hardwareFlags: { .maskCommand },
        eventPoster: { events.append(Edge($0)); return true }
    ))
    #expect(events.map(\.code) == [36, 36])
    #expect(events.allSatisfy { !$0.flags.contains(.maskCommand) })
}
```

注意：这条断言锁的是「无修饰快捷键不继承未经边沿验证的修饰键」这一产品决定，采用方案 A 时不适用。

对应方案 A，需要先把 `postPaste` 的事件构造抽成可注入的 poster，才能断言 `flagsChanged down → keyDown → keyUp → flagsChanged up` 的顺序；这一步本身是私有包补测试的前置改造。

建议同时加一条静态检查：所有合成修饰键路径必须同时满足「成对 `flagsChanged`」+「设置 `syntheticEventMarker`」，防止再出现第三条同类路径。

## 诊断缺口

`diagnosticKind(36, [])` 返回 `nil`（`ShortcutEventSequence.swift:250-255` 只对 ⌘ 组合、Control + 方向键、功能层键位开诊断）。因此**裸 Return 的自定义快捷键不会输出** `physical_flags` / `event_flags`，也没有逐事件 `event_submission` 行。这是本次未能直接用日志坐实根因的原因。

可行的取证方式，按成本排序：

1. 照 `Testing/CustomShortcutLifecycle.md:85` 的先例（「本次仅增加日志，不改变事件标志、顺序、防抖或按键映射」），把 `keyCode == 36` 纳入 `diagnosticKind`，发一个只加日志的候选包。零行为风险。
2. 看 `SHORTCUT OBSERVATION` 的 `correlation=unavailable` 分支：若 Return 事件真带了 Command，会打印 `primary_kind=command_shortcut event_flags=0x100000`；干净时没有这条。
3. 对照实验：常用语插入后，先用实体键盘点一下 Command 或任一普通键清掉残留，再触发自定义 Return。若恢复发送即可印证。

## 防止再犯

新增或修改任何**合成修饰键**路径时，逐条确认：

1. 是否成对发 `flagsChanged`（按下 + 释放），而不是只给 `keyDown` / `keyUp` 加 flags？
2. 是否设置了 `eventSourceUserData = KeyboardInjector.syntheticEventMarker`？
3. 动作结束后，HID flags 是否回到动作前的基线？
4. 是否区分「用户真实按住」与「上一次合成残留」？不得把 `CGEventSource.flagsState` 直接当物理真值。
5. 是否覆盖「无修饰快捷键紧跟合成 ⌘ 组合」的用例？
6. 是否覆盖相反用例「用户真实按住修饰键时，该修饰键仍被保留」？
7. 是否复用了仓库内已验证的单一实现（第 4 节的四事件和弦），而不是在本文件里手写一套新的？

文档一致性：`Testing/CustomShortcutLifecycle.md:153-155` 已声明撤销「实时快照一定纯物理」的假定。这条声明必须在**同一次修改**中落到实现，不能只改文档；本次缺陷正是该声明只对 Fn 落地的结果。

## 验证边界

- 本文是**代码级根因推断**，没有该次复现时段的加密日志，也未在真机上做过对照实验。`physical_flags` 的精确值仍需「诊断缺口」节的方式确认。
- 即使确认，也只能证明「事件被投递时带了 Command」；第三方输入框是否因此换行属于外部行为，需要微信、浏览器普通文本区、原生文本区分别实测。
- 本地构建、单元测试、事件替身都不能替代真实遥控器 + 签名候选包的真机验收。
