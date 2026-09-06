# macOS 安装与卸载行为测试手册

## 适用范围

- 基线：`origin/main` `18b42243710ac80f27ec2d16c41741e8ba0d99e5`
- 目标：macOS Apple Silicon 14+ 和 Intel Ventura 13
- 安装资产：最终 Developer ID 签名、Apple 公证并 staple 的 DMG、Install PKG 和 standalone Uninstall PKG
- Siri Remote 系统服务是 Install PKG 中的可选组件，默认不选择；MiRemoteV 2ch 与无线麦SayAll.app仍是默认组件。

## 测试前准备

1. 备份需要保留的无线麦本地设置；记录当前 App/driver 路径、版本、Build 和 Bundle ID。
2. 准备全新机、仅 App、仅驱动、canonical App+驱动、历史 App+驱动和已安装更新版 App 六种状态。
3. 准备一个 Bundle ID 不同的伪 `SayAll.app`，仅用于验证未知同名内容保护。
4. 确保测试前废纸篓中的同名项目有记录，不要清空用户废纸篓。

## 安装用例

### 1. DMG 单入口与全新安装

1. 挂载对应架构 DMG。
2. 确认根目录只有 Install PKG，没有并列 App、Applications 快捷方式或 Uninstall PKG。
3. 运行 Install PKG；进入“安装类型/自定安装”页面后，确认 `Siri Remote 支持` 默认未勾选。
4. 不勾选 Siri Remote，继续安装并完成管理员授权。

预期：`/Applications/SayAll.app` 与 `MiRemoteV 2ch` 安装完成，App 自动启动；`/Library/PrivilegedHelperTools/com.hd838a.SayAll.AppleRemoteHCIService` 和对应 LaunchDaemon 不被新安装创建；签名、公证、Gatekeeper、架构、最低系统与权限全部正确。

失败判定：DMG 出现多个普通安装入口，或 App/driver 只安装其一，或未勾选时仍新建 Siri Remote 系统服务。

### 2. 按需安装 Siri Remote 支持

1. 重新运行同一 Install PKG，进入“自定安装”。
2. 勾选 `Siri Remote 支持 / Siri Remote support`，继续安装并完成管理员授权。

预期：除默认组件外，安装器才写入 Apple Remote HCI helper 与 LaunchDaemon；helper 签名标识、Mach 服务名、权限和 `launchctl` 状态正确，App 可以进入 Apple Remote 音频准备流程。

失败判定：未勾选也安装 helper，勾选后 helper 或 LaunchDaemon 缺失，或安装器覆盖无法确认归属的同名服务。

### 3. 升级、旧路径与取消/失败

1. 分别从 canonical App、`Remote Mic.app`、`无线麦.app`、仅驱动状态安装。
2. 对“从未安装 Siri Remote”和“已经安装 Siri Remote”两种状态，分别运行新 PKG；观察默认选择保持未勾选。
3. 分别在管理员授权前取消，以及用测试夹具触发驱动复制失败。
4. 尝试用较旧 Build 覆盖较新 App。

预期：新 App 验证成功前不处理旧 App；成功后旧 App 进入废纸篓且可恢复。未勾选 Siri Remote 时，不会偷偷补装该组件；已经安装过的 Siri Remote 服务保持兼容，不因普通升级被删除或重置。取消或失败不留下半更新状态；较新 App 保留。

失败判定：失败后 App 或驱动消失，旧 App 被永久删除，或较新 Build 被降级。

## 卸载用例

### 4. 完整卸载与可恢复性

1. 退出 App，运行 standalone Uninstall PKG。
2. 分别验证 canonical App+驱动、历史 App+驱动、仅 App 和仅驱动。
3. 在废纸篓中找到名称带 `uninstalled` 时间标记的项目，执行“放回原处”或手动恢复。

预期：所有已识别 App 和 `MiRemoteV 2ch` 移入当前用户废纸篓，无永久删除；驱动被移除后 CoreAudio 刷新。BlackHole 和本地设置保留，恢复项目字节与 Bundle ID 不变。

失败判定：PKG 成功但 App 或驱动仍在原位，项目未进入废纸篓，BlackHole/本地设置被改动，或无法恢复。

### 5. 未知同名内容、碰撞与回滚

1. 把 Bundle ID 不同的 App 放在 canonical 或历史路径，运行卸载包。
2. 预先在废纸篓创建与卸载目标同名的占位项，再运行卸载包。
3. 用只读或拒绝移动夹具让中间项失败。

预期：未知内容保留；同名目标自动增加序号；中途失败时已移动项逆序恢复，并且 PKG 返回失败。

失败判定：未知内容被移动，废纸篓旧项被覆盖，或失败后产生半卸载状态。

## 稳定功能回归

- App-only ZIP 仍作为高级资产，不进入 DMG 根目录。
- Sparkle 只更新 App，不隐式更改或卸载驱动。
- 安装包不要求 Xcode 或 Command Line Tools。
- Apple Silicon/Intel 错包会在 Installer.app 中显示可操作的错误提示。
- 安装或卸载不读取其他 App 内部数据。

## 日志收集

1. 记录 UTC 开始/结束时间、系统版本、架构、安装前后路径与 Bundle ID。
2. 导出 Installer.app 的“窗口 → 安装器日志”，并保留 `pkgutil --check-signature`、`stapler validate`、`spctl -a -vv -t install` 和 CoreAudio 设备列表结果。
3. 不在日志中记录用户名、主目录、本地设置内容、签名凭据或语音内容。

## 自动化、代理实测与用户实测边界

自动化可验证脚本语法、伪目标卷移动/碰撞/未知内容保护、PKG/DMG 结构、架构门禁和不含永久删除命令。代理可构建无签名包并在伪卷执行脚本，但不能替代真实管理员授权、用户废纸篓、Developer ID 签名/公证/Gatekeeper、Intel Ventura 和 CoreAudio 设备刷新。这些项必须由最终候选包完成用户实测。

2026-09-06 已使用最终 Developer ID、公证并 staple 的 Apple Silicon 1.9.21 (174) 资产执行 Siri Remote 可选组件 E2E。默认不安装、主动选择安装、已有 Helper 覆盖升级不选择、卸载原路径、无管理员权限拒绝、GUI 默认值/勾选交互、App 启动和 CoreAudio 枚举均通过；Finder 废纸篓恢复、Installer.app secure UI 授权、无历史 receipt 新机和 Intel Ventura 仍待人工实机。计划见 `Testing/SiriRemoteOptionalPKGE2EPlan.md`，结果见 `Testing/SiriRemoteOptionalPKGE2EReport-2026-09-06.md`。
