# macOS Fn 层与特殊按键参考

本文整理 macOS 上「Fn 类特殊按键」的机制、修饰键标志位、本仓库涉及的位置和日志判读口径。它只描述系统行为与实现事实，不定义产品行为；产品规则仍以 [`AGENTS.md`](AGENTS.md) 和各功能的 `PRODUCT_SPEC.md` 为准。

## 结论摘要

- Home、End、PageUp、PageDown、Forward Delete 在 Apple 键位表里属于 **Fn 层**，按下时系统硬件修饰键快照会额外带上 `maskSecondaryFn`。
- 自定义快捷键注入会把该快照并入合成事件，所以这类按键触发的快捷键可能被投递成 `Fn + 目标组合`，目标 App 匹配不上。
- 只有快捷键注入需要处理。原生动作、系统媒体键和用户手打的事件都不经过这条路径。
- 过滤口径是「只保留可证明的 Fn」：显式配置了 Fn，或确实观测到键码 63 的按下边沿，才保留；只有快照报告的一律剔除。

## 四种不同机制

「Fn 类特殊按键」不是一种东西，按行为分四类，只有第一类会污染快捷键：

| 机制 | 例子 | 表现 | 快捷键注入是否需要处理 |
| --- | --- | --- | --- |
| Fn 层语义的键码 | Home、End、PageUp、PageDown、Forward Delete、Insert/Help | 键码本身正常，但硬件快照额外带 `maskSecondaryFn` | 需要，必须过滤 |
| 功能键层 | F1–F12 | 键码正常；按不按 Fn 只改变系统对该键的解释（功能键或亮度/音量） | 不需要 |
| 无键码的系统事件 | 亮度、键盘背光、音量、播放控制、弹出、电源 | 以 `NX_SYSDEFINED` 投递，不在键盘事件流里 | 不需要，本仓库走 `postSystemKey` |
| 设备相关修饰位 | 左右 ⌘、⌥、⇧、⌃ 的区分位 | 同一个修饰键，左右各有独立的低位标记（`NX_DEVICEL*KEYMASK`） | 不需要，录制器按侧别保存 |

## 修饰键标志位

`CGEventSource.flagsState(.hidSystemState)` 返回的是**当下状态**，不包含时间、来源和使用者意图。快照里出现某一位，只能说明「系统此刻认为该修饰键按下」，不能说明是谁按的、按了多久。

| 位 | 值（十六进制） | 值（十进制） | 含义 |
| --- | --- | --- | --- |
| `maskSecondaryFn` | `0x00800000` | 8388608 | Fn |
| `maskNumericPad` | `0x00200000` | 2097152 | 数字键盘位 |
| `maskHelp` | `0x00400000` | 4194304 | Help |
| `maskAlphaShift` | `0x00010000` | 65536 | Caps Lock 锁定 |

快照里的 `maskSecondaryFn` 有两种互不相干的来源：用户真按着 Fn，以及源按键本身属于 Fn 层。标志位不区分这两者，这正是需要额外证据的原因。

## Fn 层键位清单

| 键 | macOS 键码 | 典型快照 | 本仓库可达性 |
| --- | --- | --- | --- |
| Home | 115 | `0x00800000` | 遥控器主页键的原生事件（`RemoteButtons.swift` 的 `.home` → `keyboard(keyCode: 115)`），默认动作是显示桌面（Fn-F11） |
| PageUp | 116 | `0x00800000` | 没有默认映射，只有用户自己录制的快捷键会用到 |
| Forward Delete | 117 | `0x00800000` | 同上 |
| End | 119 | `0x00800000` | 同上 |
| PageDown | 121 | `0x00800000` | 同上 |
| Insert / Help | 114 | 未实测；按 `CGEventFlags` 定义可能同时置 `maskHelp` | 没有默认映射 |

方向键（123–126）是例外：快照为 `0x00A00000`，即 Fn 加数字键盘位。方向键本身是数字键盘 2/4/6/8 的无 NumLock 版本，因此多带一个可辨识的附加位。旧实现正是靠这个附加位识别出伪 Fn，而 Home 没有这个特征，所以被漏掉。

## 本仓库中的 Fn 用法

| 位置 | 用法 | 是否受快捷键注入过滤影响 |
| --- | --- | --- |
| `KeyboardInjector.swift` 的显示桌面动作 | `keyPoster(103, .maskSecondaryFn)`，即 F11 加 Fn | 不受影响，走普通按键注入 |
| `VoiceKeyMode.function`（语音键默认模式） | 注入键码 63 加 `maskSecondaryFn` | 不受影响，语音会话不走快捷键事务 |
| `RemoteButtons.swift` 的快捷键展示 | 允许把 fn 记入修饰键并显示为 `fn ⌘H` | 不受影响，只影响展示 |
| `ShortcutEventSequence.swift` 的注入 | 请求显式包含 Fn 时保留 Fn | 属于保留分支 |

## 快捷键注入为什么会带上 Fn

1. `KeyboardInjector.send(.customShortcut:)` 进入 `ShortcutEventSequence.send`。
2. `send` 通过 `hardwareFlags()` 读取硬件修饰键快照，交给 `ShortcutHardwareModifierState.snapshot`。
3. 快照中除请求的修饰键之外还存在的位，会被并入每个合成事件，目的是不把用户正按着的 ⌘ 或 ⇧ 松开。
4. 源按键自带的 Fn 位因此也被并入，`Command+Shift+H` 就变成了 `Fn+Command+Shift+H`。

`ShortcutEventSequence` 的当前规则：

| 情形 | 结果 |
| --- | --- |
| 请求显式包含 `maskSecondaryFn` | 保留 Fn |
| 观测到键码 63 的按下边沿（`functionKeyPressed == true`） | 保留 Fn |
| 快照只有 Fn，且从未观测到边沿（`functionFlagUnverified`） | 剔除 Fn，`hardware_function_filtered` 记为 `true` |
| 快照同时带数字键盘位 | 按原有规则剔除（方向键） |

## 日志判读

| 字段 | 取值 | 含义 |
| --- | --- | --- |
| `hardware_function_state` | `pressed` / `released` / `unobserved` | 是否观测到真实 Fn 边沿；`unobserved` 表示只有快照 |
| `hardware_flags` | 如 `8388608` | 快照原始标志位（十进制） |
| `physical_flags` | 如 `1179658`（左 ⌘ 加左 ⇧） | 过滤后要并入事件的修饰键 |
| `hardware_function_filtered` | `true` / `false` | 本次是否剔除了 Fn |
| `event_function` | `true` / `false` | 实际投递的事件是否带 Fn |

三条同时成立即判定为 Fn 层污染：`hardware_function_filtered=true`、`hardware_flags` 只含 `8388608`（或同时含 `4194304`）、`hardware_function_state=unobserved`。方向键会是 `10485760`，因为它多一个数字键盘位。

## 边界与已知限制

- 本文的实测证据来自 Intel 机器上的真实遥控器日志与公开键位表。同一配置在同一台 Apple 芯片机器上未复现，但两代机器 HID 转换路径的差异没有查到可证实的根因，本文只记录观测结果，不做推测。
- `unobserved` 至少有三种来源：没有输入监控权限、事件监听启动晚于用户按住、使用不经过本进程事件过滤器的外部键盘。这三种情况下真实按住的 Fn 会被当作未验证而剔除，这是过滤口径的已知代价。
- 语音键 Fn 模式注入的是合成事件，`ShortcutEventSequence.observe` 明确排除合成事件（`eventSourceUserData` 等于合成标记时直接返回），所以它不构成已验证的 Fn。按住语音键再触发不含 Fn 的快捷键，Fn 会被剔除。
- Insert / Help 与数字键盘位的组合没有做过真机覆盖；相关结论以日志实测为准，不以本表推定为已通过。
- 本文与上述实测都只覆盖 macOS，不代表 Windows 侧行为；兼容性结论仍按 [`Testing/HardwareCompatibilityContract.md`](Testing/HardwareCompatibilityContract.md) 的实机矩阵判定。

## 相关文档

- 快捷键修饰键生命周期与验证范围：[`Testing/CustomShortcutLifecycle.md`](Testing/CustomShortcutLifecycle.md)
- 原生方向键把伪 Fn 带入自定义快捷键：[`Bugs/2026-10-20-shortcut-inherits-navigation-function.html`](Bugs/2026-10-20-shortcut-inherits-navigation-function.html)
- HID 连接、按键映射与语音键 Fn 映射：[`TECHNICAL.md`](TECHNICAL.md#hid-与按键映射)
