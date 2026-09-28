# Xcode 26.4 生成的 PKG 组件清单缺少不可重定位字段

- 时间：2026-09-20
- 状态：已修复，待真实安装验收
- 影响范围：使用 Xcode 26.4 构建 macOS 安装 PKG
- 功能点：SayAll.app 安装路径、旧 receipt 升级、Siri Remote 可选组件

## 复现

在 macOS 26、Xcode 26.4 上，用 Developer ID 签名的 `SayAll.app` 和
`MiRemoteV2ch.driver` 执行：

```zsh
EXPECTED_DEVELOPER_TEAM_ID=L3QHLDRPAY \
INSTALLER_SIGNING_IDENTITY="Developer ID Installer: lei qian (L3QHLDRPAY)" \
REQUIRE_DEVELOPER_ID_SIGNING=1 \
scripts/build-doubao-driver-pkg.sh
```

`pkgbuild --analyze` 能识别 `Applications/SayAll.app`，但生成的对应字典
没有 `BundleIsRelocatable`。随后 `PlistBuddy Set` 返回：

```text
Set: Entry, ":1:BundleIsRelocatable", Does Not Exist
```

安装包因此在组件包生成前失败。

## 根因

构建脚本假定 `pkgbuild --analyze` 始终预先生成 `BundleIsRelocatable`。
旧工具链满足该假设；Xcode 26.4 对当前 App 组件不再生成该键。路径识别、
App 签名和 payload 本身均正常，失败边界仅是对可选 plist 键使用了
只能修改现有键的 `Set`。

## 修复

继续按 `RootRelativeBundlePath` 精确定位 `Applications/SayAll.app`：

1. 字段存在时使用 `Set` 写为 `false`；
2. 字段不存在时使用 `Add ... bool false` 新建；
3. 仍然把修改后的组件清单交给正式 `pkgbuild`，不改变 Bundle ID、组件
   package identifier、安装路径或旧 receipt 兼容语义。

## 验证

- `scripts/test-installer-architecture-guard.sh`：同时守护 `Set` 和缺失字段
  的 `Add` 路径。
- `swift test --disable-keychain --filter releaseBundleNameMatchesBrandingAndInstallerPaths`：
  守护发布脚本包含两条兼容路径。
- 使用原始复现命令重新构建真实 Developer ID 安装/卸载 PKG，并运行
  `scripts/verify-doubao-driver-pkg.sh` 做结构验证。

自动化和结构验证不能替代从旧 receipt 升级后的真实 Installer.app 流程；
正式发布前仍需按 `Testing/FirstUseSuccess.md` 执行升级与实机硬件回归。
