# 自定义快捷键丢失修饰键左右侧（右⌘+逗号不生效）

- 时间：2026-09-05
- 状态：已修复，自动化通过；真机验收未完成
- 影响范围：使用自定义快捷键且依赖左/右侧修饰键的按键映射
- 功能点：自定义快捷键录制、持久化与注入
- 简单描述：录制时丢弃修饰键的左右侧信息，注入时也只在主键上打通用 flag、不按下真实修饰键，导致要求「右侧 Command」的第三方软件不响应；且以 keyDown 形式注入的修饰键不会改变系统修饰键状态，快捷键同时泄漏给前台 App。
- 原始记录：来自日常真机使用的 `~/Library/Logs/RemoteMic/runtime.log` 与 `defaults` 实读配置

## 复现与现象

把某个遥控器按键设为自定义快捷键「右 Command + 逗号」，用于触发区分左右侧的第三方语音软件：

1. 快捷键「没有生效」——目标软件不响应；
2. 在不同 App 前台按该键时，会「触发别的逻辑」（实测一例：⌘+, 泄漏给前台钉钉并弹出「设置」）。

## 证据

- 持久化配置实读：`power → { keyCode: 43(","), modifierFlagsRawValue: 1048576 }`。`1048576 = 0x100000` 是**侧别无关的通用 Command**，**没有**右侧设备位（右⌘ = `0x10`）。
- 日志：`HID BUTTON button=power trigger=singleClick action=customShortcut` —— 按键识别与动作派发正常，问题不在 HID、按键映射或权限。
- 关键反证：**手动**用键盘按右⌘+逗号时，钉钉**不**弹设置——说明目标 App 会像手按一样消费真实的 `flagsChanged` 序列，而注入的序列不是。

## 根因

1. **录制即丢侧别**：`CustomKeyboardShortcut.init` 对 `modifierFlags` 做 `.intersection(supportedModifiers)`，而该集合只含侧别无关掩码，右⌘ 的设备相关位（IOKit `IOLLEvent.h`，右⌘=`0x10`）在保存时被剔除。
2. **注入无法表达侧别**：`customShortcut` 分支只做 `postKey(主键, 通用flag)`，从不按下真实修饰键。
3. **注入方式不保真**：以 `CGEvent(keyDown:)` 发送修饰键不会改变系统修饰键状态（真实硬件发的是 `flagsChanged`），于是逗号事件仍带 ⌘ flag，前台 App 的菜单快捷键据此触发——即「泄漏」。
4. UI `displayName` 只显示 `⌘`，把这次降级隐藏了。

## 修复

- `CustomKeyboardShortcut`：新增左右设备位掩码；`retainedModifiers` 同时保留设备位（录制不再丢侧别）；`cgEventFlags` 附带已记录的设备位；新增 `sideSpecificModifierKeyCodes`（右⌘=54、右⌥=61、右⇧=60、右⌃=62；左侧 55/58/56/59），顺序固定 Control→Option→Shift→Command；`displayName` 标注「左/右」。
- `KeyboardInjector.postShortcut`：有侧别时**按下真实侧别修饰键（累积 flags）→ 主键 → 逆序释放**，`defer` 保证失败也释放（不重演卡修饰键）；无侧别（旧配置）走**原有 flags-only 路径**，行为逐字节不变。
- 修饰键注入走新增的 `postModifierState`：对侧别修饰键码改发 **`flagsChanged`** 事件，使注入序列在系统层面与手按一致。

**本 PR 的刻意范围**：`flagsChanged` 修正只应用于组合快捷键注入路径（经 `send()` 新增的 `modifierStatePoster` 参数，默认 `postModifierState`）。已发布的语音键左/右 Command 长按与 1.9.9 的独立左右修饰键动作仍走原 `postKeyState`（keyDown）路径——那是已验证的既有行为，是否同样改为 `flagsChanged` 建议按维护者的真机验证矩阵另行评估。

- 本地化新增 `keyboard.modifier.left/right`（中英同步）。
- 配置导入导出往返兼容：旧配置（无侧别位）继续走 flags-only 路径。

## 验证

自动化（6 项新测试，均为行为断言）：

- `rightSideModifierIsPreservedAndDisplayed` —— 录制保留 0x10 右侧位、键码 54、显示含 ⌘；
- `sideSpecificShortcutHoldsRealModifierAndReleasesInReverse` —— 注入序列 `down:60 → down:54 → key:43 → up:54 → up:60`；
- `failedModifierPressStillReleasesWhatWasHeld` —— 第二个修饰键按下失败时主键跳过、已按下的仍释放；
- `legacyShortcutWithoutSideKeepsFlagsOnlyInjection` —— 旧配置行为不变（回归护栏）；
- `sideSpecificShortcutInjectsCumulativeSideFlags` —— 按下事件带累积 flags 与右侧位；
- `modifierKeyCodesAreClassifiedForFlagsChanged` —— 8 个侧别修饰键码被分类，逗号与 Fn 不受影响。

`swift test` 全量通过；`scripts/test.sh`、`scripts/check-repository-boundaries.sh` 通过。

真机验收按 [`Testing/CustomShortcutModifierSide.md`](../Testing/CustomShortcutModifierSide.md) 执行：重新录制后显示侧别、目标软件被右 Command 触发、⌘+, 不再泄漏给前台 App、连按不卡键。
