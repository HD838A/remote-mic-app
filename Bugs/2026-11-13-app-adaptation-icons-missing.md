# App 适配页的 App 图标不显示

## 现象与证据

「APP 适配」页左侧档案列表应显示每个 App 的图标，用户现场反馈图标全部消失。
列表行由 `c8fa4ba9`（2026-11-01）改为主从布局时新增，当时直接使用
`NSWorkspace.shared.icon(forFile: profile.applicationPath)` 取图标。

代码检查确认两种会产生空路径或失效路径的情况：

- 完整配置备份导出时 `completeConfigurationSnapshot()` 把每个档案的
  `applicationPath` 清空（`AppSettings.swift` 中 `applications[index]["applicationPath"] = ""`），
  导入后的 `importConfiguration(from:)` 只校验并采用档案，没有再按 bundle identifier
  重解析本机路径。
- 旧档案可能保存了另一台 Mac 的路径。`applicationPath` 为空或文件不存在时，
  `NSWorkspace.shared.icon(forFile:)` 不会返回目标 App 的图标。

用户现场没有提供设置文件或日志；本记录只确认可复现的代码条件，不推断用户数据来源。
便携配置传输在 `preparePortable` 中已有 bundle identifier 重解析，不覆盖完整备份导入路径。

## 根因与修复

图标显示只信任档案里保存的路径，没有处理“路径为空或文件不存在”的情况。
在列表图标显示处增加兜底：路径为空或文件不存在时，用 `bundleIdentifier` 通过
`NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` 解析当前 Mac 上的
实际 App URL，再取图标。路径仍存在时保持原有行为，不增加额外解析。

解耦后的路径选择在 `Sources/RemoteMic/ApplicationIconResolver.swift`，显示处仍只在
`SettingsView.applicationIcon(for:)` 调用，不改变档案、导入格式或按键执行链路。

## 验证

- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter ApplicationIconResolverTests`
  通过 4 项：空路径解析、失效路径解析、有效路径不触发解析、解析失败保留原路径。
- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'SettingsPageRegressionTests|CustomApplicationProfileLifecycleTests'`
  通过 80 项。
- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain` 全量 1391 项通过。
- 本机 `NSWorkspace` 查询 `com.apple.TextEdit` 返回 `/System/Applications/TextEdit.app`，
  确认 bundle identifier 兜底可用。
- `SettingsScreenshotRenderer` 新增 `REMOTE_MIC_SETTINGS_SCREENSHOT_APPLICATIONS_FIXTURE=1`
  隔离夹具，种入空路径与失效路径档案；用 release App 的生产 `SettingsView` 生成
  中英文浅色/深色四张 `1020×772` 截图，图标均正常显示。
- `git diff --check` 通过。
- 未覆盖：用户本机原档案复现、实际导入完整配置备份后的现场视觉验收。截图使用隔离夹具，
  证明生产视图在空路径和失效路径下能显示图标，不证明特定用户数据的来源。
  本次为显示兜底修复，未改变完整备份导入的路径持久化行为；如需让导入后立即写回
  实际路径，应作为独立工作项评估。
