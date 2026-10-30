# 修饰键双击录入：产品规范

## 状态与适用范围

- **状态：规范草案，等待产品确认；尚未开始开发。**
- 适用平台：macOS。Windows 版边界见第 8 节。
- 本文件是「把修饰键双击录成一条自定义快捷键」这一行为的权威产品规范。
  实现、测试手册和界面上线后的回归判断都以此为准。
- **本功能与语音键无关。** 它只作用于快捷键录入器、`CustomKeyboardShortcut` 数据模型
  和快捷键发送路径，不修改 `VoiceKeyMode`、遥控器语音键的按下/释放会话生命周期，
  也不给语音键增加任何手势。`AGENTS.md` 的「语音键响应与手势边界」与
  「跨硬件语音音频完整性规范」不适用于本功能。

## 1. 背景与问题

### 1.1 今天能做什么

快捷键录入器已经支持把一个**单独的修饰键**录成快捷键，覆盖 9 种键：
左/右 Command、左/右 Option、左/右 Control、左/右 Shift 和 Fn
（`Sources/RemoteMic/KeyboardShortcutPicker.swift:38` `StandaloneKeyboardModifier`）。
界面上既有键盘录入，也有免录入的选择器入口
（文案 `shortcut.picker.standalone_modifiers.help`：「用于只短按并释放一个左侧或右侧修饰键，
不需要在实体键盘上录入」）。

### 1.2 今天做不到什么

**「同一个修饰键连按两次」无法录入，也无法表达。**

- 数据结构 `CustomKeyboardShortcut`（`Sources/RemoteMic/RemoteButtons.swift:154`）只有
  `keyCode`、`modifierFlagsRawValue`、`keyLabel` 三个字段，**没有按压次数维度**。
  一个快捷键的语义被限定为「按一次」。
- 录入器 `ShortcutCaptureMonitor`（`Sources/RemoteMic/ShortcutCaptureMonitor.swift`）
  在修饰键**释放**时立刻定案：`handleModifierFlagsChanged` 在
  `pressedModifierKeyCodes` 变空、且没有出现组合键时，直接置 `didCapture = true` 并回调。
  它没有为「等第二击」保留任何状态。
- 发送侧 `KeyboardInjector.send` 的 `.customShortcut` 分支
  （`Sources/RemoteMic/KeyboardInjector.swift:403`）对单独修饰键只发一次
  `keyStatePoster(down)` + `keyStatePoster(up)`。

### 1.3 为什么值得做

「连按两次修饰键」是 macOS 既有交互语言，不是小众用法：

- **macOS 听写的默认快捷键就是「按两下 Fn 键」**；系统听写快捷键选项里
  还有「右 Command 按两下」「Control 按两下」等预设。
- 相当多的第三方语音输入与效率工具用「双击某个修饰键」作为自己的触发方式。

用户想把这类组合绑到遥控器按键上，由 SayAll 代发，今天做不到。这是本功能唯一的目标场景：
**把「双击修饰键」录下来，再由 SayAll 原样发出去。**

### 1.4 立项前查重（2026-10-23）

| 检查项 | 结果 |
| --- | --- |
| 开放 PR（16 个） | 仅 #403 `feat: add remote Agent switcher and fix App focus shortcut capture` 触及快捷键录入，但内容是 App 聚焦快捷键捕获的修复（`Bugs/2026-09-10-application-focus-shortcut-capture.md`），与本功能不等价。其余无相关项。 |
| 历史 PR（全量标题检索 `双击` / `double` / `两次`） | 仅 #560 `fix(mac): prevent double navigation in monitored app switcher`，与快捷键录入无关。 |
| Issue | #485「[Bug] 单击变双击」是遥控器按键手势问题，与本功能无关。 |
| `TODO.md` | 没有对应条目。 |
| 结论 | 无重复实现，可以独立立项。 |

## 2. 术语

| 术语 | 含义 |
| --- | --- |
| 修饰键 | Command、Option、Control、Shift、Fn，且区分左右（Fn 只有一个）。共 9 种。 |
| 单击修饰键 | 按下并释放一次同一个修饰键，中间没有按其他键。本功能上线前已有能力。 |
| 双击修饰键 | 在统一判定窗口内，对**同一个**修饰键完成两次「按下并释放」。 |
| 判定窗口 | 从第一次释放到第二次按下之间允许的最大间隔。 |
| 组合键 | 修饰键 + 其他主键，例如 Command + C。与双击互斥。 |

## 3. 用户可见行为

### 3.1 可以录入的键（第一版）

- 仅限第 2 节定义的 9 种修饰键。
- 只允许**单一**修饰键双击。**不支持**多修饰键同时双击（例如 Option + Command 连按两次），
  也不支持普通主键双击（例如双击 A）。
- 不支持三击及以上。

### 3.2 录入交互

1. 用户在按键映射页点击「录入快捷键」，进入录入状态。
2. 用户对同一个修饰键连续按下并释放两次。
3. 两次之间判定窗口未超时、且期间没有按下任何其他键，则录入成功，
   结果是一条「双击该修饰键」的快捷键。
4. 若只按一次、窗口超时，则按现有行为录成「单击该修饰键」，不报错。
5. 若第一次释放后按下了其他**主键**，判定为组合键，按现有行为录入。
6. 若第一次释放后按下了**另一个修饰键**，按现有行为「多个修饰键但不含主键不构成快捷键」处理。

> **具体采用哪种录入交互，取决于第 9 节 D1 的决策。** 3.2 描述的是推荐方案。

### 3.3 显示

- 紧凑显示（按键映射页）：重复符号，例如双击右 Command 显示 `⌘⌘`，
  双击 Fn 显示 `fn fn`。左右侧区分沿用现有 `sidedSymbol` 规则。
- 完整显示（悬停、无障碍朗读、编辑器标题）：使用本地化文案
  「双击右 Command」「双击 Fn」，不得只重复符号。
- 中英文都必须有对应文案。

### 3.4 执行

绑定到遥控器按键后触发时：

1. 对目标修饰键连发两次完整的「按下 → 释放」。
2. 两次之间插入固定间隔，间隔值需实测确认（见 D2）。
3. 发送必须走现有 `ShortcutEventSequence` 的修饰键生命周期机制，
   保留左右侧 device bit、硬件快照和合成事件标记，
   不得绕开它直接用裸 `CGEvent` 发送。
4. 日志沿用 `SHORTCUT ACTION` 前缀，新增可区分「双击」的字段，
   且不得记录用户内容。

### 3.5 选择器入口（是否提供见 D5）

若提供，在现有「单独修饰键」选择区旁增加「双击」维度的选择，
让用户不必依赖实体键盘录入就能选出「双击右 Command」。

## 4. 判定规则

| 场景 | 判定 | 说明 |
| --- | --- | --- |
| 同一修饰键 按下→释放→按下→释放，间隔 ≤ 窗口 | 双击 | 结果依赖 D1 的交互方案 |
| 同一修饰键 按下→释放，窗口超时 | 单击 | 保持现有行为 |
| 修饰键按下→释放后按主键 | 组合键 | 复用现有 `modifierChordDetected` |
| 两个不同修饰键各自按下释放，无主键 | 不成立 | 保持现有行为，见测试 `multipleModifiersWithoutAMainKeyDoNotBecomeAStandaloneShortcut` |
| 按键自动重复 | 忽略 | 复用现有 `keyboardEventAutorepeat` 过滤 |
| 事件带 `KeyboardInjector.syntheticEventMarker` | 忽略 | 复用现有合成事件过滤，防止自触发 |
| 判定窗口内按下任一非目标键 | 立即退出双击候选 | 且不得吞掉该键 |

**事件吞掉的边界（重要）**：录入器采用 `.defaultTap`，命中即吞掉事件。
因此在「等待第二击」的窗口内也必须吞掉这些修饰键事件，否则目标 App 会先收到一次单击修饰键。
但**一旦判定结束（成立或不成立）就必须立即停止吞事件**，
不能让窗口期变成用户后续输入的漏斗。窗口超时上限必须有界。

## 5. 明确不做

- 不修改语音键的任何行为、手势或时序。
- 不修改遥控器按键的单击/双击/长按识别（那是 `RemoteButtonGestureRecognizer` 的职责，
  键粒度是遥控器按键，与键盘修饰键无关）。
- 不改变 `Testing/HardwareCompatibilityContract.md` 定义的 300 ms 遥控器按键双击窗口语义。
- 不新增根目录文档，不新增可执行辅助文件。
- 不为本功能引入常驻键盘监听；只在录制期间存在事件 tap。
- 不支持多修饰键双击、普通键双击、三击。

## 6. 数据与兼容

### 6.1 数据模型

`CustomKeyboardShortcut` 需要新增一个「按压次数」维度（建议 `tapCount: Int`，默认 1）。
这是本功能**唯一具有侵入性的改动**。

### 6.2 必须处理的四个兼容点

1. **解码兼容**：该结构目前用合成的 `Codable`，没有 `CodingKeys`，也没有自定义
   `init(from:)`。新增字段后必须自定义解码，旧配置缺字段时回落到 1，
   不得让旧配置整体解码失败。
2. **导入校验透传**：`AppSettings.validatedShortcut`（`Sources/RemoteMic/AppSettings.swift:2608`）
   通过「用正常初始化器重建」来做白名单过滤。**如果重建时没有透传新字段，
   导入的双击快捷键会被静默降级成单击，且不报错。** 这是本功能最容易漏的坑。
3. **持久化与备份**：`buttonShortcuts` 以 `[String: CustomKeyboardShortcut]` 存在
   键 `buttonShortcuts` 下，并且进入完整备份与配置导出。三个方向（读写、
   导出、导入）都要覆盖，备份版本兼容策略需明确。
4. **私有包透传**：`MacroFeatureIntegration.swift:185` 从 `SayAllButtonProfiles`
   读回快捷键时用 `CustomKeyboardShortcut(keyCode:modifierFlags:keyLabel:)` 重建，
   **只透传单次按键**。私有包（`macos-combination-actions` / `macos-button-profiles`，
   独立仓）不同步扩展时，双击快捷键经这些入口读取会退化为单击。
   见 D7。

### 6.3 隐私

本功能不新增任何数据采集。日志只记录是否成功、是否双击、以及失败的归类原因，
不记录用户按下了什么、也不记录目标 App 内容。

## 7. 与系统既有行为的冲突

| 冲突 | 影响 | 处理建议 |
| --- | --- | --- |
| macOS 听写默认快捷键是「按两下 Fn」 | SayAll 发出的「双击 Fn」会同时被系统听写接收 | 这**可能正是用户想要的结果**（借遥控器触发系统听写）。但必须明确：SayAll 不保证独占该组合。界面上需要提示，见 D6。 |
| 右 Command 双击是听写可选快捷键 | 同上 | 同上 |
| 用户自定义的全局热键 | 可能被其他 App 抢 | 不做特殊处理，在测试手册中列为已知边界 |

**不得**为了独占而改写系统设置，也不得读取系统听写配置以外的私有状态。

## 8. 跨平台边界

- 本功能的录入口径在 macOS 上定义。Windows 版源码在独立仓
  `GetSayAll/remote-mic-app-windows`，不在本仓库。
- `Testing/HardwareCompatibilityContract.md` 要求「平台之间用户可观察语义一致」。
  因此本功能落地时必须二选一，并在该合同的平台差异表中登记：
  1. Windows 仓同步支持，语义一致；或
  2. 明确声明该平台不支持「双击修饰键录入」，而不是静默替换成单击。
- 见 D8。

## 9. 待确认决策点

以下每一项都需要产品确认后才能开发。推荐项已标注。

### D1（最关键）录入交互用哪种方案

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| **A. 统一等待窗口** | 任何修饰键释放后都先等窗口再定案 | 语义统一，但**单击修饰键录入会多出约一个窗口的延迟**，且会改变现有测试 `capturesEveryStandaloneModifierOnRelease` 的时序语义 |
| **B. 立即定案 + 窗口内可升级** | 先按单击定案，窗口内若出现第二击则改写成双击 | 单击无延迟，但需要录入器在定案后继续存活一小段时间，UI 要支持「已成功」再变「已成功（双击）」，边界更绕 |
| **C. 独立的「录入双击」模式（推荐）** | 现有「录入快捷键」行为完全不动；另加一个只等双击的录入入口 | **不改变任何现有行为，不动现有 9 个测试的时序语义**，用户意图显式；代价是 UI 多一个入口 |

推荐 **C**。理由是它把「等待窗口」从默认路径上彻底移开，
不会让老用户觉得单击修饰键录入变慢，改动面也最小。

### D2 判定窗口与发送间隔

- 录入判定窗口：建议 300 ms，与仓库统一的 300 ms 双击口径一致
  （`HIDRemoteScheduler.swift:17` 与 `Testing/HardwareCompatibilityContract.md:52`）。
- 发送两次之间的间隔：300 ms 只是**录入判定**口径，**发送间隔需要实测**。
  建议初值 50–80 ms，由真机验证 macOS 听写能否稳定识别。
- 需确认：窗口是否允许用户配置。建议第一版写死，不暴露设置项。

### D3 允许哪些修饰键

- 建议第一版放开全部 9 种，不做人为限制；Fn 与右 Command 的冲突按第 7 节提示处理。
- 需确认：是否要收窄到「Fn + 右 Command + 左 Option」这几个系统听写不占用、
  或用户最常绑定的键，以降低误触发投诉。

### D4 是否支持多修饰键双击

- 建议第一版**不支持**，只允许单一修饰键。
- 需确认是否接受这个限制。

### D5 是否提供免录入的选择器入口

- 现有「单独修饰键」区已经有免录入选择。若只支持键盘录入，
  用户必须真的双击一次才能配置。
- 建议同时提供，保持与现有单独修饰键入口的一致性。

### D6 与系统听写冲突的处理力度

- 选项一（建议）：只在 UI 上做静态提示，说明该组合可能同时被系统听写接收。
- 选项二：尝试读取系统听写快捷键设置并主动告警。这会引入读取系统偏好的依赖，
  需要单独评估权限与隐私边界。
- 选项三：不处理。

### D7 私有包是否同步

- 组合动作与键位方案在独立私有仓。不同步时，经这些入口读取双击快捷键会静默退化为单击。
- 建议：要么同步扩展私有包模型，要么第一版明确声明
  「双击快捷键仅在按键映射页生效，组合动作/键位方案读到后退化为单击」，
  并在界面上警示。

### D8 Windows 版

- 需确认是同步支持，还是声明平台不支持（见第 8 节）。

### D9 是否需要 `TODO.md` 条目

- 若确认开发，按 `AGENTS.md`「TODO 同步」要求在同一次修改中新增条目并维护状态。

## 10. 验证与失败判定

落地时的验证边界（现在只是列出，不代表已执行）：

| 层级 | 验证内容 |
| --- | --- |
| 自动化 | 录入器状态机：双击成立、窗口超时回落单击、组合键不误判、两个修饰键不误判、自动重复、合成事件过滤；发送侧：确实连发两次且带正确侧位标志 |
| 自动化 | 数据兼容：旧配置无新字段可解码；`validatedShortcut` 透传后双击不退化；导出→导入往返保持双击 |
| 构建 | `swift build` / `swift test` 带 `--disable-keychain`，Apple Silicon 与 Intel 双架构 |
| 真机 | 绑定到遥控器按键，验证目标 App 是否响应「双击修饰键」；至少覆盖 macOS 听写与一个第三方工具 |
| 失败判定 | 双击被录成单击；单击修饰键录入变慢；窗口期吞掉无关按键；导入后静默退化；`⌘⌘` 显示成 `⌘` |

单元测试与构建不能替代真机验收；未完成真机验证前不得标记为完成。

## 11. 预期改动面（供评估，不是承诺）

| 文件 | 改动 |
| --- | --- |
| `Sources/RemoteMic/RemoteButtons.swift` | `CustomKeyboardShortcut` 增加按压次数；显示名；自定义解码 |
| `Sources/RemoteMic/ShortcutCaptureMonitor.swift` | 双击识别状态机（依赖 D1） |
| `Sources/RemoteMic/KeyboardInjector.swift` | `.customShortcut` 分支支持连发两次 |
| `Sources/RemoteMic/AppSettings.swift` | `validatedShortcut` 透传新字段 |
| `Sources/RemoteMic/SettingsView.swift`、`KeyboardShortcutPicker.swift` | 录入入口与显示（依赖 D5） |
| `Resources/*.lproj/Localizable.strings` | 中英文文案 |
| `Tests/RemoteMicTests/ShortcutCaptureMonitorTests.swift` 等 | 新增用例 |
| `Testing/<新手册>.md` | 真机测试手册 |

`MacroFeatureIntegration.swift` 是否改动取决于 D7。
