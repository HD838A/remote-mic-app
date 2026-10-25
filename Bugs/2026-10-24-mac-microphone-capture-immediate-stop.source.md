---
title: Mac 麦克风会话启动后立即停止
subtitle: 现场日志显示配置通知被误判为采集失败
source: PR #739 后续 Bug 修复
---
## A 现象
用户点击“用 Mac 麦克风说话”后，页面返回空闲状态。
语音工具没有收到有效声音。
悬浮提示使用系统 `.help`，显示时间不稳定。

## B 现场日志证据
现场日志来自 `/path/to/user-home/Library/Logs/RemoteMic/runtime.log`。
两次操作都进入 `requested → route_ready → started`。
每次启动后约 20–30 ms 进入 `stopping reason=capture`。
采集结果为 `samples=0`，`conversion_failed=false`。
日志没有 `first_pcm`，也没有转换失败事件。

## C 根因
`MacMicrophoneCapture` 为 `AVAudioEngineConfigurationChange` 注册了失败回调。
回调没有检查当前输入设备是否仍是用户选择的设备。
启动设备绑定可能产生一次配置通知。
该通知被误判为采集失败，所以会话在首个 PCM 到达前结束。

## D 修复
配置通知先读取当前输入设备。
当前设备仍是所选设备时，记录并忽略通知。
当前设备明确变更时，保留采集失败并结束会话。
未知设备状态不立即结束会话。
按钮改用即时自绘悬浮提示，并保留辅助功能提示。

## E 验证边界
`swift test --disable-keychain --filter MacMicrophoneInputTests` 已通过。
自动化验证覆盖配置通知决策和现有 Mac 麦克风会话状态机。
真实麦克风、真实第三方输入工具和现场文字上屏仍需用户复验。
