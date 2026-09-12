# Mac 下载 Cloudflare CDN

## 为什么开发

Mac 安装包和 Sparkle 更新资产当前直接从 GitHub Releases 下载。GitHub 仍适合作为公开发布和不可变源文件存储，但用户下载速度和可达性受 GitHub 网络状况影响，官网也只能把用户带到 Release 页面后再次选择文件。

本功能提供固定入口 `https://download.sayall.app/mac`，并让实际版本文件通过 Cloudflare CDN 下载，同时保留 GitHub 作为源站和回退路径。

## 用户功能

- 官网“下载 macOS 版”直接打开固定下载入口。
- 固定入口只下载最新正式版 DMG，不会把预览版误当作正式版。
- Sparkle 的 ZIP 和本地化更新说明使用固定标签 CDN URL。
- GitHub Releases 页面和全部源文件继续保留；macOS Release 的公开矩阵由 `candidate-provenance.json` 唯一定义，安装 PKG 只在对应 DMG 内保留，不再重复上传。

## 范围与非目标

本次范围：

- Cloudflare Worker 白名单代理公开仓库的固定标签资产；
- Cloudflare Worker 提供 stable/preview、Apple Silicon/Intel 四个 appcast 固定通道；
- 官网中英文下载链接与匿名点击事件；
- appcast enclosure 和本地化说明 URL；
- 发布后的 GitHub/CDN 双路径字节回验；
- provenance 驱动的新资产矩阵和历史 Release 自身 provenance 的只读兼容；
- `GET`、`HEAD` 和 `Range` 下载行为。

本次不做：

- 不迁移到 Cloudflare R2；
- 不迁移或复制 GitHub Release 源资产；
- 不代理任意仓库或用户传入 URL；
- 不改变签名、公证、版本治理或 Stable 晋升规则。

## 隐私和兼容边界

Worker 只接收普通 HTTP 下载请求并访问公开 GitHub Release 资产，不需要账号、Token、Cookie 或设备身份。Cloudflare 和 GitHub 会按各自基础设施处理常规网络元数据；无线麦不在该链路新增用户账号、语音数据或本地设置上传。

新版本通过 Cloudflare 固定通道获取 appcast，Cloudflare 在边缘读取公开 GitHub Releases 并重定向到同域版本化 appcast；客户端不再直接请求未认证 GitHub Releases API。appcast 内的 ZIP 地址继续使用同一 Sparkle Ed25519 签名验证。

## 状态

四个 appcast 通道已部署，stable 两架构指向当前正式版 `v1.9.18`，preview 两架构指向当前预览版 `v1.9.20`，最终字节均与 GitHub 固定 Tag 一致。等待 `1.9.21` 候选产物、签名公证和真实 Sparkle UI 发布闭环。

详细实现见 [development.md](development.md)，测试边界见 [testing.md](testing.md)、[Testing/CloudflareDownloadCDN.md](../../Testing/CloudflareDownloadCDN.md) 和 [Testing/MacReleaseAssetMatrix.md](../../Testing/MacReleaseAssetMatrix.md)。
