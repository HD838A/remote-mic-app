# App 切换器左右键一次移动两格

- 复现：v1.9.21，非独占监听，左右方向键无双击/长按绑定；TV 打开切换器后短按左右。
- 证据：用户报告两格；runtime.log 每次实体按下仅一条 HID EDGE 与一条 APP SWITCHER navigate，连接为 mode=monitored。
- 根因：shouldUseNativePassthrough 未排除活动的 AppSwitcherSession，未 arm 原始 keyDown 抑制，同时 handleAppSwitcherControlPress 注入另一个方向键。
- 修复：活动切换会话不使用 native passthrough。会话外的视频方向键直通保持。
- 检查：隔离执行源码中的实际 predicate，修改前在 active=true、非独占、无附加手势时失败；修改后 64 个状态组合通过。该检查不等于完整 HID 或实体测试。
- 回归测试：扩展现有 AppSwitcher 控制测试，覆盖非独占监听及会话前后原始事件处理。在最新 main 的公开构建路径中运行回归：移除修复时非独占 keyDown 抑制断言失败；加入修复后 RemoteButtonsTests 与手势测试共 121 项通过。实体测试待执行。
- 手工验收：Testing/AppSwitcherRemoteControl.md 非独占监听回归。
