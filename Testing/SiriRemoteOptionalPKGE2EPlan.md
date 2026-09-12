# Siri Remote 可选 PKG E2E 测试计划

## 目标与范围

验证最终 macOS 安装资产中 `Siri Remote 支持` 是真正的按需组件：默认安装只部署无线麦SayAll.app与 `MiRemoteV 2ch`，用户主动选择后才部署系统级 Apple Remote HCI Helper；已有 Helper 的升级、取消、无管理员权限和卸载路径不得留下错误或半安装状态。

本计划只覆盖安装器生命周期，不把 Siri Remote 的实体按键、触摸、语音首字延迟或尾字完整性计入 PKG E2E。硬件功能仍按 `Testing/AppleRemoteHardwareInterface.md` 单独验收。

## 固定候选

- 源码：`origin/main` `18b42243710ac80f27ec2d16c41741e8ba0d99e5`
- App：无线麦SayAll.app `1.9.21 (174)`
- Install PKG SHA-256：`48be363c8994bc38f8e72511cde987e2450ee6885dfe89893c3418de6c352c79`
- Uninstall PKG SHA-256：`5c57f0b4cf52bcd18b113c4d1e7a31c6ed9eda15e4c1575d414a875b89b5e287`
- DMG SHA-256：`4205373802ad2e5955769f3ff0ffa0487363e4fd9b5dca2ec94eb37989e0a095`
- 预期签名 Team ID：`L3QHLDRPAY`

## 测试环境矩阵

| 环境 | 本轮要求 | 说明 |
| --- | --- | --- |
| Apple Silicon，macOS 26.5.2 | 必测 | M2 Pro 实机，中文系统 Installer |
| Intel，macOS Ventura 13 | 待补 | 必须使用独立 Intel 最终候选包，不以 Rosetta 替代 |
| 全新系统、无历史 receipt | 待补 | 本轮可移除 payload，但保留历史 Installer receipt |

## 测试顺序

1. 验证 PKG、DMG、App、驱动和 Helper 的 Developer ID、公证、staple、Gatekeeper 与 SHA-256。
2. 挂载 DMG，确认根目录只有一个 Install PKG，且内嵌 PKG 与独立 PKG 字节一致。
3. 在 Installer.app 打开 Install PKG，确认 `Siri Remote 支持` 默认未勾选；实际切换复选框并确认选择状态变化。
4. 在已有 Siri Remote Helper 的状态下保持未选择并覆盖安装；比较 Helper、LaunchDaemon、驱动的 SHA、mtime、权限和 launchd 状态。
5. 运行正式 Uninstall PKG；确认 App、驱动、Helper、LaunchDaemon 和状态目录离开原路径，服务停止。
6. 在无 payload 状态保持未选择安装；确认 App 和驱动恢复、App 启动、CoreAudio 可枚举驱动，同时系统级 Siri Remote 文件仍不存在。
7. 主动选择 Siri Remote 安装；确认独立 receipt、Helper/LaunchDaemon、权限、签名、Mach service 和 launchd 启动能力。
8. 以非管理员身份提交安装；预期系统拒绝，且 App、驱动和 Helper 字节不变。
9. 在安装提交前关闭 Installer.app；预期没有安装状态变化。
10. 恢复最终可用状态：App、驱动和 Siri Remote Helper 均安装，App 与 Helper 可运行。

## 证据与失败判定

每条路径记录开始/结束 UTC、退出码、选择状态、安装前后 SHA、权限、receipt、`launchctl print`、CoreAudio 枚举和 `/var/log/install.log` 对应时间。日志不得记录密码、用户内容、设备唯一标识或其他 App 私有状态。

以下任一情况判定失败：默认选择 Siri Remote；未选择仍新装 Helper；未选择的升级删除或重置已有 Helper；选择后缺少 Helper/LaunchDaemon/receipt；非管理员失败改变任何已安装字节；卸载后服务或原路径残留；最终资产签名、公证、staple 或 Gatekeeper 任一失败。

## 完成门槛

Apple Silicon 核心安装器路径全部通过后，只能称为“Apple Silicon PKG E2E 有条件通过”。Intel Ventura、真正无历史 receipt 的全新机、Installer.app 安全授权对话框、Finder 废纸篓恢复和 Siri Remote 真机功能验收全部完成后，才能称为完整发行矩阵通过。
