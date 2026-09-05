# macOS 安装与卸载行为测试手册

## 适用范围

- 分支：`codex/fix-installer-uninstaller-behavior`
- 目标：macOS Apple Silicon 14+ 和 Intel Ventura 13
- 安装资产：最终 Developer ID 签名、Apple 公证并 staple 的 DMG、Install PKG 和 standalone Uninstall PKG

## 测试前准备

1. 备份需要保留的无线麦本地设置；记录当前 App/driver 路径、版本、Build 和 Bundle ID。
2. 准备全新机、仅 App、仅驱动、canonical App+驱动、历史 App+驱动和已安装更新版 App 六种状态。
3. 准备一个 Bundle ID 不同的伪 `SayAll.app`，仅用于验证未知同名内容保护。
4. 确保测试前废纸篓中的同名项目有记录，不要清空用户废纸篓。

## 安装用例

### 1. DMG 单入口与全新安装

1. 挂载对应架构 DMG。
2. 确认根目录只有 Install PKG，没有并列 App、Applications 快捷方式或 Uninstall PKG。
3. 运行 Install PKG 并完成管理员授权。

预期：`/Applications/SayAll.app` 与 `MiRemoteV 2ch` 安装完成，App 自动启动；签名、公证、Gatekeeper、架构、最低系统与权限全部正确。

失败判定：DMG 出现多个普通安装入口，或 App/driver 只安装其一。

### 2. 升级、旧路径与取消/失败

1. 分别从 canonical App、`Remote Mic.app`、`无线麦.app`、仅驱动状态安装。
2. 分别在管理员授权前取消，以及用测试夹具触发驱动复制失败。
3. 尝试用较旧 Build 覆盖较新 App。

预期：新 App 验证成功前不处理旧 App；成功后旧 App 进入废纸篓且可恢复。取消或失败不留下半更新状态；较新 App 保留。

失败判定：失败后 App 或驱动消失，旧 App 被永久删除，或较新 Build 被降级。

## 卸载用例

### 3. 完整卸载与可恢复性

1. 退出 App，运行 standalone Uninstall PKG。
2. 分别验证 canonical App+驱动、历史 App+驱动、仅 App 和仅驱动。
3. 在废纸篓中找到名称带 `uninstalled` 时间标记的项目，执行“放回原处”或手动恢复。

预期：所有已识别 App 和 `MiRemoteV 2ch` 移入当前用户废纸篓，无永久删除；驱动被移除后 CoreAudio 刷新。BlackHole 和本地设置保留，恢复项目字节与 Bundle ID 不变。

失败判定：PKG 成功但 App 或驱动仍在原位，项目未进入废纸篓，BlackHole/本地设置被改动，或无法恢复。

### 4. 未知同名内容、碰撞与回滚

1. 把 Bundle ID 不同的 App 放在 canonical 或历史路径，运行卸载包。
2. 预先在废纸篓创建与卸载目标同名的占位项，再运行卸载包。
3. 用只读或拒绝移动夹具让中间项失败。

预期：未知内容保留；同名目标自动增加序号；中途失败时已移动项逆序恢复，并且 PKG 返回失败。

失败判定：未知内容被移动，废纸篓旧项被覆盖，或失败后产生半卸载状态。

### 5. 系统音频服务未运行时的安装与卸载

1. 在系统音频服务（coreaudiod）未运行的环境或等效夹具下执行安装。
2. 在同样条件下执行卸载。

预期：安装与卸载都返回成功——驱动文件已就位/已移入废纸篓，重启音频服务只是让系统更快加载新驱动。三种分支（服务未运行、重启成功、重启失败）都如实提示，重启失败时明确告知重启 Mac 后生效，不抑制 killall 的 stderr。

失败判定：PKG 在驱动已写入/已移除后报告“安装失败”；服务未运行被误报为“已重启”；权限不足等真实失败被吞掉或谎报为“服务未运行”。

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
