# Voice Input Started Before the Target Was Ready

- 时间：2026-08-11
- 状态：已修复，自动化与模拟硬件回归通过；第三方 App 真实输入仍待预览版验收
- 影响范围：macOS 既有 Fn 点按语音路径；内置 App、自定义 App 和自定义快捷键均可能受影响
- 功能点：唤起或聚焦目标 App 后的第一次语音输入
- 简单描述：按键动作提交 App 启动/聚焦后立即返回成功，但目标输入框可能还需数秒才能获得焦点；Fn 会在固定 150 ms 后提前发送，导致前几次语音没有进入目标输入框。
- 原始记录：根目录 `DEBUG.md`

## 复现条件与错误边界

1. 开启“语音键模拟 Fn 点按”。
2. 将一个遥控器动作配置为打开内置 App、自定义 App，或发送用于切换/聚焦输入位置的快捷键。
3. 目标 App 未运行、在后台，或前台焦点不在可编辑输入位置。
4. 执行动作后立即按住语音键说话并松开。

错误行为：Fn 在目标输入位置就绪前发送，语音可能进入旧窗口、没有进入任何输入框，或表现为前两次无效、第三次才成功。

正常边界：如果没有刚执行目标切换，现有前台 App 中的 Fn 语音仍按原有 150 ms 时间线启动；修复不得为所有语音无条件增加数秒延迟。

## 日志证据

现场日志显示 App 动作和最终输入框聚焦相差 2～3 秒：

```text
15:37:44 APP ACTION opened bundle=com.openai.codex
15:37:47 APP FOCUS succeeded bundle=com.openai.codex

15:37:49 APP ACTION opened bundle=com.openai.codex
15:37:51 APP FOCUS succeeded bundle=com.openai.codex
```

`APP ACTION opened` 只代表系统接受启动/激活请求，不代表系统级 `AXFocusedUIElement` 已经是安全、可编辑的输入位置。

## 根因

`KeyboardInjector.send` 在提交异步启动/聚焦请求后立即返回，而 `VoiceFnTapSessionController` 独立使用固定 150 ms 定时发送 Fn；两条异步链路之间没有“目标 App 已在前台且系统级焦点属于安全可编辑元素”的完成握手。

代码对比同时确认 `VoiceFnTapSessionController.swift` 与 `RemoteVoiceFunctionMapper.swift` 在 `v1.8.3` 和 `v1.8.8` 相同，因此不是这两个版本之间新增了“三次计数”；`v1.8.8` 扩大了 Typeless/Fn 路径的使用范围，使既有竞态更容易暴露。

## 修复

- 新增通用 `VoiceInputDestinationCoordinator`，统一跟踪内置 App、自定义 App和自定义快捷键触发的近期目标切换。
- 使用 system-wide Accessibility 的最终焦点判断前台目标是否拥有可编辑的 `AXTextArea`、`AXTextField` 或 `AXComboBox`；密码、受保护内容、禁用控件和非编辑控件不算就绪。
- 目标切换待定时，Fn 会话先缓存音频，目标就绪后只发送一次开始 Fn，并完整回放预录；用户在等待期间松开语音键，仍会在就绪后完成匹配的开始/停止 Fn。
- 最大等待 5 秒，约可缓存 5 秒、16 kHz、Int16 的 80,000 个 sample。超时、目标 App 退出、等待中切换到其他 App 或新请求覆盖旧请求时取消，不向错误窗口发送 Fn 或音频。
- 没有近期目标切换时继续使用原有 150 ms Fn 时间线，不改变普通前台语音行为。
- Codex、Claude、cmux 及自定义 App 原有专用聚焦策略继续只负责帮助聚焦；最终是否可以发送 Fn 统一由系统级就绪条件决定。

## 验证

- 修复前最小复合测试稳定失败：模拟目标 3 秒后才就绪时，旧实现于 150 ms 提前尝试 Fn，并进入 `start_tap_failed`。
- 修复后同一用例通过，并覆盖 0、200 ms、1 秒、3 秒就绪延迟。
- 覆盖完整预录、语音提前结束、5 秒预录容量、超时、目标切换、App 退出、新请求覆盖、敏感字段拒绝、无 pending 时原时间线。
- 独立硬件模拟器用 RC001 与 RC003 的真实 `STREAM_START → AUDIO → STREAM_STOP` fixture 驱动生产解码、Fn 会话和目标就绪链路；两种设备的第一次语音均在目标就绪后完整回放，未依赖前置主动 `MIC_OPEN`。
- 运行命令记录在 [`Testing/VoiceInputDestinationReadiness.md`](../Testing/VoiceInputDestinationReadiness.md)。

## 验证边界

自动化已经覆盖协议事件、PCM 解码、会话缓存、Fn 配对和目标状态机，但无法证明任意第三方 App 的 Accessibility 树长期稳定，也不能代替真实 RC001/RC003、豆包、Typeless、Codex、Claude、cmux 和用户自定义 App 的最终文字上屏验收。预览版交付后仍需按测试手册完成这些用例；未要求也未依赖屏幕解锁。
