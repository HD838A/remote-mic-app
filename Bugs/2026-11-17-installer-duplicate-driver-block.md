# 安装器因重复的兼容麦克风驱动阻止升级

## 状态

候选修复：安装前扫描改为分原因枚举并自动归置可写 HAL 中的本产品重复副本；日志已补齐到可远程定位。现场机器的具体触发分支尚未取得安装后日志，真实 Installer 与 CoreAudio 验收未完成。

## 影响范围

- macOS 安装 PKG 的 `preinstall`/`postinstall` 驱动安全门禁。
- 用户已安装本产品兼容麦克风后升级新版时，若 HAL 目录出现额外的同 Bundle ID 副本、符号链接或权限异常，安装会在写入负载前停止。
- 停止时现有 App、驱动、名称记录和用户设置保持不变，但 Installer 只显示通用失败提示。

## 错误证据

2026-11-17 用户提供系统 Installer 日志（文件字节未入库）。关键事件顺序：

```text
An existing compatible microphone was found and will be checked before any update.
DRIVER_NAMING phase=blocked result=failed reason=duplicate_driver
Installation stopped: the microphone name could not be determined safely. Existing drivers and settings were kept. Contact support.
PackageKit: Install Failed: Error Domain=PKInstallErrorDomain Code=112 ... NSFilePath=./preinstall ...
```

同一日志中的环境事实：

- 包为 `SayAll-2.0.8-404-AppleSilicon-install.pkg`，与仓库 `v2.0.8` 标签的安装脚本逐字一致。
- 系统 macOS 15.6.1，Apple Silicon；架构与最低系统门禁均已通过。
- 管理员授权成功、包信任等级正常，失败发生在 `preinstall` 写入任何 App/驱动之前。
- 既有驱动存在且 `CFBundleIdentifier` 为 `com.hd838a.MiRemoteV2ch`；`phase=observed` 未打印，说明阻断发生在名称观测之前。

## 调查

`check_driver_naming_duplicates`（`packaging/doubao-driver/install/driver-naming.zsh`）在旧实现中用同一个 `reason=duplicate_driver` 覆盖三类互不相同的状态：

1. `/Library/Audio/Plug-Ins/HAL` 或 `/System/Library/Audio/Plug-Ins/HAL` 中除规范路径外还有 `*.driver` 声明同一 Bundle ID。
2. HAL 路径链任意一级是符号链接。
3. HAL 路径链任意一级非 root 所有，或 group/other 可写。

旧日志不记录 scope、目录层级、原因、条目数，也没有区分文案；因此仅凭现场日志无法判断是三类中的哪一类，只能让用户手工执行终端命令检查。这是本次确认的诊断缺口。

### 根因假设与置信度

- **H1（最可能）**：可写 HAL 中存在本产品的另一份副本（改名副本、符号链接或迁移恢复残留）。同 Bundle ID 的副本会让 Core Audio 注册两个同名设备；安装器按设计停止，但旧实现既不区分原因，也不能自行恢复。
- **H2**：HAL 目录链权限被第三方音频工具或手工操作改成 group/other 可写。
- **H3**：HAL 目录链被替换成符号链接。
- 高置信：阻断点为上述函数，且未发生任何写入。
- 中置信：实际命中 H1。现场未回收 HAL 清单，不能用日志字段直接证明。

## 修复

- 扫描拆成两步：先校验两个 HAL 目录链，再按 Bundle ID 枚举；两类结果分别使用固定枚举输出。
- 新增 `phase=hal_scan scope=<library|system> drivers=<n> ours_external=<n> symlinked=<n> unreadable=<n>`，每次安装输出两行。
- 阻断行补充 `detail`、`scope`，父目录问题补充 `level` 与 `issue`，条目问题补充 `count`；仍不记录路径、名称或第三方 Bundle ID。
- 可写 HAL 中经 `driver_naming_identity` 验证、非符号链接的本产品多余副本，移入目标卷 root 废纸篓的可恢复位置后继续安装；移动或标记写入失败时按相反顺序恢复已移动副本。
- `preinstall` 写 `duplicates-reconciled` 标记；`postinstall` 读取后强制 `DRIVER_CHANGED=1`，确保即使规范驱动健康且同版本也会重启 Core Audio。
- 只读 System HAL 中的副本、符号链接、身份不可验证、目录权限异常和废纸篓不可用仍停止安装，不自动删除。
- 用户可见文案按原因区分；不再把重复驱动或权限问题描述成“无法确定麦克风名称”。

## 验证

```sh
scripts/build-doubao-driver.sh
scripts/test-driver-naming.sh
```

2026-11-17 本机 Apple Silicon：

- `scripts/test-driver-naming.sh` 全部通过，共 43 个隔离场景（安装、恢复、卸载重装与直接安装）。
- 新增断言覆盖：可写 HAL 副本移入 root 废纸篓并写入标记；标记写入失败时按相反顺序恢复已移动副本；postinstall 对有效、缺失、符号链接和内容不符标记的消费结果；符号链接副本不跟随、不删除；只读 System HAL 副本停止且不写标记；目录权限异常停止并输出 `reason`/`level`/`issue`；阻断文案包含 `detail`、`scope`、`count`。
- 旧夹具中的健康驱动保留、名称记录恢复、卸载重装、设置字节保留和签名校验均保持通过。

## 验证边界

- 未在真实用户机器上运行新安装包；未使用系统 Installer UI、管理员授权和真实废纸篓。
- 未验证 CoreAudio 在重启后是否只枚举一个设备，也未验证第三方语音工具。
- Intel 架构夹具未在本机执行。
- 若现场仍失败，新的 `hal_scan` 与 `blocked` 行应能直接给出 `scope`/`level`/`issue`/`detail`，无需用户执行命令。
