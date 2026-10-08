# 2026-10-08 预览 UI 测试 App 路径被清理

## 错误证据

测试期间两次出现 macOS 弹窗“应用程序‘无线麦.app’已不能再打开”。弹窗时间附近没有新的无线麦进程启动记录。测试 App 使用的路径位于预览 UI 测试 worktree 输出目录；该目录随后已不存在。系统日志同时出现 `No such file or directory`。

## 日志结论

该现象不是 App 崩溃，也没有证据表明 `ApplicationInstanceGuard` 锁竞态导致启动失败。LaunchServices 在旧路径仍有打开请求时，目标 App 已被移动或清理，因此 macOS 报告旧路径不可用。

## 根因

UI 测试输出目录位于可被清理的 Git worktree/临时生命周期内。测试结束或 worktree 清理后，稳定 App 的 Sparkle 测试重启请求仍可能引用旧路径。

## 修复

`scripts/prepare-staged-preview-ui-test.sh` 现在要求输出路径为绝对路径，且位于 Git worktree 和临时目录之外；父目录必须预先存在。测试手册要求在 UI attestation 完成、所有 App 进程退出前保留该目录。

## 验证

- 脚本语法检查：`bash -n scripts/prepare-staged-preview-ui-test.sh`。
- 发布流程自检：`scripts/test-macos-release-flow.sh` 覆盖 worktree/临时路径拒绝门禁。
- Swift 测试与 App 构建不属于本次路径修复的必要验证范围。

## 边界

本修复覆盖预览 UI 测试输入准备和清理顺序。它不能替代真实 Sparkle 更新、退出、二次启动和用户硬件流程；这些仍需按 `Testing/MacReleaseBranchLifecycle.md` 完成。
