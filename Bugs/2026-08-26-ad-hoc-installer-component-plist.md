# 本地 DMG 安装器无法写入缺失的组件可迁移属性

## 复现

1. 在 `codex/native-system-settings-ui` 的 `4b09b61` 上使用 Xcode 27 执行 Apple Silicon 本地测试打包：`CODE_SIGN_IDENTITY=- INSTALLER_SIGNING_IDENTITY=- scripts/build-dmg.sh`。
2. App release 构建、ad-hoc 签名和 MiRemoteV 2ch 驱动构建通过。
3. `pkgbuild --analyze` 生成组件清单后，安装器构建在 App 组件处失败：`Set: Entry, ":1:BundleIsRelocatable", Does Not Exist`。

正常行为：无论当前 `pkgbuild` 是否预先生成 `BundleIsRelocatable`，安装器都应把 `Applications/SayAll.app` 标记为不可迁移并继续打包。

## 日志结论

失败发生在安装包组件清单处理阶段；App、驱动、签名校验和此前 Swift 测试均已通过。日志没有显示业务运行时、权限、蓝牙或音频错误。

## 根因

`scripts/build-doubao-driver-pkg.sh` 使用 `PlistBuddy Set` 修改 `BundleIsRelocatable`。该命令只能修改既有键；当前 Xcode 27 的 `pkgbuild --analyze` 没有为 SayAll.app 预先写入该键，因此脚本在生成安装组件包前退出。

## 修复

保持原组件定位逻辑不变：先尝试修改既有键；键不存在时使用 `PlistBuddy Add` 新增布尔值 `false`。没有改变 App、驱动、安装位置、签名或发布行为。

## 验证

- `BuildSigningTests` 增加缺失键兼容路径的源码门禁。
- 重新执行原始 Apple Silicon ad-hoc DMG 打包流程，并使用 `scripts/verify-dmg.sh` 挂载、展开和验证内部安装包。
- 对 DMG 内 App 执行 ad-hoc 深度签名、架构和版本复核，并校验 SHA-256。

## 验证边界

本地测试包不是 Developer ID 签名或 Apple 公证资产；Gatekeeper 拒绝属于预期结果，不能作为公开 Release、私有 Draft 或普通用户分发包。
