# Apple Remote HCI 恢复在只读系统根卷失败

## 复现

- 环境：macOS 26.5.2、Apple Silicon；安装前不存在 `/Library/Preferences/com.apple.MobileBluetooth.debug.plist`。
- 操作：旧候选 helper 开启 HCI trace，随后用新候选 PKG 升级；`preinstall` 和 `postinstall` 均要求 helper 执行 `--restore`。
- 错误行为：系统 Installer 报脚本失败，安装日志出现 `APPLE_REMOTE_HCI_SERVICE restore_command result=failed`，HCI trace plist 仍存在。
- 正常行为：恢复应移除仅由 SayAll 创建的 HCI trace plist，并重载 `bluetoothd`，不留下配置。

## 日志与现场证据

- 同次安装中，驱动 staging 清理明确报告 `mkdir: /.Trashes: Read-only file system`。
- HCI helper 的“原 plist 不存在”恢复分支同样使用 `/.Trashes/0`，因此无法把临时 plist 移入废纸篓。
- 安装器因恢复命令非零退出而停止，没有继续 bootstrap 新服务。

## 根因

macOS 当前系统根卷不允许创建 `/.Trashes`。root 用户可写、可恢复的废纸篓位置是 `/var/root/.Trash`。旧实现虽然避免了永久删除，但选择了不可写的目标。

## 修复

- HCI helper 将只由 SayAll 创建且恢复后为空的蓝牙 debug plist 移入 `/var/root/.Trash`，继续使用时间戳和碰撞规避名称。
- PKG 安装脚本的旧驱动备份与 staging 目录也统一移入 `/var/root/.Trash`。
- PKG 静态验证器同步禁止回退到 `/.Trashes/0`。

## 验证边界

- 用修复后的 helper 对当前失败现场执行 `--restore`，确认 HCI plist 不存在、Authorization right 与安装前一致。
- 重新安装 PKG，确认 staging 清理、旧 helper 恢复和 LaunchDaemon bootstrap 均成功。
- App/服务崩溃、系统重启和完整卸载的恢复仍需按 Apple Remote 测试手册分别验证。
