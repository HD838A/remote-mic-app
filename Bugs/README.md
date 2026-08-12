# Bug 记录

- [Intel Sparkle appcast 缺少本地化更新说明](./2026-08-13-intel-appcast-missing-release-notes.md)
- [SwiftPM 资源构建路径进入发布 App](./2026-08-13-swiftpm-resource-build-path-leak.md)

本目录统一保存已经发现、调查或修复的问题。每个 Bug 使用独立 Markdown 文件，至少记录时间、状态、影响范围、功能点、简单描述和详细过程；无法从历史提交恢复的细节会明确标注，不补写推测。

新增 Bug 时先按“观察 → 假设 → 实验 → 结论”记录调查，确认根因后补充修复与验证。DEBUG.md 只保留入口说明，历史内容已迁移到这里。

## 固定解决流程

所有 Bug 统一按以下顺序处理：

1. **先复现 Bug**：记录触发条件、错误结果和正常边界；无法复现时明确缺少的条件。
2. **查看日志**：核对现场时间、事件顺序、设备或会话身份以及最终结果，不能把“已接收、已解码、已入队”直接当成功能可用。
3. **查看代码**：根据复现和日志缩小范围，提出根因假设并用最小实验验证。
4. **修复 Bug**：根因确认后只修改直接相关的代码，避免扩大范围。
5. **验证修复**：重新执行原复现，使同一用例从失败变为通过，并检查受影响的稳定基线。

每份 Bug 文档还必须明确实际执行过的测试、测试结果，以及模拟器、自动化和真机验证之间的边界。

## 硬件模拟与真机验收边界

- 硬件模拟作为日常回归主路径：固定回放控制事件、音频分片、停止时序、设备交替、异常包和 HID 手势，并直接驱动生产协议解析、解码、路由及停止策略。模拟用例必须能先复现旧 Bug，再证明修复后通过。
- 真机验收只负责模拟器无法证明的系统边界：真实蓝牙发现与订阅、固件实际时序、CoreBluetooth 与 HID 共存、权限、音频设备绑定、第三方语音工具触发，以及最终听感和文字输入体验。
- 真机语音按步骤写入 UTC 开始/结束标记；每个会话记录 trace、设备型号、时长、解码量、入队失败、输出路线和最终缓冲状态，但不记录用户语音内容。发现问题后只分析对应步骤区间，并继续遵循“复现 → 日志 → 代码 → 修复 → 重验”。
- 普通改动优先运行模拟回归；修改共享蓝牙协议、音频、HID、设备识别、Fn 模拟或系统权限时，发布预览版前仍需对受影响路线执行最小真机门禁，不能用构建、签名或模拟测试代替。

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
| 2026-08-09 | [RC001 Short Voice Stream Tail Dropped on STREAM_STOP](./2026-08-09-rc001-short-voice-stream-tail-dropped.md) | 已修复，模拟与真机回归通过 |
| 2026-08-10 | [Unbound Multi-Remote Button Actions Are Ignored](./2026-08-10-unbound-multi-remote-actions-ignored.md) | 已修复，双遥控器真机复验通过 |
| 2026-08-10 | [Upgrade Leaves Custom Button Mapping Inactive](./2026-08-10-upgrade-custom-mapping-not-activated.md) | 已修复，签名升级验证通过；待实体按键确认 |
| 2026-08-10 | [RC003 普通语音会话约一分钟停止](./2026-08-10-rc003-one-minute-voice-session-timeout.md) | `MIC_EXTEND` 候选方案已撤回，问题未解决 |
| 2026-08-10 | [已占用组合键无法录入](./2026-08-10-reserved-shortcut-capture.md) | 候选修复完成，等待真实系统热键验证 |
| 2026-08-10 | [左右键按住不能连续移动](./2026-08-10-left-right-hold-repeat.md) | 候选修复完成，硬件模拟通过，等待真机验证 |
| 2026-08-10 | [增益滑块轨道拖动带动整个窗口](./2026-08-10-gain-slider-drags-window.md) | 已修复，等待可见界面复验 |
| 2026-08-11 | [预发布候选工作流依赖 Runner 未安装的 rg](./2026-08-11-preview-candidate-runner-missing-rg.md) | 已修复 |
| 2026-08-11 | [Onboarding 新配对遥控器 BLE 与 HID 状态不刷新](./2026-08-11-onboarding-new-remote-ble-hid-refresh.md) | 候选修复完成，等待真机验收 |
| 2026-08-11 | [Onboarding 全流程恢复与最终可用性审计](./2026-08-11-onboarding-end-to-end-recovery-audit.md) | 候选修复完成，等待真实全流程验收 |
| 2026-08-11 | [遥控器设备卡名称、状态截断并重复展示](./2026-08-11-remote-device-card-clipping-and-duplication.md) | 候选修复完成，浅/深色页面通过 |
| 2026-08-11 | [升级后 Onboarding 已收到实体按键但仍显示蓝牙未连接](./2026-08-11-onboarding-upgrade-hid-before-ble.md) | 候选修复完成，等待真实升级与 RC003 验收 |
| 2026-08-11 | [蓝牙断连后虚拟麦克风仍保持活动](./2026-08-11-bluetooth-disconnect-keeps-virtual-microphone-active.md) | 候选修复完成，等待真机与会议 App 验证 |
| 2026-08-11 | [已安装用户升级后被要求重新完成 Onboarding](./2026-08-11-existing-users-forced-through-onboarding.md) | 候选修复完成，等待真实升级验收 |
| 2026-08-11 | [Onboarding 音频步骤错误地只接受 MiRemoteV 2ch](./2026-08-11-onboarding-requires-miremote-audio-device.md) | 候选修复完成，等待真实音频设备验收 |
| 2026-08-12 | [Remote Mic 运行期间 MacBook 实体方向键偶发失效](./2026-08-12-physical-arrow-keys-blocked.md) | 已修复，自动化通过，等待真机复验 |
| 2026-08-12 | [Mac 等待手机后无法取消或切换设备](./2026-08-12-mac-phone-waiting-cannot-cancel.md) | 已修复，等待多手机真机验收 |

## 记录模板

新文件至少包含以下字段：

- 时间：发现或首次记录日期
- 状态：调查中、已修复、等待真机验证或已归档
- 影响范围：版本、平台、设备和用户场景
- 功能点：对应模块或用户功能
- 简单描述：一句话说明错误行为
- 原始记录：日志、提交、版本历史或用户反馈

详细过程按需要记录观察、假设、实验、根因、修复和验证；历史资料不足时应明确说明，不得补写推测。
