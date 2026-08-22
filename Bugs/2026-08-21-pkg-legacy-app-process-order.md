# App 改名后 PKG 升级时旧进程未及时停止

- 时间：2026-08-21
- 状态：正式签名 PKG 已验证旧进程提前停止；完整升级被 Installer 旧路径重定位问题阻断
- 影响范围：从 1.8.x `Remote Mic.app` / `无线麦.app` 通过 PKG 升级到 1.9.x `SayAll.app`
- 功能点：PKG 安装、旧 App 路径迁移、MiRemoteV 2ch、Onboarding 音频与 HID 初始化
- 简单描述：用户通过 PKG 安装 1.9.x 后，Onboarding 卡在音频页；手动删除 1.8.x 旧 App 后重新安装恢复正常。

## 复现

用户现场满足以下条件：

1. 已安装并正常使用 1.8.x，旧 App 位于 `/Applications/Remote Mic.app` 或历史中文路径。
2. 通过 1.9.x 安装 PKG 安装新版本，canonical 路径为 `/Applications/SayAll.app`。
3. 新版本 Onboarding 显示 `audio.no_output_device`，同时出现 `button_mapping.error.power_suppression_failed`。
4. 手动删除旧 1.8.x App 后再次安装，问题消失。

原始现场只提供了诊断截图，没有 `/var/log/install.log` 或安装时段的完整 `runtime.log`。2026-08-22 已使用官方 1.8.3 和真实 Developer ID 签名、公证、staple 的 1.9.7 (130) PKG 在 Apple Silicon Mac 执行升级；真实安装记录见下文。

## 观察与根因

截图中的权限、控制连接和按键观察均为正常；失败集中在音频输出不存在/未选择以及 HID 电源键保护失败。代码检查确认品牌改名把安装目标从 `Remote Mic.app` 改为 `SayAll.app`，旧 App 不再被 PKG 覆盖，而由 `postinstall` 在新 App 验证后迁移。

原有顺序是：

1. 更新 MiRemoteV 2ch；
2. 必要时重启 `coreaudiod`；
3. 才停止 `RemoteMic` 进程并把旧 App 移入废纸篓；
4. 启动 `SayAll.app`。

因此正在运行的 1.8.x 进程可能在驱动更新和 CoreAudio 重启期间继续占用或重新初始化音频/HID 资源，新版本随即启动时就会看到 `audio.no_output_device` 和 `power_suppression_failed`。手动删除旧 App 会阻止旧实例继续运行，与现场恢复结果一致。

这不是 Bundle ID 改变：`com.hd838a.RemoteMic`、可执行文件 `RemoteMic` 和产品 Bundle ID 均保持兼容。问题是改名后旧路径分离，以及旧进程停止被延后。

## 修复

- `preinstall` 在确认 canonical 或历史路径中的 App 属于无线麦且没有版本降级风险后，设置已拥有 App 标记。
- 在任何驱动替换或 `coreaudiod` 重启前，先执行 `pkill -x RemoteMic`，避免旧版/当前版进程继续持有底层资源。
- `postinstall` 仍在新 `SayAll.app` 通过校验后才把旧 App 移入废纸篓；不匹配的同名应用仍保留，迁移失败也不删除旧 App。

## 自动化验证

- `BuildSigningTests` 增加安装时序静态门禁，要求 preinstall 具备 owned-app 标记、`pkill -x RemoteMic` 和“更新音频驱动前停止进程”的提示。
- 原有旧 App 废纸篓迁移测试继续覆盖可恢复移动、冲突命名、非产品 Bundle ID 和 Trash 不可用边界。
- 2026-08-22 真实 PKG 监控确认：运行中的 1.8.3 `RemoteMic` 进程在驱动目录修改和 `coreaudiod` 重启之前退出，证明本次 `preinstall` 停止时序生效。
- 同一次安装随后因 macOS Installer 把新 App 重定位到旧 `/Applications/Remote Mic.app` 而失败；`postinstall` 要求 `/Applications/SayAll.app` 存在，因此完整迁移、CoreAudio 重启、MiRemoteV 2ch 重新枚举和实体遥控器验收没有执行。独立根因记录见 [`2026-08-22-pkg-bundle-relocation-keeps-legacy-path.md`](./2026-08-22-pkg-bundle-relocation-keeps-legacy-path.md)。

## 验证边界

真实签名 PKG 已证明旧进程停止时序正确，但完整升级仍失败，不能表述为用户现场问题已解决。修复 Installer 路径重定位后，必须从官方 1.8.3 重新执行相同测试，并继续覆盖 CoreAudio、MiRemoteV 2ch、Onboarding 和实体遥控器。
