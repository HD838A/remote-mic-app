# PKG 升级时 macOS Installer 将 SayAll 重定位到旧 Remote Mic 路径

- 时间：2026-08-22
- 状态：真实签名升级稳定复现，尚未修复
- 影响范围：已通过 `com.hd838a.RemoteMic.installer` 安装 1.8.x 的用户，经 PKG 升级到以 `SayAll.app` 为 canonical 路径的 1.9.x
- 功能点：PKG 安装、App 改名、旧 App 迁移、MiRemoteV 2ch

## 复现环境

- Mac：Apple Silicon，macOS 26；测试期间未重启 Mac。
- 旧版：公开 Release `v1.8.3`，`Remote Mic.app` 1.8.3 (64) 与 `Remote-Mic-1.8.3-Installer.pkg`。
- 候选：分支 `codex/fix-pkg-legacy-app-migration-order`、提交 `f5f1d047`，无线麦SayAll.app 1.9.7 (130)。
- 两个 PKG 及 App 均通过 Developer ID、Apple Notarization、staple 和 Gatekeeper 校验；候选安装 PKG SHA-256 为 `3fe7a71be1985e72ed3deb5899ecb3c9fbd15a8c5bc3ddf93e11f03f05777cd4`。

## 复现步骤

1. 从官方 1.8.3 DMG 安装 `/Applications/Remote Mic.app`，安装官方 1.8.3 PKG。
2. 启动 1.8.3，确认 `RemoteMic` 正在运行且 MiRemoteV 2ch 可用。
3. 不退出旧 App、不删除旧路径，使用管理员权限安装候选 `Install Remote Mic.pkg`。
4. 以约 100 ms 间隔记录 `RemoteMic`、`coreaudiod` PID 和驱动目录修改时间，同时保存 Installer 输出。

## 实际结果

- 安装前旧 `RemoteMic` PID 为 `93897`；监控在 2026-08-22 00:12:47Z 首次记录进程消失。
- 进程消失时 MiRemoteV 2ch 驱动目录修改时间仍为旧值，`coreaudiod` PID 仍为 `93892`，证明 `preinstall` 已先停止旧 App。
- Installer 随后报告“运行软件包脚本时出错”，安装失败。
- 失败现场不存在 `/Applications/SayAll.app`；`/Applications/Remote Mic.app` 的内容却已变成 1.9.7 (130)。
- MiRemoteV 2ch 目录未更新，`coreaudiod` 未在候选安装中重启；候选 staging driver 留在 `Library/Application Support/RemoteMic/Installer`。
- 失败后已把候选 App 和 staging driver 可恢复地移出工作路径，恢复并重新启动原有 1.9.3 (125)。Codex 进程保持运行，Mac 未重启。

测试记录保存在 `/tmp/sayall-upgrade-test-20260822/`：

- `install-1.8.3.log`
- `install-1.9.7.log`
- `process-driver-watch.log`
- `staged-driver-after-failure/`

## 根因证据

候选 PKG 的 payload 和 Distribution 都声明 `Applications/SayAll.app`，但生成的 `PackageInfo` 同时声明：

- 主 App Bundle ID 为 `com.hd838a.RemoteMic`；
- `<upgrade-bundle>` 包含 `com.hd838a.RemoteMic`；
- 组件包标识继续使用 `com.hd838a.RemoteMic.installer`。

系统中的 1.8.3 receipt 对同一个组件包标识记录的是 `Applications/Remote Mic.app`。真实安装证明 macOS Installer 根据旧 receipt 和相同 Bundle ID 执行 bundle relocation，把新 payload 更新到旧路径，而不是 payload 声明的 `SayAll.app` 路径。

`postinstall` 随后固定检查 `/Applications/SayAll.app`，第一个无法满足的 App 门禁是 `test -d "$APP_DESTINATION"`，因此在驱动处理、旧 App 废纸篓迁移和新 App 启动之前退出。文件落点、receipt、脚本顺序与进程/驱动监控相互一致，根因置信度高。

## 修复边界

正式修复需要保证旧 receipt 存在时，新 payload 仍确定安装到 `/Applications/SayAll.app`，同时保持 App 的 Bundle ID、Team ID 和 designated requirement 不变，以延续 TCC 权限。不能仅让 `postinstall` 接受旧路径，否则 canonical 路径迁移仍未完成。

根因修复前不得把“旧进程提前停止”当作完整升级通过。修复后必须重新执行官方 1.8.3 → 候选 PKG 的真实签名升级，确认：

1. 旧进程先停止；
2. 新 App 最终只位于 `/Applications/SayAll.app`；
3. 旧 App 可恢复地进入废纸篓；
4. PKG receipt 更新成功；
5. MiRemoteV 2ch、CoreAudio、Onboarding 音频与实体遥控器均通过。
