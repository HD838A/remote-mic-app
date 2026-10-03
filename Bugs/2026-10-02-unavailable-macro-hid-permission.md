# 组合动作拒绝被误记为 HID 权限失效（开发期回归）

- 范围：统一按键源码候选，未发布。
- 复现：辅助功能检查返回有效，确认键绑定已删除动作；连续注入两份相同按下报告。
  预期仅拒绝一次、保持按住状态；修复前执行器收到两次请求，状态错误变为辅助功能权限失效。
- 日志：`hid-macro-reproduction.log` 两项断言失败；HID ACTION failed 后进入 stop，
  状态为 `button_mapping.permission.accessibility_expired`，没有可确认的权限撤销证据。
- 根因：HID 普通执行器 Bool 失败分支原来只处理键盘投递失败，新宏的不可用/忙碌拒绝也经过该分支。
  stop 清除 activeUsages 后，同一报告被再次识别为新按下。
- 修复：组合动作拒绝仅终止当前动作并保留按住状态；其他动作保留现有权限失败处理。
- 复验：`swift test --disable-keychain --filter rejectedMacroDoesNotReleaseHIDOrInventPermissionFailure`
  验证相同报告只产生一次请求、没有权限失效状态；完整三配置回归另见统一按键手册。
- 边界：使用注入式执行器和硬件报告，未替代实体设备及系统权限验收。
