# 个人中心侧边栏登录态截图证据

- 生成方式：`CONFIGURATION=release REQUIRE_SIRI_REMOTE_SIGNING=0 ./scripts/build-app.sh`，再使用生成的 `dist/SayAll.app` 内生产 `SettingsScreenshotRenderer` 离屏入口渲染。
- 逻辑窗口尺寸：`1020 × 772`
- PNG 像素尺寸：`2040 × 1544`
- 语言：简体中文
- 状态：该目录为 2026-09-21 的历史截图，未登录文案“登录”已被 2026-09-22 的修正版替换为“我”；当前截图见 `../sidebar-profile-login-20260922/`。

## 文件

- `profile-sidebar-login-zh-hans-light-1020x772.png`
  - 外观：浅色
  - SHA-256：`69202c6ec198c4d106cbadfc24944ea9808e219a2acd273b8eb922bc8e0efc4c`
- `profile-sidebar-login-zh-hans-dark-1020x772.png`
  - 外观：深色
  - SHA-256：`7d80ed209ee21679654d2e86224afe394652a5f45588f0d6c5e947acb38d864d`

两张截图均来自本次功能分支的生产 App，展示侧栏首项上移、分享入口和未登录个人中心入口。
