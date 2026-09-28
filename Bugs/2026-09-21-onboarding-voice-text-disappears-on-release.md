# Onboarding 语音文字在松键后消失

- 时间：2026-09-21
- 状态：修复已实现，等待微信输入法/豆包等真实第三方工具验收
- 影响范围：macOS Onboarding 语音测试页；使用微信输入法、豆包、Typeless 或其他输入工具时的临时组合文字提交

## 复现

1. 在 Onboarding 选择微信输入法，连接小米蓝牙遥控器 2/2 Pro，并选择 `MiRemoteV 2ch`。
2. 进入语音测试页，按住遥控器语音键讲话。
3. 语音过程中输入框出现文字后松开语音键。
4. 旧实现中，文字可能随第三方输入工具撤销 marked/composition text 而消失，随后语音测试报告 `external_tool_no_commit`。

用户现场 1.9.21 日志中，音频多次完整送达且焦点稳定，但 attempt 2 和 5 均在 3 秒等待后报告 `transcript_commit_not_observed`；同一日志中的 attempt 1 和 7 可以通过，说明问题集中在文字提交时序而不是遥控器或音频链路。

## 根因

Onboarding 使用自定义 AppKit `NSTextView`。第三方输入工具可以先把识别结果作为 marked text 写入输入框；语音键松开后，输入工具可能撤销仍处于 marked 状态的文字。旧实现没有在语音会话结束时提交 marked text，也没有保留松键前已经显示的文字，因此输入框会回到空值，流程只能报第三方工具未提交。

## 修复

1. 语音会话中实时记录当前 attempt 最后一次非空文字候选，不记录文字内容到日志。
2. 松开语音键时向原生 `NSTextView` 发出一次提交请求；编辑器在请求中调用 `unmarkText()`，把 marked text 转为普通文本，并同步回 SwiftUI 状态。
3. 编辑器在 marked text 仍存在时不使用 SwiftUI 状态直接覆盖 `textView.string`，避免视图刷新再次撤销输入法组合态。
4. 如果第三方输入工具在松键后的事件循环中仍清空文字，在短暂的恢复窗口内使用本次 attempt 已显示的非空候选恢复输入框；用户手动输入时不执行恢复。
5. 增加脱敏日志 `ONBOARDING TRANSCRIPT marked_text_commit=true` 和 `restored_after_voice_release=true`，只记录动作，不记录文字、长度或第三方 App 私有状态。

## 验证

- 增加 Onboarding 定向源码回归断言，覆盖提交请求、`unmarkText()`、marked text 更新保护和松键恢复路径。
- 本地需要执行：
  - `swift test --disable-keychain --filter OnboardingFlowTests`
  - `swift test --disable-keychain`
  - `git diff --check`
- 真实验收必须使用实体 RC003、小米 `MiRemoteV 2ch`，分别验证微信输入法、豆包、Typeless 和其他支持工具：文字在语音过程中出现，松键后仍保留，不按回车、不重新点击输入框即可继续 Onboarding。

## 验证边界

自动化不能模拟真实第三方输入工具撤销 marked text 的时序，也不能读取第三方 App 私有状态。没有真实输入法和遥控器验收前，只能确认代码路径和自动化回归通过，不能宣称现场问题已最终关闭。
