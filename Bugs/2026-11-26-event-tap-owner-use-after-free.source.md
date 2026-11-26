---
template: doc
theme: auto
title: 事件 tap 回调对象释放后访问
subtitle: SIGSEGV in KeyboardEventSuppressor.handle
source: 2026-11-26 · 无线麦 SayAll / macOS
status: 修复完成，自动化通过；真机待验收
---

Lead: 全量测试进程中 `SayAll.EventTap` 线程偶发 `EXC_BAD_ACCESS`。根因是事件 tap 回调保存了未保留的 owner 指针。测试停止 tap 后对象释放，WindowServer 仍投递最后一个事件。

## 证据

- Crash 报告：`~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-2026-11-26-215727.ips`。
- 异常：`EXC_BAD_ACCESS (SIGSEGV)`，`KERN_INVALID_ADDRESS at 0x18`。
- Faulting thread：`SayAll.EventTap`。
- 栈：`swift_retain` → `KeyboardEventSuppressor.handle(type:event:)` → `keyboardEventSuppressorCallback` → `SkyLight processEventTapData`。
- 另一份报告 `swiftpm-testing-helper-2026-11-26-193136.ips` 停在 `KeyboardEventSuppressor.swift:381`，同样是 `EXC_BAD_ACCESS`。
- 崩溃时正在运行的测试不固定：`importsLegacyPersonalConfigurationQueuedFromSettingsDrop`、`staleConnectionStateCannotRestartAStoppedServiceDuringSleep`、`shortcutCaptureTapPrecedesLocalMonitor`。
- `shortcutCaptureTapPrecedesLocalMonitor` 只读源码，不创建 tap。它只是回调异步到达时正在运行的测试。

## 根因

`KeyboardEventSuppressor.start()` 用 `Unmanaged.passUnretained(self)` 注册 tap。`ShortcutCaptureMonitor.start()` 使用同样的模式。

测试执行 start/stop 循环后，owner 释放。`EventTapPort.release` 会 disable、摘除 source 和 invalidate 端口，但系统可能已经排队最后一个事件。回调随后调用 `takeUnretainedValue()` 并进入 `handle`，访问已释放对象。

`EventTapPort.release` 的 500 ms fallback 会从调用线程强制 invalidate 端口，明确允许与回调并发。这条路径没有同步 owner 的生命周期。

## 修复

- `KeyboardEventSuppressor` 和 `ShortcutCaptureMonitor` 在 start 时用 `passRetained` 保留 owner，并存入 `tapOwner`。
- stop 时先调用 `EventTapPort.release`。只有 tap RunLoop 确认摘除成功后才释放 owner。
- `EventTapPort.release` 返回是否在超时前完成排空。超时时保留 owner，记录 `owner_retained` 日志；端口已 invalidate，这次保留是有界泄漏，不是 use-after-free。
- start 的失败清理路径同样按 release 结果决定是否释放 owner。
- 新增测试：start 后离开强引用作用域，owner 仍存活；stop 后 owner 释放。

## 验证

- `swift test --disable-keychain --no-parallel --skip BuildSigningTests --filter EventTapPortTests`：12 项通过。
- 新增测试：`keyboardEventSuppressorKeepsOwnerAliveUntilStop`、`shortcutCaptureMonitorKeepsOwnerAliveUntilStop`。
- 全量公开测试：见 PR 验证记录。
- 真实 App 的快捷键录入、HID 权限撤销和退出清理仍须实机验收。

## 边界

- 本修复不改变 tap 的启用条件、事件吞噬规则或快捷键行为。
- 超时 fallback 的 owner 保留是异常路径的受控泄漏。它优先保证进程不崩溃。
- 全盘克隆、TCC 权限变化和真实 HID 设备不在自动化覆盖范围。
