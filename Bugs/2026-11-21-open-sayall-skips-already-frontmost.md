# 打开 SayAll 时未重新显示设置窗口

- 来源为 PR #886 的 `ad75e8eb`。它在预设应用已在前台时跳过重新打开，以避免第三方编辑器丢失焦点。
- 2.0.9（412）有 20 次音量减路由到打开 SayAll，再以 `already_frontmost` 结束。代码跳过了现有的重开请求与设置窗口入口。日志没有记录当时每个窗口的可见状态。
- 打开 SayAll 使用现有窗口重开路径。回归 `openingSayAllReopensItsWindowEvenWhenAlreadyFrontmost` 在修改前没有收到打开请求。已有 WorkBuddy 焦点测试继续覆盖第三方应用的行为。
- 实机分别覆盖 SayAll 在后台、已在前台且设置窗口可见、已在前台且需要重新显示窗口。
