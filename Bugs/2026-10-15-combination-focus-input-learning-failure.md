# 输入框学习失败与组合动作聚焦

## 错误证据

用户在开始学习输入框时看到“输入框学习失败：未能完成操作。FOCUSlearningerror”。按键页面的“聚焦输入框”可以使用。用户希望组合动作先打开 App，再自动聚焦输入框。

## 调查结论

按键页面使用公开宿主的前台输入框聚焦回调。旧组合动作使用私有 Package 的 Accessibility 学习记录。两条路径不同。

旧学习路径在倒计时结束后只读取一次 system-wide Accessibility 焦点。Electron、WebKit 和部分 App 会延迟建立 Accessibility 树，或先把焦点暴露为容器角色，因此会错误返回 `FOCUSlearningerror`。错误类型没有实现 `LocalizedError` 时，界面还会丢失具体原因。

## 修复

- 为学习错误提供 `errorDescription`，保留具体原因。
- 学习前对目标 App 设置 `AXManualAccessibility`；不支持时降级到 `AXEnhancedUserInterface`。
- 优先从目标 App 自身读取焦点，避免 system-wide 焦点短暂落在无线麦页面。
- 在有限重试窗口内等待 Accessibility 树和可编辑控件出现。
- 支持 `AXTextField`、`AXTextArea` 和 `AXComboBox`；地址栏和搜索框可以学习，仍拒绝密码、Token、密钥、银行卡等敏感输入框。
- 增加独立“聚焦输入框”组合动作步骤。它不保存学习记录。
- 宿主复用公开聚焦能力，并等待最终聚焦回调。
- 聚焦失败、取消或超时停止后续步骤。
- 旧“聚焦学习过的输入框”步骤保持原校验和兼容行为。
- 旧私有二进制没有新回调时隐藏新按钮，并报告缺少能力。

## 验证

- 私有组合动作 Package：`swift test --disable-keychain`，128 项中 126 项通过、2 项跳过。
- 收费按键方案 Package：`swift test --disable-keychain --package-path packages/macos-button-profiles`，80 项通过。
- 公开宿主：无私有组件 `swift test --disable-keychain`，884 项测试通过。
- 公开宿主接入当前私有源码：`SAYALL_COMBINATION_ACTIONS_PATH=... swift test --disable-keychain`，892 项测试通过。
- 本地 `.app` 使用 1020×772 窗口验证中文浅色、中文深色和英文浅色页面。截图保存在本次交付的持久化证据目录。
- 本地空白输入框 App 验证“打开 App → 聚焦输入框”。执行后 Accessibility 焦点进入文本输入区，组合动作显示成功。

2026-10-16，公开 PR #676 的收费集成 CI 发现旧执行器遗漏 `.focusInput`，编译报错 `switch must be exhaustive`。旧执行器没有宿主聚焦回调，因此明确返回缺少依赖。当前宿主仍通过统一组合动作执行新步骤。公开依赖清单固定到私有提交 `efa9fdb6e85b88ad578efcb3740ebafe4188c8e7`，覆盖该修复。

## 未覆盖边界

第三方 App 的真实控件响应、Intel Mac、真实遥控器触发和生产私有二进制构建仍需现场验证。构建和本地 Accessibility fixture 不能替代这些验证。现场验收必须确认目标 App 的 Bundle ID、辅助功能权限、学习成功提示、重启后测试聚焦和真实遥控器触发。
