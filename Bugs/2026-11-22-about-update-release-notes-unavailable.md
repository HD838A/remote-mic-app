# 关于页显示“此版本暂未提供可展示的更新内容”

- 时间：2026-11-22
- 状态：已修复，等待 PR CI 与发布后真实升级验证
- 影响范围：macOS 设置页“关于”版本中心；使用 `download.sayall.app` 与 `SayAll-<版本>-<Build>` 资产命名的公开版本
- 功能点：更新说明加载、语言切换、Sparkle 更新信息展示
- 简单描述：升级前“设置 → 关于”长期显示“此版本暂未提供可展示的更新内容”，但 Sparkle 更新弹窗正常显示完整合并说明。
- 原始记录：用户在 2.0.9 升级过程中观察到；该问题不影响 Sparkle 检查、下载、安装和本次发布。

## 错误证据

- 2.0.9 公开 appcast 的说明链接为 `https://download.sayall.app/mac/releases/v2.0.9/SayAll-2.0.9-424.en.txt` 和 `.zh.txt`，下载包为 `SayAll-2.0.9-424.zip`。
- 公开 Release 实际包含 `SayAll-2.0.9-424.en.txt`、`SayAll-2.0.9-424.zh.txt` 和 `SayAll-2.0.9-424.zip`；中文说明文件包含完整合并内容。
- 旧路径 `https://github.com/HD838A/remote-mic-app/releases/download/v2.0.9/Remote-Mic-2.0.9.zh.txt` 返回 404。
- 1.9.21 的 appcast 已使用 `download.sayall.app`；2.0.6、2.0.8、2.0.9 的资产名继续使用 `SayAll-<版本>-<Build>`。
- 关于页截图夹具使用 `archiveURL: nil` 和内置说明，绕过了真实 URL 构造；单元测试只使用 `github.com` 和旧 `Remote-Mic-` 命名，因此自动化未覆盖线上路径。
- 现有运行日志没有记录说明加载失败；旧代码在 URL 不可用和网络失败时静默返回。

## 根因

`UpdateReleaseNotes.assetURL` 使用两个已过期的发布假设：

1. 只接受 `github.com`。正式 appcast 的 enclosure 和说明链接已迁到 `download.sayall.app`，函数直接返回 `nil`，不会发起请求。
2. 说明文件名固定为 `Remote-Mic-<版本>.<语言>.txt`。当前资产包含 Build，名称为 `SayAll-<版本>-<Build>.<语言>.txt`；Intel 包使用 `-Intel.zip`，但复用不带 `-Intel` 的说明文件。

Sparkle 弹窗读取 appcast 的 `sparkle:releaseNotesLink`，因此不经过这段推导逻辑。关于页没有可用说明时，`releaseNotes` 为空数组，界面显示“此版本暂未提供可展示的更新内容”。

## 修复

- 允许 `github.com` 和 `download.sayall.app` 两个 HTTPS 发布域名。
- 从更新包文件名推导说明文件名：去掉 `.zip`，去掉 Intel 包的 `-Intel` 后缀，再追加 `.<语言>.txt`。
- 保留旧 `Remote-Mic-<版本>.zip` 和 Intel 共用说明的兼容路径。
- 增加 `UPDATE RELEASE_NOTES` 终态日志：`loaded`、`asset_url_unavailable`、`notes_empty` 或 `load_failed`。日志只包含版本稳定 token、语言、说明条数和错误域/码，不包含 URL、路径或用户内容。
- 新增回归断言，覆盖 CDN 新命名、Intel 共用说明、旧命名兼容、非法域名和非 ZIP 文件。

## 验证

- `swift test --disable-keychain --filter UpdateInformationTests`：17 项通过，覆盖 CDN 新命名、Intel 共用说明、旧命名兼容、非法域名、非 ZIP 文件和语言重载。
- `swift test --disable-keychain --skip BuildSigningTests`：1585 项、112 个 suite 通过。
- `SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain -c release`：构建通过。
- `./scripts/verify-repository-governance.sh origin/main`：通过。
- `git diff --check`：通过。
- 未完成：真实签名包升级、Sparkle 弹窗与关于页并排验收。无需真实硬件或第三方 App；发布后按 `Testing/AboutUpdateCenter.md` 用例 3 和用例 6 执行。
- 已发布的 2.0.8/2.0.9 不会被本修复回溯；用户安装包含本修复的版本后，下一次检查更新才会使用新逻辑。

## 边界与回滚

- 只读取公开 appcast 和公开说明资产，不读取第三方 App 私有文件、数据库、沙盒或协议。
- 修复只影响关于页说明展示，不改变 Sparkle 下载、安装、签名、公证或更新通道。
- 回滚只需还原 URL 推导和日志改动；没有配置、持久化或协议迁移。
