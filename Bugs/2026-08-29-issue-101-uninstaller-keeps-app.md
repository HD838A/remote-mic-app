# Issue #101：卸载 PKG 运行后 App 仍保留

- 时间：2026-08-29
- 状态：候选修复完成，等待正式签名 PKG 与双架构真实卸载验收
- 影响范围：macOS 公开 Release 中的 `Uninstall Remote Mic.pkg`
- 功能点：App/`MiRemoteV 2ch` 安装与卸载、失败回滚、DMG 单入口
- 简单描述：卸载包名称表达“卸载无线麦”，但实现只永久删除 `MiRemoteV 2ch`，`SayAll.app` 仍留在“应用程序”中。
- 原始记录：GitHub Issue #101（Alice，2026-08-20）。

## 复现

1. 检查当前 `packaging/doubao-driver/uninstall/postinstall`。
2. 运行 `rg 'SayAll\.app|Remote Mic\.app|无线麦\.app' packaging/doubao-driver/uninstall/postinstall`。
3. 旧实现无 App 路径，仅对驱动目标执行 `/bin/rm -rf`。

错误结果：PKG 报告成功后 App 仍可见，但兼容麦克风已被永久删除。

正常边界：名为 `Uninstall Remote Mic.pkg` 的资产应处理属于无线麦的 App 与兼容麦克风；未知同名内容、BlackHole 和本地设置不应被修改。

## 日志结论

问题发生在 App 启动之外的 Installer `postinstall` 脚本中，没有可对应的 App `runtime.log`。Issue 现象与 PKG 脚本的静态执行路径完全一致：脚本只定义驱动目标，成功信息也只声明卸载 `MiRemoteV 2ch`。

## 代码审计与根因

- `scripts/build-dmg.sh` 已只把 Install PKG 放在 DMG 根目录，普通安装单入口已实现。
- 安装 PKG 已在替换前检查架构、系统、Bundle ID 与构建号；新 `SayAll.app` 验证后才把旧 App 移入废纸篓。
- 安装 PKG 的驱动更新路径仍会在复制新驱动前永久删除旧驱动，与 TODO 中的“失败回滚”预期不一致。
- 根因是历史上该 PKG 是驱动专用卸载器，发布资产后来采用了完整产品名称，却没有同步扩展实现和用户指引。

## 修复

1. 卸载脚本检查 canonical `SayAll.app`、两个历史 App 路径和 `MiRemoteV2ch.driver` 的 Bundle ID。
2. 只把已确认归属无线麦的项目移入目标卷的 macOS 废纸篓，名称包含 UTC 时间和 PID 并自动避免碰撞。
3. 废纸篓不可用时不移动任何项目；中途失败时按逆序恢复本轮已移动项。
4. 成功后仅在当前启动卷的驱动被移动时重启 `coreaudiod`。BlackHole 和本地设置明确保留。
5. 安装器更新旧驱动时先原子改名为备份；新驱动复制、权限或签名验证失败时恢复旧驱动，成功时把旧驱动移到系统卷 root 废纸篓，不再永久删除。

## 验证

- `zsh -n packaging/doubao-driver/uninstall/postinstall`。
- 伪目标卷回放：覆盖 canonical App、历史 App、兼容驱动、未知同名 App 和中途失败回滚；另静态检查目标名碰撞避让循环。
- 构建不用于分发的无签名测试夹具 PKG/DMG，执行 `scripts/verify-doubao-driver-pkg.sh` 的 install/uninstall 结构校验和 `scripts/verify-dmg.sh` 的 DMG 单入口校验。
- `scripts/test-installer-architecture-guard.sh`。
- `git diff --check`。

## 真实验收边界

本轮不生成或分发 Developer ID 签名、Apple 公证、staple 的 PKG/DMG，也不使用管理员权限修改真实 `/Applications` 或 `/Library/Audio/Plug-Ins/HAL`。因此尚需在 Apple Silicon macOS 14+ 与 Intel Ventura 上分别验证：Installer.app 中/英文、管理员取消、真实用户废纸篓归属、App/driver 全部组合、回滚失败路径、Gatekeeper 与卸载后 CoreAudio 设备刷新。
