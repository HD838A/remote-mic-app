# 卸载后残留 Siri Remote 安装收据和 Dock 固定项

- 时间：2026-11-20
- 状态：候选修复完成，等待真实签名卸载包验收
- 影响范围：macOS 卸载 PKG；安装过 Siri Remote 可选组件或把 App 固定在 Dock 的用户
- 功能点：安装、卸载、Siri Remote 可选组件、Dock 入口
- 简单描述：完整卸载后，`com.hd838a.RemoteMic.siri-remote` 收据仍在；重新安装时安装器继续自动勾选 Siri Remote，App 的 Onboarding 也继续认为该组件可用。若用户把 App 固定在 Dock，卸载后固定项仍指向已移入废纸篓的 App。
- 原始记录：2026-11-20 用户询问卸载 PKG 是否遗漏这两项清理，并明确要求保留 App 配置文件和日志。

## 复现与证据

1. 检查卸载脚本：`packaging/doubao-driver/uninstall/postinstall` 只移走 App、驱动、HCI helper、LaunchDaemon、HCI 状态目录和驱动名称记录，没有 `pkgutil --forget`。
2. 安装器用 `my.target.receiptForIdentifier('com.hd838a.RemoteMic.siri-remote')` 决定是否自动勾选 Siri Remote。收据存在时，完整卸载后的下一次安装仍会选中该组件。
3. App 的 Onboarding 直接检查 `/var/db/receipts/com.hd838a.RemoteMic.siri-remote.plist`。收据残留时，没有 helper 的 App 仍显示 Siri Remote 来源。
4. 卸载脚本没有引用 `persistent-apps` 或 Dock。用户固定到 Dock 的条目保存在 `~/Library/Preferences/com.apple.dock.plist`，把 App 移入废纸篓不会删除该条目。
5. 本机检查：`pkgutil --pkg-info com.hd838a.RemoteMic.siri-remote` 返回 2.0.6；`com.apple.dock` 的 `persistent-apps` 中存在指向 `/Applications/SayAll.app` 的 SayAll 条目。

## 日志结论与缺口

旧卸载器只输出 `DRIVER_NAMING` 相关日志，没有 Siri 收据或 Dock 清理结果。问题发生在 Installer `postinstall` 的安装元数据和用户 Dock 偏好，不涉及 App 运行日志。修复前没有可对应的 App `runtime.log`。

## 根因

- 卸载脚本只处理可移动的安装项，没有把 Siri Remote 组件收据视为安装元数据。
- 卸载脚本没有处理当前控制台用户的 Dock 固定项；`pkill -x RemoteMic` 只能让运行时 Dock 图标随进程退出消失。
- 现有测试手册只检查 App、驱动、HCI helper、LaunchDaemon 和本地设置，没有覆盖收据与固定 Dock 项。

## 修复

1. 卸载成功后，在没有留下无法确认归属的 Siri helper 或 LaunchDaemon 时执行 `pkgutil --volume "$TARGET_VOLUME" --forget com.hd838a.RemoteMic.siri-remote`。收据不存在时跳过；无法确认归属的组件仍在时保留收据。
2. 仅对当前控制台用户，导出 `com.apple.dock`，删除 `persistent-apps` 中指向本次被卸载 App（包括刚移入废纸篓的路径）的条目，再导入并重启 Dock。其他 Dock 条目和设置保持不变；非启动卷、无控制台用户或无法读取偏好时跳过并记录原因。
3. 收据或 Dock 清理失败时，已移动的安装项不回滚；卸载器明确提示部分清理失败并返回非零，避免把失败报告成成功。
4. 不修改 App 的 `UserDefaults`、`~/Library/Logs/RemoteMic`、历史、录音或其他用户数据。驱动名称记录仍按既有行为移入废纸篓，需要时可恢复。
5. 新增 `scripts/test-uninstaller-cleanup.sh` 和 `BuildSigningTests.uninstallerCleanupFixturePasses`，并把静态门禁和回放接入 `scripts/test-installer-architecture-guard.sh`。

## 验证

- `zsh -n packaging/doubao-driver/uninstall/postinstall`
- `./scripts/test-uninstaller-cleanup.sh`
- `./scripts/test-installer-architecture-guard.sh`
- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter BuildSigningTests`
- `git diff --check`

## 真实环境边界

本轮不生成 Developer ID 签名、公证并 staple 的卸载 PKG，也不修改真实 `/Applications`、系统 helper 或用户 Dock。仍需在 Apple Silicon macOS 14+ 与 Intel Ventura 上用最终候选验证：真实 Installer 管理员授权、真实 Dock 固定项、真实 Siri 收据、两个用户账户、Dock 未运行、偏好写入失败、卸载后重装默认不勾选，以及废纸篓恢复。

## 回归与风险

- 只删除与本次被卸载 App 路径匹配的 Dock 固定项；不重建 Dock，不处理其他用户。
- 旧卸载器已经留下的 Dock 固定项不会在“仅收据残留、没有 App 可移动”的早期退出路径中自动移除；可重新安装后卸载，或手动从 Dock 移除。新流程在移动 App 时清除固定项。
- `defaults` 导出/导入会在短时间内覆盖整个 `com.apple.dock` 域。实现保留导出时的其他键，但无法排除同一时刻的用户 Dock 变更；失败时明确报告。无法读取 Dock 偏好时记录 `preferences_unavailable` 并跳过。
- 收据清理只针对 `com.hd838a.RemoteMic.siri-remote`，不删除主安装收据 `com.hd838a.RemoteMic.installer`，避免破坏历史驱动名称兼容逻辑。
- 测试手册见 [Testing/MacInstallerUninstaller.md](../Testing/MacInstallerUninstaller.md)。
