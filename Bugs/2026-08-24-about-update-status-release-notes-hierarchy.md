# 关于页更新检查状态与更新日志层级混杂

## 复现

- 环境：用户提供的“关于 → 版本与更新”浅色截图，当前版本 `1.9.8`，检查结果为已是最新版本。
- 操作：打开关于页并查看“当前版本”和“新版本内容”两行。
- 实际结果：“当前版本”只显示版本号和检查操作；“新版本内容”却显示“已是最新版本 / 当前更新通道没有更高版本”，使检查结果看起来像更新日志。
- 预期结果：“当前版本”负责已安装版本、检查动作和检查结果；“新版本内容”只负责确实可用的新版本更新日志。

## 日志结论

检查截图时段，没有发现 SwiftUI、布局约束、资源加载、崩溃或更新状态机错误。页面正确取得 `.upToDate` 状态，但把该状态渲染到了错误的信息行，属于稳定的视图层级问题。

## 反馈循环

修复前结构门禁输出：

```text
FAIL: update status and release notes are still mixed across the version rows
```

门禁要求“当前版本”行同时引用更新状态视图与更新动作，并要求“新版本内容”行只引用发布说明视图、不得引用检查状态视图；2026-08-25 更新动作已收敛为单一状态化按钮。

## 根因

单一 `updateInformationContent` 根据 `UpdateInformationState` 同时渲染两类语义：`.idle / .checking / .upToDate / .unavailable` 是更新检查状态，`.available` 则是新版本发布说明。父级无条件把这个视图放在“新版本内容”行，因此该行会随状态在“检查结果”和“更新日志”之间改变含义；另外“最新版本”在 `.available` 时又被拆成第三条独立行。

## 修复

- `aboutCurrentVersionRow` 统一承载当前版本、单一状态化更新按钮和 `aboutUpdateStatusView`。
- `aboutUpdateStatusView` 处理空闲、检查中、已是最新、检查不可用以及发现新版本时的最新版本号。
- `aboutReleaseNotesRow` 只在 `.available` 时出现，并只承载 `aboutReleaseNotesView`。
- `aboutReleaseNotesView` 只显示目标版本标题、无说明状态或真实更新条目，不再显示检查结果。
- 保留原有更新检查、Sparkle 更新、预发布开关、版本历史和本地化 key，不改变更新状态机或网络请求。

## 验证

- 原结构门禁修复后输出：`PASS: update status belongs to Current Version and release notes own the second row`。
- `swiftc -frontend -parse Sources/RemoteMic/SettingsView.swift Tests/RemoteMicTests/SettingsPageRegressionTests.swift`：通过。
- `git diff --check`：通过。

## 验证边界

Xcode 27 下 30 项设置页测试、342 项全量测试、成品构建与完整性检查通过；中文浅色/深色 `800 × 650` 和浅色 `920 × 700` 关于页默认状态层级正常。英文及检查中、已最新、检查失败和可更新等动态状态仍按测试手册逐项验收。
