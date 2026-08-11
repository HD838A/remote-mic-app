# Mac 下载 Cloudflare CDN

## 为什么开发

Mac 安装包和 Sparkle 更新资产当前直接从 GitHub Releases 下载。GitHub 仍适合作为公开发布和不可变源文件存储，但用户下载速度和可达性受 GitHub 网络状况影响，官网也只能把用户带到 Release 页面后再次选择文件。

本功能提供固定入口 `https://download.sayall.app/mac`，并让实际版本文件通过 Cloudflare CDN 下载，同时保留 GitHub 作为源站和回退路径。

## 用户功能

- 官网“下载 macOS 版”直接打开固定下载入口。
- 固定入口只下载最新正式版 DMG，不会把预览版误当作正式版。
- Sparkle 的 ZIP 和本地化更新说明使用固定标签 CDN URL。
- GitHub Releases 页面和全部源文件继续保留。

## 范围与非目标

本次范围：

- Cloudflare Worker 白名单代理公开仓库的固定标签资产；
- 官网中英文下载链接与匿名点击事件；
- appcast enclosure 和本地化说明 URL；
- 发布后的 GitHub/CDN 双路径字节回验；
- `GET`、`HEAD` 和 `Range` 下载行为。

本次不做：

- 不迁移到 Cloudflare R2；
- 不修改 App 内置稳定 feed；
- 不修改预发布版本的 GitHub API 发现机制；
- 不代理任意仓库或用户传入 URL；
- 不改变签名、公证、版本治理或 Stable 晋升规则。

## 隐私和兼容边界

Worker 只接收普通 HTTP 下载请求并访问公开 GitHub Release 资产，不需要账号、Token、Cookie 或设备身份。Cloudflare 和 GitHub 会按各自基础设施处理常规网络元数据；无线麦不在该链路新增用户账号、语音数据或本地设置上传。

已安装版本继续通过原有 GitHub `SUFeedURL` 获取 appcast，因此无需专门迁移。appcast 内的 ZIP 地址改变后仍使用同一 Sparkle Ed25519 签名验证。

## 状态

等待预览版集成。公开 Worker 和官网已经上线并使用当前正式版完成回源验证；候选产物、签名公证资产与生产到候选更新路径由统一 Mac 预览版流程继续验证。

详细实现见 [development.md](development.md)，测试边界见 [testing.md](testing.md) 和 [Testing/CloudflareDownloadCDN.md](../../Testing/CloudflareDownloadCDN.md)。
