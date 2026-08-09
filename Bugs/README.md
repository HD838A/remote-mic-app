# Bug 记录

本目录统一保存已经发现、调查或修复的问题。每个 Bug 使用独立 Markdown 文件，至少记录时间、状态、影响范围、功能点、简单描述和详细过程；无法从历史提交恢复的细节会明确标注，不补写推测。

新增 Bug 时先按“观察 → 假设 → 实验 → 结论”记录调查，确认根因后补充修复与验证。DEBUG.md 只保留入口说明，历史内容已迁移到这里。

## 索引

| 时间 | Bug | 状态 |
| --- | --- | --- |
| 2026-07-29 | [睡眠或音频路由变化后打开页面崩溃](./2026-07-29-audio-route-change-player-crash.md) | 已修复 |
| 2026-07-30 | [Automatic Application Focus Investigation](./2026-07-30-automatic-application-focus.md) | 已修复 |
| 2026-07-30 | [cmux Frontmost Refocus Follow-up](./2026-07-30-cmux-frontmost-refocus-follow-up.md) | 已修复 |
| 2026-07-30 | [普通安装要求下载 Xcode 命令行工具](./2026-07-30-installer-requires-xcode-command-line-tools.md) | 已修复 |
| 2026-07-31 | [cmux Frontmost Refocus Follow-up 2](./2026-07-31-cmux-frontmost-refocus-follow-up-2.md) | 已修复 |
| 2026-08-01 | [切换语言时菜单项重复挂载异常](./2026-08-01-language-switch-menu-duplicate-mount.md) | 已修复 |
| 2026-08-03 | [iOS 从后台返回后不自动重连](./2026-08-03-ios-foreground-auto-reconnect.md) | 已修复 |
| 2026-08-03 | [iPhone 麦克风权限已开但无法开始录音](./2026-08-03-ios-microphone-permission-open-but-recording-fails.md) | 已修复 |
| 2026-08-03 | [iOS 手机语音键无响应](./2026-08-03-ios-phone-voice-button-no-response.md) | 已修复，真机体验曾要求复验 |
| 2026-08-03 | [iOS 重启后仍无法重新连接 Mac](./2026-08-03-ios-relaunch-reconnect.md) | 已修复 |
| 2026-08-04 | [iOS 0.8.3 无法连接 Mac App](./2026-08-04-ios-083-cannot-connect-mac.md) | 已修复 |
| 2026-08-05 | [邀请码 Return 重复提交与二维码切换不稳定](./2026-08-05-phone-invite-return-and-qr-state.md) | 已修复 |
| 2026-08-05 | [预发布更新源不可用时阻止正式更新](./2026-08-05-prerelease-update-source-blocks-stable.md) | 已修复 |
| 2026-08-05 | [正式构建遗漏手机网页版服务器地址](./2026-08-05-production-web-relay-url-missing.md) | 已修复 |
| 2026-08-05 | [周统计与全部累计不一致](./2026-08-05-weekly-statistics-total-mismatch.md) | 已修复 |
| 2026-08-06 | [macOS 1.7.6 连接遥控器时启动退出](./2026-08-06-macos-176-hid-client-startup-crash.md) | 已修复 |
| 2026-08-06 | [手机网页版按键只能触发单击](./2026-08-06-mobile-web-buttons-only-single-click.md) | 已修复 |
| 2026-08-08 | [RC001-MS 语音遥控器适配](./2026-08-08-rc001-voice-remote-compatibility.md) | 兼容性调查已归档 |
| 2026-08-08 | [RC001 / RC003 型号与充电状态识别](./2026-08-08-remote-model-and-power-detection.md) | 已实现并归档 |
| 2026-08-09 | [Centered Remote Mapping Layout](./2026-08-09-centered-remote-mapping-layout.md) | UI 缺陷已修复 |
| 2026-08-09 | [Custom Shortcut Repeat and Sidebar Focus Regression](./2026-08-09-custom-shortcut-repeat-and-sidebar-focus.md) | 已修复 |
| 2026-08-09 | [Frontmost Remote Mic Navigation Repeat Error Sound](./2026-08-09-frontmost-navigation-repeat-error-sound.md) | 已修复 |
| 2026-08-09 | [Held Remote Key Leaks Native Auto-repeat](./2026-08-09-held-key-native-auto-repeat-leak.md) | 已修复 |
| 2026-08-09 | [Home and Volume-down Connector Crossing Follow-up](./2026-08-09-home-volume-down-connector-crossing.md) | UI 缺陷已修复 |
| 2026-08-09 | [Mapping Connector Overlap and Excessive Side Gaps](./2026-08-09-mapping-connectors-overlap-and-gaps.md) | UI 缺陷已修复 |
| 2026-08-09 | [Menu and TV Connector Crossing Follow-up](./2026-08-09-menu-tv-connector-crossing.md) | UI 缺陷已修复 |
| 2026-08-09 | [Multi-Remote Automatic HID Routing and RC003 Voice Regression](./2026-08-09-multi-remote-hid-routing-and-rc003-voice.md) | 已修复 |
| 2026-08-09 | [Post-fix Multi-Remote HID Report Routing Regression](./2026-08-09-post-fix-multi-remote-hid-routing.md) | 已修复 |
| 2026-08-09 | [RC001 Short Voice Stream Tail Dropped on STREAM_STOP](./2026-08-09-rc001-short-voice-stream-tail-dropped.md) | 已修复，模拟回归通过 |

## 记录模板

新文件至少包含以下字段：

- 时间：发现或首次记录日期
- 状态：调查中、已修复、等待真机验证或已归档
- 影响范围：版本、平台、设备和用户场景
- 功能点：对应模块或用户功能
- 简单描述：一句话说明错误行为
- 原始记录：日志、提交、版本历史或用户反馈

详细过程按需要记录观察、假设、实验、根因、修复和验证；历史资料不足时应明确说明，不得补写推测。
