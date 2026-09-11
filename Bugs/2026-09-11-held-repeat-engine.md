# 按住连发被手势路径整体排除,特例修复对实际绑定静默失效

## 根因

- 连发只存在于无手势绑定的裸路径:`startRepeatIfNeeded` 带 `hasSecondaryAction` 守卫,识别器在按住期间不触发单击(`doubleClickTimedOut` 要求已松开)。任何绑定了双击/长按的键,按住永远不会连发单击动作。
- 此前的修复(startHeldScrollRepeat/startHeldDeleteRepeat,PR #409 同内容)守卫在动作类型 `== .scrollUp/.scrollDown/.deleteBackward` 与 `!hasOverrideBinding` 上;用户实际配置中 up/down 长按绑的是 customShortcut(Home/End),守卫不满足即静默返回,表现为"改了没效果"。
- App 切换器内左右键一次移动两格:`shouldUseNativePassthrough` 未排除活动中的 AppSwitcherSession,原始 keyDown 未被抑制,同时会话又注入一次方向键。

## 修复

- 连发速率归一到动作级策略表 `HIDRemoteTiming.repeatIntervalMilliseconds(for: action)`,裸按键、按住单击、长按三条路径共享同一执行器 `scheduleActionRepeat`。
- 识别器新增 `holdConfirmed`:按住超过双击窗口(300ms)且无长按绑定时,单击动作持续连发,松开即停且不补发单击;绑定长按的键让位给长按语义。
- 长按动作按同一策略表连发(菜单长按删除连续退格,120ms),customShortcut 类长按仍只触发一次。
- `shouldUseNativePassthrough` 增加 `!appSwitcherSession.isActive`。
- 返回键原生连发速率由 50ms 归一到删除动作的 120ms(有意的 UX 变更:受控删除速率)。

## 回归测试

RemoteButtonsTests 新增 4 项:按住连滚与松开停止、长按让位与快捷键单发、长按连删、前台/配置档变化停发;app-switcher 测试参数化覆盖 seized/非独占 × 会话内外的事件抑制。`swift test` 全量 471 项通过。
