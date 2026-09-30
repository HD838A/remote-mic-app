# 自定义组合快捷键丢失左右修饰键侧别

## 状态与范围

- 状态：候选修复；自动化通过，真实键盘、实体遥控器和区分左右侧的目标 App 尚未验收
- 基线：`fe4cad7aebc52e93e28bfb2d05e33d7349e3ad9a`
- 关联：[PR #361](https://github.com/HD838A/remote-mic-app/pull/361)
- 影响：用真实键盘录入右 Command、右 Option、右 Control 或右 Shift 与主键的组合后，保存和执行会退化为左侧修饰键

## 复现

先只增加两个无系统副作用的事件测试，不修改产品代码：

1. 用通用 Command 位加右 Command 设备位 `0x10` 构造 `CustomKeyboardShortcut`；
2. 让 `ShortcutEventSequence` 发送通用 Command 位加 `0x10`，记录产生的虚拟键码和 flags。

修复前结果：

```text
shortcut.modifierFlags → 1048576
rightCommandMask → 16
events.map(\.code) → [55, 43, 43, 55]
```

右侧设备位在保存时被移除，执行时使用左 Command 键码 `55`，而不是右 Command 键码 `54`。旧配置只含通用修饰位时仍应继续使用左侧键，这是兼容边界，不属于失败。

## 日志与代码结论

没有可对应的用户现场加密日志，因此不把任何第三方 App 的最终响应写成已确认事实。现有 `SHORTCUT SEQUENCE` 日志能证明事件提交和清理结果，但修复前没有记录本次请求是否带侧别。

代码检查确认两处直接根因：

- `CustomKeyboardShortcut.normalizedModifierFlags` 只保留设备无关的 Control、Option、Shift、Command、Fn，丢弃 macOS 设备相关左右侧位；
- `ShortcutEventSequence` 为每类修饰键固定选择左侧键码，即使请求 flags 已包含右侧位也不会选择右侧。

当前主线已经统一发送完整的 `flagsChanged → 主键 down/up → flagsChanged` 生命周期，所以不能重新引入 #361 当时的第二套快捷键注入实现。

## 最小修复

- 只在对应通用修饰位存在时保留 Control、Option、Shift、Command 的左右设备位，并在 `CGEventFlags` 中继续携带该位；配置格式不变。
- 现有 `ShortcutEventSequence` 根据设备位选择左或右物理键码；没有侧别的历史配置仍默认左侧。
- 明确指定右侧时，只把同一右侧实体键视为已按住；用户真实按住另一侧时仍发送目标侧，最终释放保留真实硬件 flags。
- 映射摘要和辅助功能说明显示 `左/右`（英文为 `L/R`），避免保存成功后在页面上隐藏侧别。
- 请求日志增加脱敏的 `modifier_count` 和 `side_specific`；不记录具体主键、用户内容或前台 App。

没有修改语音键、单独修饰键动作、蓝牙、音频、手势、默认映射或配置 schema。

## 验证与边界

- 修复前两个定向测试共 5 条断言失败；修复后同一保存与事件序列用例通过。
- 自动化覆盖四种右侧修饰键键码、右 Command 保存/显示、旧配置默认左侧、失败清理和实体另一侧已按住的保留行为。
- `swift test --disable-keychain`：761 tests / 58 suites 全部通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：48 passed / 0 failed；`swift build -c release --disable-keychain` 和 Debug App 构建通过。
- 使用实际 Debug `.app` 资源和生产 `SettingsView` 生成并逐张检查浅色、深色页面，均清晰显示“右⌘,”，没有裁切或小于 12pt 的中文。审计文件 `mapping-1020x1400.png` 的 SHA-256 分别为 `2066562e08bbf99d5e17301456371e104c044d7183d58d2d38c4655a17a8362c`（浅色）和 `35225fa85b7b8144b34bbce05b53f196c37fb1de305856be0a67f9a710dcb352`（深色）；截图作为 PR 证据上传，不作为产品资源提交。
- 完整验证命令与真实环境用例见 [`Testing/CustomShortcutLifecycle.md`](../Testing/CustomShortcutLifecycle.md)。
- 自动化只证明保存值和构造出的 CGEvent 顺序，不能证明 WindowServer 或第三方 App 已接受。真实右 Command + 逗号、连续触发、目标 App 不泄漏和无粘键仍需使用签名候选包验收。

## 原作者

问题、复现方向和原始修复由 [@NotWizard](https://github.com/NotWizard) 在 #361 提交；当前集成保留其作者署名，并只把实现适配到主线已有的统一快捷键生命周期。
