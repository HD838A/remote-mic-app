# 快捷指令内测包安装失败并删除现有 App

## 复现条件

- 当前 Mac：Apple Silicon，macOS 26.5.2。
- `/Applications/Remote Mic.app` 已安装 `1.8.13 (105)`。
- 从私有 Draft Release 下载并打开快捷指令内测包 `1.8.5 (67)`。
- 在图形化 Installer 中执行标准安装。

## 错误行为与正常边界

错误行为：Installer 最终显示“安装失败”，并且原有 `/Applications/Remote Mic.app` 被删除。

正常行为：新版测试包应原子覆盖旧版；旧包或安装失败时必须停止安装并完整保留现有 App。

## 日志证据

`/var/log/install.log` 在 2026-08-14 00:31:15 至 00:31:19 记录：

- PackageKit 因磁盘上 `1.8.13 (105)` 高于包内 `1.8.5 (67)`，跳过 `com.hd838a.RemoteMic` payload。
- `preinstall` 随后输出已删除原有 `Remote Mic.app`。
- `postinstall` 因 `/Applications/Remote Mic.app` 不存在而返回失败。
- 最终错误为 `PKInstallErrorDomain Code=112`，失败脚本是 `./postinstall`。

这证明失败与 GUI、DMG 摘要或未签名提示无关，直接根因是安装脚本与 PackageKit 版本处理冲突。

## 根因

1. 内测包错误复用了已经落后于当前公开版本的 `1.8.5 (67)`。
2. `preinstall` 在 PackageKit 提交 payload 前直接删除现有 App。
3. PackageKit 对较旧 payload 执行版本保护并跳过安装，脚本却不知道 payload 已被跳过。
4. 旧验证脚本和单元测试反而要求 `preinstall` 包含删除命令，错误地把危险行为当成发布门禁。
5. 发布前只校验了包结构、签名结构和摘要，没有在当前 Mac 上执行真实覆盖安装。

## 修复

- `preinstall` 不再删除现有 `Remote Mic.app`，由 PackageKit 使用 `upgrade` 原子替换。
- 打包时把本次 App Build 写入 `release-variant.plist`。
- `preinstall` 在任何 App 修改前比较已安装 Build 与包内 Build；检测到旧包时明确停止并保留现有 App。
- 最终 PKG 验证增加包内版本、Build 和 `PackageBuild` 一致性检查，并禁止恢复删除现有 App 的逻辑。
- 本次测试包版本调整为高于已存在候选和本机安装版本的 `1.8.17 (109)`。

## 验证

自动化与静态验证：

```bash
swift test --filter BuildSigningTests
./scripts/verify-doubao-driver-pkg.sh "dist/Install Remote Mic.pkg" install
./scripts/verify-dmg.sh "dist/Remote-Mic-1.8.17.dmg"
git diff --check
```

当前 Mac 真实安装必须覆盖以下两条：

1. 从已恢复的正式签名版 `1.8.14 (106)` 安装 `1.8.17 (109)`，确认 Installer 成功、App 存在且能启动。
2. 使用低于当前 App Build 的夹具包运行安装，确认安装被拒绝且原 App 的版本、签名和 SHA-256 均保持不变。

## 验证边界

- Swift 测试、包结构、签名和 DMG 校验不能替代真实 Installer。
- 当前 Mac 已完成 `1.8.14 (106) → 1.8.17 (109)` 图形化 Installer 覆盖安装。`/var/log/install.log` 记录 `Installed "Install Remote Mic"` 和 `Displaying 'Install Succeeded' UI`，安装后 App 已启动。
- 当前 Mac 已完成低 Build 108 夹具的真实失败保护：日志明确记录 Build 109 高于 Build 108；安装前后 App 版本、PID 和文件树 SHA-256 `cff83f556327f49136bc06fafc271f1e7befb529a51ff22fd2d7fc4baa7edad1` 一致。
- 42 项项目自检、222 项完整测试、仓库边界检查、最终 App/DMG/PKG 校验和 `git diff --check` 已通过。
- Intel 产物已完成构建和结构验证，但本次不宣称完成 Intel Mac 真实安装。
