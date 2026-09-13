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

RemoteButtonsTests 新增 4 项:按住连滚与松开停止、长按让位与快捷键单发、长按连删、前台/配置档变化停发;app-switcher 测试参数化覆盖 seized/非独占 × 会话内外的事件抑制。历史公开测试为 471 项；当前结果以下方本轮验证为准。

## 后续回归：连发绕过有效绑定与上下文

- 最小复现：模拟遥控器按住原始/带双击的单击/长按三种路径，底层动作可重复，但宏覆盖它；或者连发中更换动作、禁用映射、切换前台。
- 修复前 `swift test --disable-keychain --filter repeatPathsRespectEffectiveBindingAndLifetime` 退出 1，21 个参数组合记录 32 个失败（含缺少终态日志）。原始路径切换前台后计数仍从 6 增至 18；长按禁用映射后仍从 3 增至 13。
- 日志边界：原版仅记录 HID 手势，没有连发提交与停止日志，无法从日志证明用户可见结果；现场权限缺失也会使同样配置不可用，与引擎缺陷分开处理。
- 根因：原始路径仍使用独立计时器；手势连发直接调用动作执行器绕过宏覆盖，三条路径的上下文守卫不一致。
- 修复：三条路径真正复用 `scheduleActionRepeat`，统一检查动作/配置档/前台/映射开关/宏覆盖/权限；任一变化停止。增加去重的开始、首次提交、结束日志，明确外部可见结果未知。
- 可选硬件模拟测试两处速率查询由物理按键参数改为当前动作，修复 API 迁移遗漏。未取得私有模拟 Package 时不能声称该测试编译通过。
- 验证：针对 RemoteButtonsTests 的公开测试通过；长按测试覆盖删除、上下滚动、音量加减。完整公开测试及本地构建在交付时另列；真实设备、输入框、视频和系统权限仍需要运行态验收。

- 独立审核追加验证：旧 App 绑定 UUID 必须完整保留参与快照；首次连发/长按触发前切前台也必须取消手势，松手不补发；进入 TV 切换器取消已有其他键连发。首次触发前切前台的回归在修复前实际记录 4 个失败（包括新 App 连续删除），修复后通过。
