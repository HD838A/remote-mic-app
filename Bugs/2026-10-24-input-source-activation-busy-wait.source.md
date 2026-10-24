---
template: doc
theme: shadcn
title: 输入源激活等待忙循环
lang: zh
---

## 问题与证据

范围为显式 Command/Option 语音的输入源激活等待。目标已就绪时不进入等待。真实 Fn 路径不调用等待器。

没有对应现场日志和主线程采样。本次使用生产默认等待器和注入的输入源查询复现。测试没有调用系统输入源 API，也没有注入系统按键。

修复前，延迟 40ms 的 common-mode Timer 无法执行。三次连续会话均超时。一次 500ms 等待约查询 160 万次。等待期间的结束和 stop 也未及时执行，日志记录为超时。

三个测试共记录 14 条失败断言。证据来自 `PreferredInputSourceMonitorTests.productionWaiter*` 的修复前运行。

## 根因与最小修复

`RunLoop.Mode.common` 表示模式集合，不是具体运行模式。`run(mode:before:)` 立即返回。外层 while 持续查询，未按 20ms 的设计节拍等待。

改为 `.default`，使主 RunLoop 等待并派发事件。保留 500ms 超时、20ms 检查间隔和现有输入源 owner 状态机。没有修改按键、音频、配置、权限或外部协议。

现有日志继续区分 `activation_cancelled` 与 `activation_timeout`。恢复仍使用原有日志；轮询内部不新增日志。

## 影响与回归

| 范围 | 验证 |
| --- | --- |
| 默认等待器 | 延迟激活、三次连续会话、等待中 Fn 按下/释放、结束与 stop、超时及只恢复一次 |
| 输入源状态机 | 原有多 owner、第三输入源保护、已就绪旁路、真实 Fn 即时路径 |
| 共享语音链路 | 按键配对、pending-down 取消、早到 PCM、首次语音与尾包基线自动化 |
| 构建与独立性 | 公开宿主无私有依赖测试；Apple Silicon 与 Intel Release 构建 |

定向命令：`swift test --disable-keychain --filter 'PreferredInputSourceMonitorTests|VoiceKeyModeTests|VoiceFunctionKeyLatchTests|ATVVProtocolTests|CoreVoiceInputJourneyTests|VoiceInputDestinationCoordinatorTests'`。

定向结果：81 项通过。`swift test --disable-keychain` 全量 951 项通过。项目自检 48 项通过。仓库治理与仓库边界检查通过。

Apple Silicon macOS 14 Release 构建通过。Intel macOS 13 Release 构建通过。

## 真实验收边界

仍为候选修复。自动化只证明进程内等待和状态机。未完成真实 TIS、豆包/微信冷启动热启动、权限变化、实体遥控器及第三方文字上屏验收。

需要按[语音键手册](../Testing/VoiceKeyModes.md)执行新增矩阵。核对极速松键、连续会话、按下到首个有效 PCM 和首字耗时，以及正常松键尾字完整。不得用模拟结果代替现场验收。

回滚本提交即可恢复旧实现。数据格式没有变化。
