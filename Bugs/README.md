# Bug 记录

- [组合动作后立即说话导致回眸整段漏记](./2026-08-19-reflections-initial-focus-unavailable.md)
- [组合动作输入框学习容易与回眸 MCP 配置混淆](./2026-08-19-macro-focus-mcp-guidance-confusion.md)
- [1.9.0 内测版 OK 键偶发无响应且日志无法定位](./2026-08-19-ok-button-intermittent-hid-report-loss.md)
- [遥控器持续连接时虚拟音频阻止 Mac 自动休眠](./2026-08-18-connected-virtual-audio-blocks-mac-idle-sleep.md)
- [Watch 停止后立即重新收音被判定占用](./2026-08-19-watch-voice-restart-during-audio-drain.md)
- [Apple Watch BLE 语音已启动但没有有效电平](./2026-08-18-watch-ble-audio-no-signal.md)
- [回眸页面阻断 Intel Ventura 构建](./2026-08-18-reflections-intel-ventura-onchange.md)
- [v1.8.25 安装后 App bundle 仍显示 Remote Mic](./2026-08-17-v1.8.25-remote-mic-bundle-name.md)
- [MiRemoteV 2ch 音频通道偶发失效，重新选择后恢复](./2026-08-17-miremotev-audio-channel-stale-until-reselected.md)
- [没有实体遥控器的用户无法完成 Onboarding](./2026-08-17-onboarding-requires-physical-remote.md)
- [移动设备已连接后仍显示正在等待](./2026-08-15-mobile-connection-still-shows-waiting/DEBUG.md)
- [macOS 签名发布并发缓存冲突与无限等待](./2026-08-16-macos-signed-release-timeout.md)
- [发布阶段 heartbeat 与 timeout 同时到期导致 CI 偶发失败](./2026-08-16-release-stage-heartbeat-timeout-flake.md)
- [正式版晋升 Runner 缺少 ripgrep](./2026-08-17-stable-promotion-runner-missing-rg.md)
- [Intel Sparkle appcast 缺少本地化更新说明](./2026-08-13-intel-appcast-missing-release-notes.md)
- [SwiftPM 资源构建路径进入发布 App](./2026-08-13-swiftpm-resource-build-path-leak.md)
- [GitHub Actions 无法读取私有 Mac 远控组件](./2026-08-13-private-mac-remote-package-ci-access.md)
- [真实候选版本号导致预发布生命周期测试夹具失败](./2026-08-13-preview-lifecycle-fixture-current-version.md)
- [语音记录在快速发送或连续语音时丢失](./2026-08-17-transcript-history-quick-send-loss.md)
- [Codex MCP 配置使用无效 TOML 转义](./codex-mcp-invalid-toml-escaping.md)

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
| 2026-08-19 | [组合动作后立即说话导致回眸整段漏记](./2026-08-19-reflections-initial-focus-unavailable.md) | 候选修复完成，等待真实 Codex 与遥控器验收 |
| 2026-08-19 | [Watch 停止后立即重新收音被判定占用](./2026-08-19-watch-voice-restart-during-audio-drain.md) | 候选修复完成，等待真机验收 |
| 2026-08-19 | [组合动作输入框学习容易与回眸 MCP 配置混淆](./2026-08-19-macro-focus-mcp-guidance-confusion.md) | 说明已优化，等待有效资格页面人工验收 |
| 2026-08-19 | [1.9.0 内测版 OK 键偶发无响应且日志无法定位](./2026-08-19-ok-button-intermittent-hid-report-loss.md) | 诊断增强完成，等待 RC003 真机复现并确认根因 |
| 2026-08-18 | [遥控器持续连接时虚拟音频阻止 Mac 自动休眠](./2026-08-18-connected-virtual-audio-blocks-mac-idle-sleep.md) | 候选修复完成，等待真实休眠与 `pmset` 验收 |
| 2026-08-18 | [回眸页面缺少侧边栏入口](./2026-08-18-reflections-sidebar-entry-missing.md) | 已修复，等待 800 × 650 组合页面人工验收 |
| 2026-08-18 | [回眸页面阻断 Intel Ventura 构建](./2026-08-18-reflections-intel-ventura-onchange.md) | 已修复，等待 Intel 真机验收 |
| 2026-08-18 | [Apple Watch BLE 语音已启动但没有有效电平](./2026-08-18-watch-ble-audio-no-signal.md) | 诊断修复完成，等待真机验收 |
| 2026-08-18 | [Codex MCP 配置使用无效 TOML 转义](./codex-mcp-invalid-toml-escaping.md) | 修复完成，等待真实 Codex 验收 |
| 2026-08-17 | [语音记录在快速发送或连续语音时丢失](./2026-08-17-transcript-history-quick-send-loss.md) | 修复完成，等待真实快速发送复验 |
| 2026-08-18 | [800 × 650 按键映射页页头被压成竖排](./2026-08-18-settings-mapping-header-compressed-800x650.md) | 已修复，等待最终打包 App 可见页面复验 |
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
| 2026-08-08 | [RC001 / RC003 型号与充电状态识别](./2026-08-08-remote-model-and-power-detection.md) | 已修复 <!-- workshop:status=已完成;priority=P2 --> |
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
| 2026-08-11 | [Onboarding 新配对遥控器 BLE 与 HID 状态不刷新](./2026-08-11-onboarding-new-remote-ble-hid-refresh.md) | 已修复 <!-- workshop:status=已完成;priority=P2 --> |
| 2026-08-11 | [Onboarding 全流程恢复与最终可用性审计](./2026-08-11-onboarding-end-to-end-recovery-audit.md) | 候选修复完成，等待真实全流程验收 |
| 2026-08-11 | [遥控器设备卡名称、状态截断并重复展示](./2026-08-11-remote-device-card-clipping-and-duplication.md) | 候选修复完成，浅/深色页面通过 |
| 2026-08-11 | [升级后 Onboarding 已收到实体按键但仍显示蓝牙未连接](./2026-08-11-onboarding-upgrade-hid-before-ble.md) | 已修复 <!-- workshop:status=已完成;priority=P2 --> |
| 2026-08-11 | [蓝牙断连后虚拟麦克风仍保持活动](./2026-08-11-bluetooth-disconnect-keeps-virtual-microphone-active.md) | 已修复 <!-- workshop:status=已完成;priority=P2 --> |
| 2026-08-11 | [已安装用户升级后被要求重新完成 Onboarding](./2026-08-11-existing-users-forced-through-onboarding.md) | 候选修复完成，等待真实升级验收 |
| 2026-08-11 | [Onboarding 错误拒绝 BlackHole 2ch](./2026-08-11-onboarding-requires-miremote-audio-device.md) | BlackHole 支持已恢复，等待真实音频设备验收 |
| 2026-08-12 | [Remote Mic 运行期间 MacBook 实体方向键偶发失效](./2026-08-12-physical-arrow-keys-blocked.md) | 已修复，自动化通过，等待真机复验 |
| 2026-08-12 | [Mac 等待手机后无法取消或切换设备](./2026-08-12-mac-phone-waiting-cannot-cancel.md) | 已修复，等待多手机真机验收 |
| 2026-08-13 | [GitHub Actions 无法读取私有 Mac 远控组件](./2026-08-13-private-mac-remote-package-ci-access.md) | 已修复，两架构 CI 验证通过 |
| 2026-08-13 | [真实候选版本号导致预发布生命周期测试夹具失败](./2026-08-13-preview-lifecycle-fixture-current-version.md) | 已修复，自动化验证通过 |
| 2026-08-14 | [内测邀请码兑换成功但客户端无反应](./2026-08-14-early-access-fractional-server-time.md) | 已修复，等待签名安装包与用户验收 |
| 2026-08-14 | [预览候选首次打开设置窗口因私有资源 Bundle 路径崩溃](./2026-08-14-preview-private-resource-bundle-startup-crash.md) | 已修复，等待新签名候选验证 |
| 2026-08-14 | [1.8.22 点击快捷指令后 App 崩溃](./2026-08-14-quick-commands-click-crash.md) | 源码修复完成，等待新签名包与用户验收 |
| 2026-08-14 | [私有邀请码页面显示本地化 Key 且文本编辑快捷键不可用](./2026-08-14-private-enrollment-localization-edit-shortcuts.md) | 候选修复完成，等待最终签名 App 人工验收 |
| 2026-08-14 | [Watch 与 iPhone 附近连接同时回归](./2026-08-14-watch-ios-nearby-connection-regression/DEBUG.md) | 已修复并通过自动化/本机发布验证，等待实际设备验收 |
| 2026-08-15 | [Watch BLE 音频积压阻塞 iPhone 语音](./2026-08-15-watch-ble-audio-backlog-blocks-iphone/DEBUG.md) | 候选修复完成，等待真实 Watch 与实际测试 Mac 验收 |
| 2026-08-15 | [移动设备已连接后仍显示正在等待](./2026-08-15-mobile-connection-still-shows-waiting/DEBUG.md) | 候选修复完成，等待真实 iPhone / Watch 验收 |
| 2026-08-16 | [macOS 签名发布并发缓存冲突与无限等待](./2026-08-16-macos-signed-release-timeout.md) | 第二次修复完成，等待下一次真实受保护工作流验证 |
| 2026-08-16 | [发布阶段 heartbeat 与 timeout 同时到期导致 CI 偶发失败](./2026-08-16-release-stage-heartbeat-timeout-flake.md) | 已修复，自动化验证通过 |
| 2026-08-17 | [正式版晋升 Runner 缺少 ripgrep](./2026-08-17-stable-promotion-runner-missing-rg.md) | 已修复，等待下一次受保护晋升验证 |
| 2026-08-17 | [MiRemoteV 2ch 音频通道偶发失效，重新选择后恢复](./2026-08-17-miremotev-audio-channel-stale-until-reselected.md) | 宿主侧候选修复完成，等待真实 MiRemoteV 与第三方 App 验收 |
| 2026-08-17 | [Onboarding 语音工具页卡片错位并依赖内部滚动](./2026-08-17-onboarding-voice-tool-layout-scroll.md) | 候选修复完成，浅色与深色页面已复验 |
| 2026-08-17 | [没有实体遥控器的用户无法完成 Onboarding](./2026-08-17-onboarding-requires-physical-remote.md) | 候选修复完成，等待 iPhone 与网页版真机验收 |
| 2026-08-18 | [Onboarding 普通音频设备与手动文字错误通过](./2026-08-18-onboarding-miremote-and-manual-text-gates.md) | 候选修复完成，等待真实语音工具验收 |
| 2026-08-19 | [Onboarding 错误拒绝 BlackHole 2ch](./2026-08-19-onboarding-blackhole-support.md) | 候选修复完成，等待真实 BlackHole 验收 |

## 记录模板

新文件至少包含以下字段：

- 时间：发现或首次记录日期
- 状态：调查中、已修复、等待真机验证或已归档
- 影响范围：版本、平台、设备和用户场景
- 功能点：对应模块或用户功能
- 简单描述：一句话说明错误行为
- 原始记录：日志、提交、版本历史或用户反馈

详细过程按需要记录观察、假设、实验、根因、修复和验证；历史资料不足时应明确说明，不得补写推测。
