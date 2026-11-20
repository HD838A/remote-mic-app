# macOS 安装与卸载行为测试手册

## 适用范围

- 基线：测试时记录本次候选的精确 `origin/main` 或 Hotfix SHA；不要把历史 SHA 当成当前基线。
- 目标：macOS Apple Silicon 14+ 和 Intel Ventura 13
- 安装资产：最终 Developer ID 签名、Apple 公证并 staple 的 `SayAll-VERSION-BUILD-AppleSilicon-install.pkg`、`SayAll-VERSION-BUILD-Intel-install.pkg` 和对应的 standalone uninstall PKG
- Siri Remote 系统服务是 Install PKG 中的可选组件：新机默认不选择；已通过 PKG 安装过该组件并存在收据时自动选中。完整卸载成功后卸载器清除该组件收据，下一次安装回到新机默认不选中。MiRemoteV 2ch 与无线麦SayAll.app仍是默认组件。
- Siri Remote 是会员功能。安装组件与会员权益是两个独立条件；仅安装组件不会自动启用。App 内启用门禁按 [会员测试手册](MembershipAndButtonProfiles.md#用例八siri-remote-双层启用门禁) 验证。

## 测试前准备

1. 备份需要保留的无线麦本地设置；记录当前 App/driver 路径、版本、Build 和 Bundle ID。
2. 准备全新机、仅 App、仅驱动、canonical App+驱动、历史 App+驱动和已安装更新版 App 六种状态。
3. 准备一个 Bundle ID 不同的伪 `SayAll.app`，仅用于验证未知同名内容保护。
4. 确保测试前废纸篓中的同名项目有记录，不要清空用户废纸篓。
5. 记录 `~/Library/Preferences/com.hd838a.RemoteMic.plist`、`~/Library/Logs/RemoteMic` 和 `~/Library/Application Support/RemoteMic` 的路径、文件数与摘要；卸载后必须保持不变。
6. 把 SayAll 固定到 Dock，并记录固定项前后顺序；至少保留一个其他 App 固定项和一个非 App 固定项。

## 历史版本兼容原则

每个新卸载包必须能卸载所有已发布版本使用的 App 身份，不得只支持当前版本。

- canonical 与历史安装路径、Bundle ID 必须继续保留；新增或变更身份时，旧值不得删除。
- 卸载器不得按 App 版本号或 Build 号跳过旧 App。
- 发布前运行 `scripts/test-installer-architecture-guard.sh`，确认卸载器仍包含 1.9.x 及更早版本的 App 身份。
- 人工验收至少覆盖一个 1.9.x 旧 App 与当前 App。

## 安装用例

### 1. PKG 全新安装

1. 下载并运行对应架构的 Installer PKG。
2. 进入“安装类型/自定安装”页面，确认 `苹果遥控器 Siri Remote` 默认未勾选。
3. 不勾选 Siri Remote，继续安装并完成管理员授权。

预期：`/Applications/SayAll.app` 与 `MiRemoteV 2ch` 安装完成，App 自动启动；`/Library/PrivilegedHelperTools/com.hd838a.SayAll.AppleRemoteHCIService` 和对应 LaunchDaemon 不被新安装创建；签名、公证、Gatekeeper、架构、最低系统与权限全部正确。

失败判定：Installer PKG 缺少 App 或驱动，或未勾选时仍新建 Siri Remote 系统服务。

### 2. 按需安装 Siri Remote 支持

1. 重新运行同一 Install PKG，进入“自定安装”。
2. 勾选 `苹果遥控器 Siri Remote`，继续安装并完成管理员授权。

预期：除默认组件外，安装器才写入 Apple Remote HCI helper 与 LaunchDaemon；helper 签名标识、Mach 服务名、权限和 `launchctl` 状态正确。有效会员在 App 中主动启用后，才进入 Apple Remote 音频准备流程；非会员仍显示开通会员入口。

失败判定：未勾选也安装 helper，勾选后 helper 或 LaunchDaemon 缺失，或安装器覆盖无法确认归属的同名服务。

### 3. 升级、旧路径与取消/失败

1. 分别从 canonical App、`Remote Mic.app`、`无线麦.app`、仅驱动状态安装。
2. 对“从未安装 Siri Remote”和“已通过 PKG 安装 Siri Remote”两种状态，分别运行新 PKG；观察前者默认未勾选、后者因收据自动选中。仅手工安装 Helper 而没有组件收据时仍不自动选中。
3. 分别在管理员授权前取消，以及用测试夹具触发驱动复制失败。
4. 尝试用较旧 Build 覆盖较新 App。

预期：新 App 验证成功前不处理旧 App；成功后旧 App 进入废纸篓且可恢复。未勾选 Siri Remote 时，不会偷偷补装该组件；已经安装过的 Siri Remote 服务保持兼容，不因普通升级被删除或重置。取消或失败不留下半更新状态；较新 App 保留。

失败判定：失败后 App 或驱动消失，旧 App 被永久删除，或较新 Build 被降级。

## 卸载用例

### 4. 完整卸载与可恢复性

1. 退出 App，运行文件名包含当前 `VERSION-BUILD` 的对应架构 standalone 卸载包。
2. 分别验证 canonical App+驱动、历史版本 App（至少一个 1.9.x 版本）+驱动、仅 App 和仅驱动。
3. 在废纸篓中找到名称带 `uninstalled` 时间标记的项目，执行“放回原处”或手动恢复。

预期：所有已识别 App 和 `MiRemoteV 2ch` 移入当前用户废纸篓，无永久删除；已安装的 Apple Remote HCI helper、对应 LaunchDaemon 和状态目录按卸载器当前实现安全移除或停用，`--restore` 可恢复应保留的项；驱动被移除后 CoreAudio 刷新。当前控制台用户 Dock 中指向被卸载 App 的固定项被移除，其他固定项和 Dock 设置不变。`com.hd838a.RemoteMic.siri-remote` 收据被清除。BlackHole、App 本地设置、日志、历史、录音和其他用户数据保留；恢复项目字节与 Bundle ID 不变。

失败判定：PKG 成功但 App、驱动或 HCI helper 仍在原位，1.9.x 旧 App 未被识别，项目未进入废纸篓，LaunchDaemon 仍加载，`--restore` 不可用，Siri 收据仍存在，SayAll Dock 固定项仍存在，其他 Dock 项被删除或顺序被重建，BlackHole/本地设置/日志/用户数据被改动，或无法恢复。

### 5. 未知同名内容、碰撞与回滚

1. 把 Bundle ID 不同的 App 放在 canonical 或历史路径，运行卸载包。
2. 预先在废纸篓创建与卸载目标同名的占位项，再运行卸载包。
3. 用只读或拒绝移动夹具让中间项失败。

预期：未知内容保留；同名目标自动增加序号；中途失败时已移动项逆序恢复，并且 PKG 返回失败。

失败判定：未知内容被移动，废纸篓旧项被覆盖，或失败后产生半卸载状态。

### 6. 系统音频服务未运行时的安装与卸载

1. 在系统音频服务（coreaudiod）未运行的环境或等效夹具下执行安装。
2. 在同样条件下执行卸载。

预期：安装与卸载都返回成功——驱动文件已就位/已移入废纸篓，重启音频服务只是让系统更快加载新驱动。三种分支（服务未运行、重启成功、重启失败）都如实提示，重启失败时明确告知重启 Mac 后生效，不抑制 killall 的 stderr。

失败判定：PKG 在驱动已写入/已移除后报告“安装失败”；服务未运行被误报为“已重启”；权限不足等真实失败被吞掉或谎报为“服务未运行”。

### 7. Siri Remote 收据在卸载后重置

1. 先通过 Install PKG 选择安装 Siri Remote 组件，确认 `pkgutil --pkg-info com.hd838a.RemoteMic.siri-remote` 成功。
2. 运行卸载包，确认卸载成功。
3. 再次执行 `pkgutil --pkg-info com.hd838a.RemoteMic.siri-remote` 和 `ls /var/db/receipts/com.hd838a.RemoteMic.siri-remote.*`。
4. 重新运行 Install PKG，打开“自定安装”。

预期：卸载后收据和 BOM 均不存在；重新安装时 `苹果遥控器 Siri Remote` 默认未勾选；App 的 Onboarding 不再把 Siri Remote 显示为已安装来源。只有手工保留且无法确认归属的 Siri helper 或 LaunchDaemon 存在时，收据才保留。

失败判定：收据仍存在、重装仍自动勾选、Onboarding 仍显示 Siri Remote 来源，或无法确认归属的 helper 被保留但收据被清除。

### 8. Dock 固定项在卸载后移除

1. 把 SayAll 固定到 Dock，同时保留至少两个其他 App 固定项和一个文件夹或分隔符。
2. 运行卸载包，确认 App 已移入废纸篓。
3. 检查 Dock 中 SayAll 固定项、其他固定项和顺序；检查 `DOCK_TILE phase=cleanup` 日志。
4. 退出并重新登录，再次检查 Dock。

预期：只移除指向本次被卸载 App 的 SayAll 固定项；其他固定项、顺序、方向、大小和其他 Dock 设置不变；Dock 重新启动后不出现问号占位。若用户从未固定过 App，只移除运行时图标，不修改 Dock 偏好。

失败判定：SayAll 固定项仍存在，其他固定项被删除或重排，Dock 设置被重置，或卸载器修改了其他用户的 Dock。

### 9. 配置、日志和用户数据保留

1. 卸载前记录 App 本地设置、`~/Library/Logs/RemoteMic`、历史、录音和其他用户数据。
2. 运行卸载包。
3. 比较卸载前后的文件、摘要和权限。

预期：App 的 UserDefaults、日志目录、历史、录音、缓存和其他用户数据不被修改；`/Library/Application Support/RemoteMic/DriverNaming` 仍按既有行为移入废纸篓，可恢复。Dock 中只移除 SayAll 固定项。

失败判定：设置、日志、历史、录音或其他用户数据被删除、截断、重置或移动；驱动名称记录被永久删除。

### 10. 收据或 Dock 清理失败

1. 用等效夹具让 `pkgutil --forget` 失败，或让当前用户的 Dock 偏好导入失败。
2. 运行卸载包。

预期：App、驱动和 HCI 项仍按正常路径移入废纸篓；Installer 日志出现 `SIRI_RECEIPT phase=cleanup result=failed reason=forget_failed` 或 `DOCK_TILE phase=cleanup result=failed reason=preferences_write_failed`；安装器明确提示部分清理失败并返回失败；已移动项目不回滚。

失败判定：失败被报告为完全成功，日志没有稳定失败原因，App 被回滚但没有提示，或已清理的收据被重新创建。

## 稳定功能回归

- App-only ZIP 仍作为高级资产单独下载。
- Sparkle 只更新 App，不隐式更改或卸载驱动。
- 安装包不要求 Xcode 或 Command Line Tools。
- Apple Silicon/Intel 错包会在 Installer.app 中显示可操作的错误提示。
- 安装或卸载不读取其他 App 内部数据。卸载只读取并更新当前控制台用户的 `com.apple.dock` 偏好，用于删除 SayAll 固定项。
- 卸载不修改 App 本地设置、日志、历史、录音和其他用户数据。
- Finder 文件名、Installer.app 标题和公开版本化 PKG 资产均使用 `SayAll` 品牌；历史 Bundle ID、Package ID、receipt 和旧 App 路径保持兼容。Siri Remote 组件收据只在完整卸载且没有残留无法确认归属的组件时清除。

## 日志收集

1. 记录 UTC 开始/结束时间、系统版本、架构、安装前后路径与 Bundle ID。
2. 导出 Installer.app 的“窗口 → 安装器日志”，并保留 `pkgutil --check-signature`、`stapler validate`、`spctl -a -vv -t install` 和 CoreAudio 设备列表结果。
3. 卸载后记录 `SIRI_RECEIPT phase=cleanup` 和 `DOCK_TILE phase=cleanup` 的结果、原因和数量；同时记录 `pkgutil --pkg-info com.hd838a.RemoteMic.siri-remote`。
4. 不在日志中记录用户名、主目录、Dock 条目内容、本地设置内容、签名凭据或语音内容。

## 自动化、代理实测与用户实测边界

自动化可验证脚本语法、伪目标卷移动/碰撞/未知内容保护、PKG 结构、架构门禁和不含永久删除命令。`scripts/test-uninstaller-cleanup.sh` 还回放 Siri 收据清理、Dock 固定项匹配/跳过/写入失败和仅收据残留的早期退出；`BuildSigningTests.uninstallerCleanupFixturePasses` 在 CI 执行该脚本。代理可构建无签名包并在伪卷执行脚本，但不能替代真实管理员授权、用户废纸篓、Developer ID 签名/公证/Gatekeeper、Intel Ventura、真实 Dock 和 CoreAudio 设备刷新。这些项必须由最终候选包完成用户实测。

2026-09-06 已使用最终 Developer ID、公证并 staple 的 Apple Silicon 1.9.21 (174) 资产执行 Siri Remote 可选组件 E2E。默认不安装、主动选择安装、已有 Helper 覆盖升级不选择、卸载原路径、无管理员权限拒绝、GUI 默认值/勾选交互、App 启动和 CoreAudio 枚举均通过；Finder 废纸篓恢复、Installer.app secure UI 授权、无历史 receipt 新机和 Intel Ventura 仍待人工实机。原始历史报告已按仓库清理规则移出仓库，测试边界保留在本节。

## 2026-10-08 Siri 可选组件检测回归

安装器使用目标卷的 Siri 组件安装收据判断初始选中状态。它不直接查询系统文件路径，也不启用已弃用的外部脚本选项。

| 状态 | 操作 | 预期结果 |
| --- | --- | --- |
| 未安装 Siri 组件，没有对应收据 | 打开自定安装页 | 苹果遥控器 Siri Remote 不选中 |
| 已通过 PKG 安装 Siri 组件，有对应收据 | 打开自定安装页 | 苹果遥控器 Siri Remote 自动选中 |
| 只有手工安装的 Helper，没有组件收据 | 打开自定安装页 | 不自动选中；已有 Helper 保留，需要更新时手动选中 |
| 上述任一状态 | 分别选择或不选择该组件，完成安装 | 安装成功；无 IFJS 外部路径访问错误 |

“已安装收据自动选中”只适用于没有完整卸载的升级状态。完整卸载成功后，卸载器清除 Siri 组件收据，下一次安装按全新状态默认不选中。两种架构分别验收。收据断言和 UI 检查不代替最终签名包安装。

## 2026-11-20 卸载清理回归

本次候选增加两项卸载清理：完整卸载后清除 `com.hd838a.RemoteMic.siri-remote` 收据；移除当前控制台用户 Dock 中指向被卸载 App 的固定项。App 本地设置、日志、历史、录音和其他用户数据不在卸载目标内。

| 自动化或回放 | 结果 |
| --- | --- |
| `zsh -n packaging/doubao-driver/uninstall/postinstall` | 通过 |
| `scripts/test-uninstaller-cleanup.sh` | 通过：收据存在/缺失/不可确认归属/清除失败；Dock 匹配/无匹配/非启动卷/无控制台用户/写入失败；仅收据残留的早期退出 |
| `scripts/test-installer-architecture-guard.sh` | 通过：静态门禁和上述回放 |
| `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter BuildSigningTests` | 通过；CI 执行同一脚本 |
| 真实签名 PKG、Installer 管理员授权、真实 Dock、双账户、Intel Ventura | 未执行，待最终候选验收 |

失败判定：收据或 Dock 固定项在完整卸载后仍存在；其他 Dock 项被删除或重排；设置、日志或用户数据被修改；失败被报告为成功。
