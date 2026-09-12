# Onboarding 权限页返回按钮点击后停留原页

- 时间：2026-08-29
- 基线：无线麦SayAll.app `1.9.18 (171)`
- 状态：候选修复完成，等待真实点击复验
- 影响范围：已有实体遥控器连接、自动进入权限页的首次使用流程
- 现场证据：用户截图中权限页左上角“返回”按钮可见，鼠标位于按钮区域

## 复现

1. 在实体遥控器已连接时进入 Onboarding 的“当前有遥控器吗”步骤。
2. App 自动选择实体遥控器并进入权限页。
3. 点击权限页左上角“返回”。
4. 页面仍显示权限页，用户感知为按钮无效。

正常边界：未连接实体遥控器或选择 iPhone/网页版时，普通前后导航不受该自动识别路径影响。

## 日志与代码结论

现有诊断没有记录导航原因，因此现场日志不能直接显示“返回后又自动前进”。代码路径可以确定该行为：

1. 权限页的 `previousStep` 在有遥控器路径明确返回 `.remoteAvailability`。
2. 点击按钮调用 `settings.setOnboardingStep(.remoteAvailability)`，说明点击 action 本身存在且目标正确。
3. `onChange(of: onboardingStep)` 随即调用 `prepareForStep(.remoteAvailability)`。
4. `prepareForStep` 调用 `routeConnectedPhysicalRemoteIfNeeded()`；遥控器仍连接时立即再次设置 `.permissions`。

因此页面实际发生 `permissions → remoteAvailability → permissions`，不是按钮命中区域、透明 overlay 或禁用状态问题。

## 假设验证

- H1：按钮 action 被 guard 阻止。否定；返回按钮没有 guard。
- H2：按钮被 overlay 或窗口拖动区域抢占。现场截图不足以完全排除点击命中异常，但代码存在可确定的立即回跳路径，足以解释稳定现象。
- H3：返回后自动路由立即再次前进。确认；步骤切换与 `prepareForStep` 的同步路径完整成立。

## 根因与修复目标

自动识别逻辑没有区分“首次进入遥控器选择页”和“用户主动从权限页返回”。已有连接本应缩短首次流程，但不能覆盖用户明确的返回导航。

候选修复只抑制这一次由用户主动返回触发的自动前进：

- 初次进入、App 恢复前台或连接状态从未连接变为已连接时，仍可自动选择实体遥控器并进入权限页。
- 用户从权限页返回后，必须稳定停留在遥控器选择页，允许改选“当前没有遥控器”。
- 抑制标记只消费一次，不持久化，不改变后续真实连接事件处理。
- 导航日志补充 `reason=user_back` 和 `auto_route_suppressed=true`，避免以后只能靠视觉猜测。

## 验证要求

1. 连接状态为 true 时，首次进入 `.remoteAvailability` 仍自动进入 `.permissions`。
2. 从实体权限页主动返回时，稳定停留在 `.remoteAvailability`，不会在同一轮 `prepareForStep` 中跳回。
3. 返回后改选“当前没有遥控器”，可以继续进入 iPhone/网页版选择页。
4. 后续出现新的真实连接事件时，自动路由仍按现有策略执行。
5. 在 `1020 × 772` 浅色与深色生产视图中真实点击返回，确认按钮可见、命中且窗口几何不变。

## 候选修复验证

- `OnboardingFlowTests` 已覆盖自动路由策略的正常路径与 `user_back` 单次抑制路径。
- `swift test`、项目自检、Release 构建和 `git diff --check` 已通过。
- 浅色/深色生产 Onboarding 截图中权限页返回按钮可见、位置稳定，窗口尺寸为 `1020 × 772`（@2x PNG 为 `2040 × 1608`）。
- 尚未在真实可见窗口中用鼠标执行点击；需在实体遥控器持续连接场景复验点击后停留在遥控器可用性页，并确认后续新连接事件仍能自动路由。
