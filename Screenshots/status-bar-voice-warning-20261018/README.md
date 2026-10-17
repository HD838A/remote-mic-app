# RC001/RC003 会话边界提醒截图

- 来源：本分支提交 `6db5ee144545d8c6342b78e64e0875d0ed65e587` 构建的生产 App。
- App：无线麦 SayAll.app，Build 248，Apple Silicon，macOS 深色外观，简体中文。
- `production-app-window-dark-zh.png`：真实运行窗口，`2314 × 1636`，SHA-256 `5d4538c867fe8f5a57bfead1f42dc7e29e83714ea872215500398d90201a1727`。
- `production-menubar-dark-zh.png`：真实运行桌面菜单栏区域，`5120 × 360`，SHA-256 `1edbfe9ec4b5142cb31a7eb06e7bc8b1ef77c246dbcfb844367dd7f70ba50b0e`。
- `production-menubar-right-dark-zh.png`：真实运行桌面右侧菜单栏区域，`1520 × 180`，SHA-256 `0de62e02fdf79b61b8a03760fc8b0b17b640ad09c5ca909eb7d18cf7fac875fd`。

截图证明当前提交的生产 App 可以启动并显示菜单栏区域。黄色、红色阈值、闪烁和提示音使用真实 RC003 长会话及脱敏日志验收；证据见 [`Testing/StatusBarConnectionAppearance.md`](../../Testing/StatusBarConnectionAppearance.md)。
