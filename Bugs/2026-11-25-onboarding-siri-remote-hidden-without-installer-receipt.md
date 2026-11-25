# 应用内安装 Siri Remote 组件后 Onboarding 仍不显示苹果遥控器

- 时间：2026-11-25
- 状态：候选修复完成，等待真实签名候选包验收
- 影响范围：通过 App 内安装（连接页安装模块 / 升级自动安装）获得 Siri Remote 组件、但没有 Installer 收据的用户
- 功能点：Onboarding 控制设备选择、Siri Remote 组件可用性
- 简单描述：用户在连接页安装 Siri Remote 组件成功，语音链路已 ready，但进入 Onboarding 后「实体遥控器」只剩两台小米遥控器，苹果遥控器整项不显示。
- 原始记录：2026-11-25 用户反馈并附生产日志与选择控制设备页截图。

## 现象与证据

用户 Build 442（2.0.10）日志，同一进程内：

| 时间 | 记录 |
| --- | --- |
| 01:49:24 | 启动，`component_installed=false`，helper / LaunchDaemon / receipt 均为 false |
| 01:49:34.915 | `install_requested source=connection_page`，用户点击连接页安装模块 |
| 01:49:40.333 | `helper_present=true launch_daemon_present=true component_installed=true`，同一行 `installer_receipt_present=false` |
| 01:49:40.347 | `SIRI REMOTE AUDIO phase=ready result=capture_available` |
| 01:49:50.427 | 从连接页进入 Onboarding：`ONBOARDING SIRI_REMOTE phase=availability installed=false available=false` |
| 次日 02:32:30 | 再次进入 Onboarding，仍为 `installed=false available=false` |

本次会话全部 5 条 `SIRI REMOTE COMPONENT` 记录中 `installer_receipt_present` 始终为 false，而安装完成后 `helper_present` 与 `launch_daemon_present` 始终为 true。日志内没有任何苹果遥控器连接或按键事件，用户在选择设备页就被挡住，未进入后续步骤。

用户截图：控制设备页「实体遥控器」只有「小米蓝牙遥控器 2 Pro」「小米蓝牙遥控器 2」，「更多控制方式」为 iOS / watchOS App 与微信小程序，没有苹果遥控器。

## 根因

仓库里有两套「组件是否已安装」的判定，来源不同：

1. `OnboardingBuildCapabilities.isSiriRemotePackageInstalled()` 只检查 Installer 收据
   `/var/db/receipts/com.hd838a.RemoteMic.siri-remote.plist`。
   `availableControlSources()` 用它决定是否追加 `.siriRemote`，
   `OnboardingPhysicalRemoteCard.ordered(availableSources:)` 再按来源生成卡片，
   收据缺失时整个苹果遥控器分组不会出现。
2. `AppleRemoteComponentInstallation.isInstalled()` 检查 helper 与 LaunchDaemon，
   连接页安装模块（`SettingsView` 的 `showsAppleRemoteComponentInstallation`）用的是这一套。

App 内安装走私有包 `AppleRemoteHCIServiceUpdater` 的 `kSMRightBlessPrivilegedHelper`
（SMJobBless），只写入 `/Library/PrivilegedHelperTools` 与 `/Library/LaunchDaemons`，
不会产生 pkgutil 收据。于是这类用户的稳定状态是 helper=true、receipt=false，
Onboarding 永远判定为不可用。

时间线也吻合：`63acc86b`（2026-10-16）确定 Onboarding 按收据显示入口；
`7b9810f7`（2026-11-17）新增连接页应用内安装模块，并在 `SiriRemoteActivationPolicy`
确立「收据 **或** helper」语义（`!installerReceiptPresent && !helperInstalled`）；
`0b8759e7`（2026-11-18）修「组件缺失误显示重新授权」时用的是 `isSiriRemoteHelperInstalled`，
但 Onboarding 的可用性门禁没有跟着统一。

同类表现还有 `BridgeAppModel.activateSiriRemoteFromCard()`：只查收据，helper 已安装时
点卡片「启用」仍会弹出「去下载安装包」的提示。

内部测试机通过 PKG 安装，收据天然存在，因此本地和离屏夹具都没有暴露这个分支。

## 修复

1. 新增 `OnboardingBuildCapabilities.isSiriRemoteComponentAvailable()`：
   `Installer 收据存在 || (helper 存在 && LaunchDaemon 存在)`，与 `SiriRemoteActivationPolicy` 一致。
   `isSiriRemotePackageInstalled()` 保留为只表示「收据存在」的诊断事实，不再承担可用性判断。
2. `availableControlSources(siriRemoteComponentAvailable:)` 改用新的可用性入参；
   Onboarding 的可用来源改为实时求值，不再在 `init` 时固化一次，
   在向导内安装成功后返回控制设备页即可看到苹果遥控器。
3. 离屏渲染与测试的覆盖参数同步改名为 `siriRemoteComponentAvailableOverride`，语义与生产一致。
4. `activateSiriRemoteFromCard()` 改用同一判定，helper 已安装时不再提示下载安装包。
5. Onboarding 可用性日志改为 `receipt_present`、`component_available`、`available` 三个字段，
   下次出现同类问题可以直接区分「没装」「装了但没收据」「收据残留」。
6. 卸载器不再保留收据：原实现在留下无法确认归属的 helper 或 LaunchDaemon 时跳过
   `pkgutil --forget`，卸载后仍会读到“组件已安装”，安装器也会继续自动勾选该组件。
   现在每次卸载都清除收据，无法确认归属的文件仍保留原样，日志记
   `SIRI_RECEIPT phase=cleanup result=forgotten kept_unverified=1`。

## 验证

- 新增 `OnboardingFlowTests.siriRemoteComponentAvailableWithHelperButNoReceipt`：
  收据缺失、helper 与 LaunchDaemon 都在时可用性为 true，苹果遥控器来源与卡片出现；
  helper 或 LaunchDaemon 缺一时仍为 false，避免半装状态放行。
- `OnboardingFlowTests.siriRemoteRequiresBothBuildSupportAndInstallerReceipt` 按新语义更新，
  继续锁定「公开构建不显示苹果遥控器来源」。
- 公开构建 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --disable-sandbox` 全量
  1662 项、116 个 suite 通过；另加 `SAYALL_SIRI_REMOTE_ENABLED` 编译开关跑 `OnboardingFlowTests`
  131 项通过。
- 反向验证：把 `isSiriRemoteComponentAvailable` 临时改回收据-only，
  `siriRemoteComponentAvailableWithoutInstallerReceipt` 在第一条断言失败；恢复后通过。
- `./scripts/test-uninstaller-cleanup.sh` 与 `./scripts/test-installer-architecture-guard.sh` 通过，
  覆盖“无法确认归属的组件保留文件但清除收据”。
- 仓库治理与边界检查通过：`bash scripts/verify-repository-governance.sh`、
  `zsh scripts/check-repository-boundaries.sh`。
- 待真实签名候选包验收：PKG 安装与 App 内安装两条路径分别进入 Onboarding，
  确认控制设备页出现苹果遥控器分组；向导内点「安装组件」成功后返回上一步也能看到；
  真实卸载包在“无法确认归属组件”场景下确认收据被清除、文件仍保留。

## 边界

本次只统一「组件是否可用」的判定、Onboarding 的求值时机和卸载后的收据状态，不改变组件安装实现、
SMJobBless 授权流程、PKG 收据写入、会员门禁、音频链路或苹果遥控器按键与语音语义。
通过 PKG 安装、收据存在的用户行为不变。卸载器仍只移动确认归属的 App、驱动与 helper，
无法确认归属的文件不移动、不删除；本次只改变这些文件存在时的收据保留策略。
