# Siri Remote 可选 PKG E2E 测试报告（2026-09-06）

## 结论

Apple Silicon 安装器核心路径有条件通过。最终 PKG 确认 `Siri Remote 支持` 默认关闭；默认安装不会创建系统级 Helper；主动选择后会安装正确签名、正确权限的 Helper 与 LaunchDaemon；已有 Helper 的覆盖升级不会删除、覆盖或重启它；卸载、无管理员权限和安装前退出均没有出现半安装。

本报告不能表述为完整发行矩阵通过：本轮没有 Intel Ventura 实机、真正无历史 receipt 的全新系统，也没有自动操作 macOS 安全授权对话框或在 Finder 中执行“放回原处”。Siri Remote 的实体按键、触摸和语音不属于本次安装器 E2E。

## 候选与环境

- 源码：`origin/main` `18b42243710ac80f27ec2d16c41741e8ba0d99e5`
- 系统：macOS 26.5.2 (25F84)，Apple Silicon M2 Pro，中文 Installer
- App：无线麦SayAll.app `1.9.21 (174)`
- Install PKG：`48be363c8994bc38f8e72511cde987e2450ee6885dfe89893c3418de6c352c79`
- Uninstall PKG：`5c57f0b4cf52bcd18b113c4d1e7a31c6ed9eda15e4c1575d414a875b89b5e287`
- DMG：`4205373802ad2e5955769f3ff0ffa0487363e4fd9b5dca2ec94eb37989e0a095`
- 测试窗口：2026-09-06 06:18–06:33 UTC

## 结果矩阵

| 用例 | 结果 | 证据摘要 |
| --- | --- | --- |
| 信任链与资产一致性 | 通过 | Install/Uninstall PKG 均为 Developer ID Installer、Apple notary trusted、staple 有效、`spctl -t install` accepted；DMG staple 与 Gatekeeper accepted；Team ID 为 `L3QHLDRPAY`。 |
| DMG 单入口 | 通过 | DMG 根目录只有 `Install Remote Mic.pkg`；内嵌文件与独立 PKG SHA-256 完全一致。 |
| Installer.app 默认选择 | 通过 | 自定安装页显示 `Siri Remote 支持 / Siri Remote support`，初始 `Value: 0`、操作为“跳过”。 |
| Installer.app 主动勾选 | 通过 | 实际点击后变为 `Value: 1`、操作为“升级”，要求空间从 19.3 MB 增至 19.5 MB。 |
| 已有 Helper，升级不选择 | 通过 | App receipt 从 1.9.19 更新到 1.9.21；Helper 和 LaunchDaemon SHA、mtime、权限保持不变，Helper PID 53120 保持运行；既有驱动 SHA 和安装时间保持不变。 |
| 完整卸载原路径 | 通过 | Uninstall PKG 返回 0；App、驱动、Helper、LaunchDaemon 和 HCI 状态目录均离开原路径；system launchd label 不再存在。 |
| 卸载后可恢复性 | 部分通过 | 已审计最终卸载脚本只使用碰撞安全的 `mv` 写入当前用户废纸篓并支持逆序回滚；macOS 隐私保护阻止当前代理枚举 `~/.Trash`，未在 Finder 执行“放回原处”。 |
| 无 payload，默认不选择 | 通过 | App 1.9.21 (174) 与 MiRemoteV 2ch 安装成功；App 自动启动；CoreAudio 枚举到 2 入/2 出、48 kHz 的 `MiRemoteV 2ch`；Helper、LaunchDaemon 和 HCI 状态目录均不存在。历史 receipt 仍存在，因此不等同全新系统。 |
| 主动选择 Siri Remote | 通过 | 新增 `com.hd838a.RemoteMic.siri-remote` receipt；Helper 为 root:wheel、0755，LaunchDaemon 为 root:wheel、0644；Identifier 和 Team ID 正确；Mach service 名正确。 |
| Helper 启动能力 | 通过 | 安装后 launchd 已注册为按需服务；`launchctl kickstart` 返回 0，服务进入 running，生成 PID 17380 和活动 Mach endpoint。App 当次启动未主动申请租约，因此没有把“App 自动拉起 Helper”记为通过。 |
| 无管理员权限 | 通过 | 非 root `installer` 返回 1，并明确提示必须以 root 运行；App、驱动、Helper SHA 全部未变化。 |
| 安装前退出 | 通过 | Installer.app 在提交安装前关闭；对应前后系统文件和 receipt 没有变化。 |
| 最终恢复状态 | 通过 | 测试结束时 App、MiRemoteV 2ch、Helper 和 LaunchDaemon 均已安装；App 可运行，Helper 可由 launchd 启动。 |

## 关键观察

1. 可选组件逻辑有效。GUI 默认值、choice changes、实际落盘结果三层一致，不是仅修改了安装器文案。
2. 未选择的升级保持已有 Siri Remote 服务原样，满足老用户升级不被破坏的要求。
3. 删除 payload 后重新默认安装没有偷偷补装 Siri Remote，说明系统 receipt 的存在不会使可选组件被隐式恢复。
4. Siri Remote LaunchDaemon 是按需服务；刚安装时 `state = not running`、`runs = 0` 是正常等待客户端，不应误判为失败。
5. GUI 安全授权窗口属于 macOS secure UI，自动化接口不可读取。本轮真实写系统步骤由相同 Installer 引擎配合管理员授权执行，GUI 选择页和提交后的安装成功摘要均已观察，但不能声称自动点击过安全授权对话框。

## 自动化回归

- `swift test`：492 tests / 43 suites，通过。
- `scripts/test-installer-architecture-guard.sh`：通过。
- `scripts/verify-doubao-driver-pkg.sh`：Install PKG 的 `install` 模式和 Uninstall PKG 的 `uninstall` 模式均通过，启用 Developer ID 与公证强制检查。
- `scripts/verify-dmg.sh`：DMG 校验和、单入口、内嵌 Install PKG、Developer ID、公证、staple 和 Gatekeeper 全部通过。
- 编译只出现仓库既有的 macOS API 弃用警告，没有测试失败或新增构建错误。

## 未完成项与发布边界

- Intel Ventura 使用最终 Intel Developer ID 包完成同一矩阵。
- 在没有历史 receipts 的新用户系统验证首次安装。
- 人工通过 Installer.app 安全授权对话框完成一次“不选择”和一次“选择”安装。
- 在 Finder 验证卸载项进入废纸篓、名称碰撞和“放回原处”。
- 用真实 A2854 验证安装后的 App 自动申请 HCI 租约、按键、触摸和完整语音链路。

因此当前结论是：Apple Silicon 的 Siri Remote 可选 PKG 可以进入用户测试，但完整跨架构发行门禁仍未关闭。
