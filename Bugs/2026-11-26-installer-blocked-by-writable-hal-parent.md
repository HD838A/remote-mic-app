# 安装器因 HAL 目录带组可写位阻止升级

## 状态

候选修复：`reconcile` 对「root 所有、真实目录、唯一异常是可写位」的可写 HAL 目录链执行 `chmod go-w` 后继续安装，并输出 `phase=repaired`；其余异常仍停止。隔离夹具与反向验证通过，真实 Installer 与 CoreAudio 现场验收未完成。

## 影响范围

- macOS 安装 PKG 的 `preinstall` 驱动安全门禁。
- 用户机器的 `/Library/Audio/Plug-Ins/HAL` 被第三方音频工具或手工操作改出组/其他可写位时，安装会在写入任何负载之前停止。
- Installer 只显示「安装器遇到了一个错误」，`preinstall` 的说明是「请把安装器日志发送给支持」，用户没有自助完成的路径。
- 停止时现有 App、驱动、名称记录和用户设置保持不变。

## 错误证据

2026-11-26 用户提供系统 Installer 日志（文件字节未入库）。关键事件顺序：

```text
SayAll  Installation Log
Opened from: /Users/ds/Downloads/SayAll-2.0.10-442-Intel-install.pkg
An existing compatible microphone was found and will be checked before any update.
An existing SayAll.app was found and will be updated atomically.
DRIVER_NAMING phase=blocked result=failed reason=unsafe_hal_parent scope=library detail=unsafe_hal_parent level=hal issue=group_writable
Installation stopped: the ownership, permissions or link state of the system audio driver directory is unsafe; nothing was changed. Send the installer log to support.
PackageKit: Install Failed: Error Domain=PKInstallErrorDomain Code=112 ... NSFilePath=./preinstall ...
```

同一日志中的环境事实：

- `Hardware: iMac19,1 @ 3.80 GHz (x 16), 32768 MB RAM`，`Running OS Build: macOS 13.5 (22G74)`。
- 包为 `SayAll-2.0.10-442-Intel-install.pkg`；Intel 架构分支的最低系统为 13.0，因此系统版本门禁通过，失败只发生在权限检查。
- 管理员授权成功、包信任等级 350，失败发生在 `preinstall` 写入 App/驱动之前。
- `level=hal` 表示触发目录是 `/Library/Audio/Plug-Ins/HAL` 本身，`issue=group_writable` 表示 owner 仍是 root，只是带了组可写位（例如 775）。

## 调查

`check_driver_naming_duplicates` 校验 HAL 目录链每一级必须 root 所有、不是符号链接、且 mode 不含 `022`。该约束用于防止在他人可写的目录里以 root 写入音频驱动。现场只命中写位，所有权和链接状态正常，属于可恢复的权限漂移；旧实现与其它不安全状态共用同一条停止分支，用户只能手工执行 `chmod`，这与「不要求用户跑命令」的产品边界冲突。

### 根因假设与置信度

- **H1（高置信）**：`/Library/Audio/Plug-Ins/HAL` 被第三方音频驱动安装器或装机脚本改成组可写。日志的 `issue=group_writable` 直接给出该状态。
- **H2（中置信）**：迁移或恢复工具复制了旧系统的目录权限。
- 现场未回收目录 mode，本文不把 775 以外的具体值当作事实。

## 修复

- 新增 `driver_naming_repair_writable_directory`，只在以下条件 **全部成立** 时执行 `chmod go-w`：
  - `reconcile` 模式（`check` 模式永不改动文件系统）；
  - `scope=library`（只读 System 作用域永不改动）；
  - 目录层级为 `hal`、`plugins` 或 `audio`（`/Library` 及以上不自动修）；
  - 目录是真实目录、不是符号链接；
  - owner 仍是 root；
  - 问题枚举是 `group_writable` 或 `other_writable`。
- 修复后重新执行既有的 `driver_naming_safe_directory` 复核；通过才继续，失败仍按原枚举停止。
- 新增日志 `DRIVER_NAMING phase=repaired result=ready scope=<scope> level=<level> issue=<issue> mode=<before> mode_fixed=<after>`，不包含路径、名称或第三方身份。
- 所有权变更、符号链接、缺失目录、只读 System 作用域、重复驱动与身份不可验证仍走原有停止分支，文案不变。

## 验证

- `scripts/test-driver-naming.sh` 新增两项夹具：
  - root 所有的 775 目录在 `reconcile` 下被修回 755、输出 `phase=repaired`、扫描继续；
  - 777 但非 root 所有的目录仍然停止，`issue=not_root`，目录 mode 保持 777。
- 反向验证：把自愈函数临时改为直接 `return 1`，测试退出码 1；恢复后全套通过。
- `scripts/verify-repository-governance.sh` 通过。
- 未覆盖：真实签名 PKG 在受影响机器上的 Installer 全流程、CoreAudio 重启后单实例枚举、其它层级权限异常的真机表现。

## 边界

- 不修复 `/Library` 及更上层目录的可写位，仍按原逻辑停止。
- 不修改所有权，不跟随或替换符号链接。
- 该修复只恢复目录可写位，不改变驱动身份、名称记录、安装路径或包 ID。
