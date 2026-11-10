---
title: 切换器里按返回键会把高亮 App 切到前台
subtitle: 取消路径只松开 Command，被系统当成确认
lang: zh
template: doc
date: 2026-11-10
status: 已修复，单元测试通过；真机待验收
---

## 现象

起切换器后把高亮移到另一个 App，不按 OK 而直接按返回键：期望回到原 App，实际是高亮的那个 App 被切到前台。

只在「高亮已经离开原 App」时可见；没有移动过高亮时松手没有变化，所以现场表现为“有时候”。

## 证据

### 代码

修复前 `Sources/RemoteMic/KeyboardInjector.swift` 的 `AppSwitcherSession.cancel()` 在切换器层只发一个 Command 抬起：

```swift
guard isActive else { return true }
let released = post(leftCommandKeyCode, isDown: false, flags: [], role: "command")
isActive = false
return released
```

macOS 系统切换器的语义是：Command 松开即确认当前高亮项；取消必须在 Command 仍按住时按 Escape。也就是说这段实现把「取消」发成了「确认」。

### 运行日志

`~/Library/Logs/RemoteMic/runtime.log`（明文，不进入仓库）。筛选条件：会话以 `ended reason=back confirmed=false` 结束，且之前 4 行内没有 `role=escape`（即切换器层，不是窗口层）。

对每个会话比较返回前的最后一条 `switcher_state`（含高亮 App 与 `front=`）与返回后的第一条：

| 切换器层返回会话 | 返回后前台变成返回前高亮的 App |
| --- | --- |
| 20 | 20 |

示例时间戳（UTC）：`2026-11-10T09:51:00.630Z`、`09:55:16.419Z`、`09:55:33.009Z`、`10:00:44.172Z`、`10:01:16.586Z`。全部满足：返回前 `front` 是原 App，返回后 `front` 等于高亮 App。

作为对照，窗口层返回会先发 `role=escape`，属于另一条路径（见「剩余边界」）。

## 根因

`cancel()` 没有先发 Escape。Command 抬起本身就是系统的确认动作，因此取消必然退化成切换；与确认 `confirm()` 的区别只剩下没有按 Option，所以不会恢复最小化窗口。

## 最小修复

切换器层的取消改为「Esc 按下 → Esc 抬起（Command 仍按住）→ Command 抬起」：

- Escape 带上 `.maskCommand` 标志，保证系统按 `⌘Esc` 处理。
- 两次 Escape 与 Command 抬起都独立求值，Escape 失败时仍然释放 Command，避免修饰键卡住。

窗口选择层的取消逻辑不变（该层 Command 已松开，直接 Esc 即可）。

另外，`cancel()` 是所有取消路径共用的（返回、超时、外部点击、输入重置），不能无条件补 Escape：

- 超时、输入重置、绑定键打断：切换器仍在屏幕上，补 Escape 才是真正的取消，否则松开 Command 依旧会确认高亮项。
- 鼠标点击外部：系统已经自己关掉切换器，此时补 Escape 会落到被点击的 App 上，可能关掉它的弹窗或窗口。新增 `cancel(dismissSwitcher:)` 参数，只有这一条路径传 `false`，只松开 Command。

## 验证

- 新增单测 `appSwitcherSessionCancelSendsEscapeBeforeReleasingCommand`：断言取消时的事件顺序为 Esc down/up（`command=true`）后跟 Command up，且会话状态清理干净。
- 新增单测 `appSwitcherSessionCancelReleasesCommandWhenEscapeFails`：Escape 投递失败时最后一个事件仍是 Command up。
- 新增单测 `appSwitcherSessionCancelWithoutDismissalOnlyReleasesCommand` 与 `appSwitcherSessionCancelInWindowPickerWithoutDismissalOnlyReleasesCommand`：系统已关掉切换器时不补 Escape。
- 监控层 `appSwitcherBackTimeoutAndFrontmostChangeReleaseCommand` 补两组断言：返回取消必须以 Esc 结尾、鼠标点击收尾不得出现 Esc。
- 既有 3 个切换器会话单测保持通过；`swift test --disable-keychain --filter "appSwitcher"` 共 25 项通过。
- 真机：待维护者用遥控器按测试手册「用例 6」复验。

## 剩余边界

以下问题与本缺陷共用「返回键 / 窗口层」路径，但属于独立行为，未包含在本次修复中：

1. 窗口层里按返回只发 Escape，没有把原 App 拉回前台；系统在 Exposé 关闭后会保留被展示的 App。
2. 确认后 150–600ms 内按返回，`foregroundEnsure` / `singleWindowRestore` 等迟到任务不会被取消，仍可能激活目标 App。
3. `handlePendingLayerCloseBack` 的落地判定在 macOS 13 上可能误判，导致已成功切换时仍补一次 Escape。

## 基线与合入

从 `origin/main` = `97824e3b` 创建 `codex/fix-app-switcher-back-cancel-20261110`，改动范围为 `Sources/RemoteMic/KeyboardInjector.swift`、`Tests/RemoteMicTests/RemoteButtonsTests.swift` 与测试手册。
