---
title: 录入普通快捷键时崩溃
subtitle: Build 264 · 线程边界修复
lang: zh
template: doc
---

## 现场证据

2.0.0 Build 264 在录入逗号时两次崩溃。
系统报告时间为 2026-10-26 00:23:46 和 00:24:05。
两次均为 EXC_BREAKPOINT / SIGTRAP。

调用栈顺序一致：

1. 快捷键录入的 event tap 回调。
2. NSEvent.charactersIgnoringModifiers。
3. HIToolbox 输入源读取。
4. dispatch_assert_queue 失败。

## 根因与反证

录入回调已移到专用线程。
普通字符名称仍在该线程解析。
输入源 API 在现场要求主队列，因而触发断言。
Space 等固定名称键不需要读取输入源，旧测试未覆盖逗号。

独立字符探针未复现现场崩溃。
该探针缺少现场事件与输入源上下文。
生产 RunLoop 回归明确复现错误线程，产生两项失败。
主线程解析断言失败，且异步回调前解析次数已为一。

## 最小修改

ShortcutCaptureMonitor 复制 CGEvent 快照。
专用线程立即返回拦截结果。
异步主队列回调再创建 NSEvent 并解析名称。
录入回调使用原有保存入口，不改变配置格式。

保留专用 event tap RunLoop。
不把 tap 放回主线程，也不增加同步等待。
日志只记录解析阶段与线程状态，不记录按键文字。

## 验证与边界

修复前线程回归出现两项失败。
修复后录入与端口生命周期 20 项测试通过。
完整 Swift Testing 1040 项与 XCTest 4 项通过。
工程自检 48 项和仓库治理检查通过。

验证命令：

- swift test --disable-keychain --filter resolvesCommaOnMainAfterReturningFromTheTapThread
- swift test --disable-keychain --filter 'ShortcutCaptureMonitorTests|EventTapPortTests'
- swift test --disable-keychain

真实键盘录入、输入法切换和配置保存仍需桌面验收。
本轮不替换已安装的 App，不修改音频或语音逻辑。
音量原生边沿不完整属于独立问题，不计为本项已修复。
