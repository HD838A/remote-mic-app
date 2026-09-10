# Agent 切换后没有聚焦输入框

## 复现与日志

2026-09-10 用户在开发版完成输入监控、辅助功能授权后，确认实体遥控器菜单 → 左右 → OK 可以切换 App，但输入框没有获得焦点。现场日志 07:35:51–07:35:54 UTC 记录完整 remote 切换操作，终态为 `AGENT SWITCHER phase=completed result=frontmost`，没有后续聚焦交接。

在生产控制器注入可观察的聚焦回调后，先运行：

```sh
swift test --disable-keychain --filter selectedApplicationFocusRunsOnceAfterFrontmostAndPanelDismissal
```

修复前断言失败：`focused=[]`，预期为选中的 `codex.bundle`。前台验证及面板关闭本身正常；故障边界是未调用聚焦步骤，不是按键映射或权限门禁。

## 原因与修复

控制器 `complete` 仅关闭面板并记录窗口置前，没有接入既有 App 聚焦流程。现在先确认选中 App 置前并关闭面板，再交接到 KeyboardInjector，按 Bundle ID 复用该 App 的保存配置。没有自定义配置的内置目标使用现有聚焦实现；明确「只打开」及未配置目标不会发送猜测快捷键。

交接不再次打开 App；检查前台身份，复用原有请求代次、权限和重试保护。重开切换器使旧聚焦请求失效。取消、超时、失败及迟到打开回调不能触发聚焦。日志关联切换与聚焦操作，快捷键提交不记录为最终输入框成功。

## 验证边界

控制器回归验证选中目标置前后、面板关闭后只交接一次，取消时不交接；聚焦路由测试覆盖自定义方式、内置方式、目标隔离、只打开、前台变化及脱敏日志。

2026-09-10 已完成本机自动化：

```sh
swift test --disable-keychain --filter AgentSwitcherFocusTests
swift test --disable-keychain
SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh
```

结果：`AgentSwitcherFocusTests` 8 个用例通过；完整 Swift 自动化 `504 tests / 43 suites` 通过；独立 selftests `44 passed / 0 failed`。第三方 App 输入框实机结果随本轮开发版运行补充。

用户确认的是修复前的实体遥控器切换；本轮输入框聚焦、各 App 冷启动、多屏、语音连续输入仍按 [测试手册](../Testing/AgentSwitcher.md) 独立记录，不能由单元测试或快捷键已提交代替验收。
