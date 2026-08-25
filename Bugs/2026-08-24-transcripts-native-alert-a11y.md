# 回眸页遗留废弃 alert API、图标按钮缺无障碍标签、自绘大标题

## 复现

- 环境:macOS 27;VoiceOver 与 Xcode 27 SDK 编译告警对照。
- 操作:「回眸」页对一条记录按 Tab 到复制/删除图标按钮听 VoiceOver;选中具体 App 观察标题层级;审查删除确认弹窗实现。
- 实际结果:复制/删除为仅图标 `.borderless` 按钮,只有 `.help`,VoiceOver 只能读到 SF Symbol 名;选中 App 名使用 22pt 自绘大标题,在 Section 内形成接近页面标题的层级;删除确认仍用 macOS 12 起废弃的 `.alert(item:)` + `Alert` 结构体。
- 预期结果:图标按钮有明确无障碍名称;标题回到系统语义层级;确认弹窗使用当前 `alert(_:isPresented:presenting:actions:message:)` API(删除属危险操作,保留系统弹窗)。

## 日志结论

纯界面与 API 遗留问题,无专用日志;Xcode 27 编译器对该文件持续报 `DeprecatedDeclaration` 告警。

## 根因

- 回眸页是原生设置重构中最后保留旧式 API 的页面:`.alert(item:)` 未被替换;图标按钮只做视觉提示;22pt 标题沿用旧设计。

## 修复

- `.alert(item:)` 换成 `alert(Text, isPresented:presenting:actions:message:)`:标题/消息拆为 `deletionAlertTitle` / `deletionAlertMessage(for:)`,动作直接调用既有 `performDeletion`,行为与文案不变。
- 复制/删除图标按钮分别加 `.accessibilityLabel`(复用与 `.help` 相同的文案 key,不新增 strings)。
- 选中 App 名从 `.system(size: 22, weight: .semibold)` 降为 `.headline`。

## 验证

- 修复前结构门禁:`.alert(item:` 存在、无 accessibilityLabel、22pt 硬编码存在。
- 修复后:`.alert(item:` 不再出现,`presenting: deletionRequest` 与两条 accessibilityLabel 断言通过,22pt 标题不再出现;31 项定向测试、344 项全量测试、成品构建与完整性校验通过;中文浅色/深色、英文 `800 × 650` 回眸页离屏渲染通过。

## 验证边界

VoiceOver 实际朗读与删除确认弹窗的真实呈现未做代理实测(无辅助功能权限),按测试手册人工复核;记录数据与删除链路未改。
