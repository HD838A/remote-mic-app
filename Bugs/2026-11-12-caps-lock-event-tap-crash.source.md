---
title: 输入组合动作名称时的 Caps Lock 崩溃
subtitle: 后台系统键事件解码修复候选
lang: zh
template: doc
---

## 现场证据

用户在组合动作名称框输入时，SayAll 2.0.0 Build 289 退出。
系统为 macOS 26.6.2，架构为 Apple Silicon。
崩溃线程为 `SayAll.EventTap`，异常为 `EXC_BREAKPOINT`。
调用链经过 `NSEvent eventWithCGEvent`、Caps Lock 输入法处理和队列断言。

核对相同 UUID 的安装版二进制后，调用点与 `KeyboardEventSuppressor.descriptor` 的系统键解码一致。
该分支将每个系统事件直接转为 `NSEvent`，包括 Caps Lock 事件。

## 根因实验

使用公开 API 构造 Caps Lock 系统键松开事件，在后台线程转换。
LLDB 在 `TSMSetCapsLockKeyTransitionDetected` 上命中一次。
仅将事件副本改为 `applicationDefined` 后，断点命中零次。
两种方式读出的事件数据相同，原始事件类型保持不变。

本机 macOS 27.0.1 未复现用户系统上的最终队列断言。
实验确认了进入同一输入法路径的条件及修复后的路径隔离。

## 修复

共用 `SystemKeyEventDecoder` 解码系统键数据。
先复制事件，再把副本改为普通应用事件，避免转换时执行 Caps Lock 输入法逻辑。
只解析 subtype 8 的辅助控制键消息。
拦截器和合成按键诊断观察器使用同一入口。
原事件继续按现有规则同步放行或拦截。

## 验证状态

91 项定向测试通过。
去除副本类型修复后，8 个参数用例失败，恢复后通过。
公开 Swift Testing 1355 项、99 套件通过，另有 XCTest 4 项通过。

完整签名包相关测试按公开 CI 口径排除。
公开 arm64 与 x86_64 Release 构建通过。
仓库边界、治理检查及补丁格式检查通过。
真实键盘、macOS 26.6.2 和最终宿主流程待现场验收。
步骤见 [快捷键生命周期测试](../Testing/CustomShortcutLifecycle.md)。
