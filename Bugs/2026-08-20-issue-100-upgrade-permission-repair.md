# Issue #100：升级后权限失效且旧 App 影响安装

- 时间：2026-08-20
- 状态：权限修复入口已实现；旧 App 迁移时序已修复，等待正式签名 PKG 验收
- 影响范围：从正式版 `1.8.3` 升级到 `1.9.3` 或后续版本的已有用户
- 功能点：完成更新后的权限恢复、Onboarding 自助排障、旧 App 路径迁移
- 来源：[GitHub Issue #100](https://github.com/HD838A/remote-mic-app/issues/100)
- 简单描述：用户反馈升级后旧权限不再生效；如果权限无法延续，应明确显示缺失并引导重新授权。用户同时反馈旧 `Remote Mic.app` 未删除时安装失败。

## 复现与证据

Issue 没有附运行日志、Installer 日志、截图或评论，因此无法复现用户机器上的具体 TCC 与安装失败时序。代码复现确认了一个确定缺口：

1. 已完成 Onboarding 的用户完成版本更新。
2. 当前进程实时检查到蓝牙、输入监控或辅助功能至少一项缺失。
3. 旧实现仍按默认行为打开“连接”页，只在用户自行找到“权限与隐私”后才显示缺失状态和补授权入口。

定向测试 `completedUpdateOpensPermissionRepairOnlyWhenARequiredPermissionIsMissing` 在旧实现无法编译，因为没有升级权限修复策略，也没有把更新完成窗口定向到权限页。

## 日志检查

Issue #100 没有提供 `~/Library/Logs/RemoteMic/runtime.log` 或 `/var/log/install.log`，因此不能把签名变化、旧 App 占用、驱动替换、架构不符或其他 Installer 阶段写成已确认根因。

候选修复新增脱敏日志：

```text
UPDATE PERMISSION_REPAIR bluetooth=<bool> input=<bool> accessibility=<bool>
```

它只记录三项实时布尔状态，不记录用户名、路径、设备、文字或权限数据库内容。

## 签名与安装包审计

从 GitHub Release 下载并逐项检查了公开正式资产：

- `v1.8.3` `Remote-Mic-1.8.3.zip` 中的 `Remote Mic.app`；
- `v1.9.3` `Remote-Mic-1.9.3.dmg` 中签名、公证 PKG 的 `SayAll.app`。

两者均为：

- Bundle ID：`com.hd838a.RemoteMic`；
- 可执行文件：`RemoteMic`；
- Team ID：`L3QHLDRPAY`；
- 相同 Developer ID designated requirement。

因此正式包只是文件名和显示名变化时，macOS 原则上应延续权限；App 无权直接修改或迁移 TCC 数据库。若系统返回权限缺失，产品能做的正确降级是显示真实缺失状态并引导用户重新授权。

公开 `1.9.3` DMG 的安装 PKG 已包含并实际签入以下逻辑：

1. 安装前识别 `/Applications/Remote Mic.app` 和 `/Applications/无线麦.app`，核对 Bundle ID 与 Build。
2. 先安装并验证新的 `/Applications/SayAll.app`。
3. 新 App 验证成功后，才把属于本产品的旧路径 App 移到当前用户废纸篓；迁移失败时保留旧 App。

此前公开包已经覆盖 Issue 所说的“备份后删除旧 App”，且不会在新 App 安装成功前删除；但旧进程停止被安排在驱动更新和 `coreaudiod` 重启之后。该时序缺口已单独记录并在 [`2026-08-21-pkg-legacy-app-process-order.md`](./2026-08-21-pkg-legacy-app-process-order.md) 修复。

## 根因

已确认根因是升级恢复入口缺失，而不是已证明的签名身份变化：完成更新后，启动逻辑只负责显示设置窗口和恢复 HID，没有根据实时权限状态决定初始页面。用户看到的第一个页面与故障无关，容易误以为 App 仍把失效权限当作可用。

安装失败的根因现已高置信度确认：App 改名后旧 `Remote Mic.app` 不再被覆盖，旧 `RemoteMic` 进程在 MiRemoteV 2ch 更新和 `coreaudiod` 重启时仍可能持有音频/HID 资源，导致新 App 首次启动看到音频设备不可用和电源键保护失败。现场仍缺少 `/var/log/install.log`，所以真实 Installer 输出顺序待正式包验收补齐。

## 修复

1. 新增纯策略：只有已完成 Onboarding、刚完成版本更新且蓝牙/输入监控/辅助功能任一实时缺失时，触发权限修复。
2. 更新首次启动仍进入现有设置窗口，但初始页面改为“权限与隐私”，不把老用户送回完整 Onboarding。
3. 权限全部正常时保持原更新完成行为；普通启动、手动打开设置和新用户流程不变。
4. 页面继续使用现有实时检测、补授权操作和更新权限身份说明；不会修改 TCC，也不会把打开设置页当作授权成功。
5. PKG 安装器在驱动更新前停止已识别的 SayAll/Remote Mic 进程；新 App 校验完成后再将旧路径 App 安全移入废纸篓。

## 验证

- 旧实现：定向测试因缺少 `CompletedUpdatePermissionRepairPolicy` 和页面接线而失败。
- 候选实现：`swift test --filter completedUpdateOpensPermissionRepairOnlyWhenARequiredPermissionIsMissing` 通过。
- `swift test --filter OnboardingFlowTests`：28 项通过。
- `swift test`：314 项、31 个 suite 通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：42/42 通过。
- `BuildSigningTests` 增加 PKG 安装前停止进程的静态时序门禁。
- 生产设置页浅色、深色 `800 × 650` 权限页面已检查：权限状态、补授权按钮、升级身份说明与诊断入口完整显示，无裁切或窗口几何变化。

## 验证边界

自动化能证明升级与权限状态组合只在正确条件下定向到权限页，以及安装脚本在驱动更新前停止进程，不能替代真实 macOS TCC、正式签名升级或 Installer.app。下一份正式签名候选仍需从 `1.8.3` 执行 Sparkle 与 PKG 两条升级路线，并保存 `/var/log/install.log` 与 `runtime.log` 核对真实顺序。
