# 开发记录

## 关键设计

```text
官网 / 用户
  → https://download.sayall.app/mac
  → GitHub releases/latest HEAD 解析正式标签
  → /mac/releases/<tag>/Remote-Mic-<version>.dmg
  → Cloudflare Worker 缓存代理
  → GitHub Releases 固定标签资产
```

Sparkle 路径不经过动态 `/mac`：

```text
https://download.sayall.app/mac/channels/<stable|preview>/<appcast>
  → Cloudflare 边缘解析并短时缓存 GitHub Releases 列表
  → /mac/releases/<tag>/<appcast>
  → https://download.sayall.app/mac/releases/<tag>/Remote-Mic-<version>.zip
  → Cloudflare Worker
  → GitHub Releases 固定标签 ZIP
```

候选公开资产由 `candidate-provenance.json` 的 payload 清单唯一决定。安装 PKG 仍在对应 DMG 内完成签名、公证与校验，但不再作为 standalone Release 资产重复上传；两套 appcast 复用同一对中英文说明，两个 DMG 的摘要写入一个 `Remote-Mic-<version>.dmg.sha256`。该文件名沿用 Worker 现有白名单，无需新增下载路由；Worker 也必须继续接受历史固定标签 URL，不能因当前矩阵变化而撤销既有资产路径。

## 涉及文件

- `scripts/notarize-release.sh`：生成 CDN enclosure 与更新说明 URL。
- `scripts/publish-preview-release.sh`：从已验证 staging artifact 发布 GitHub Pre-release，并增加 CDN 全资产及 stable/preview appcast 通道字节回验。
- `Tests/RemoteMicTests/BuildSigningTests.swift`：锁定 CDN URL、发布回验和旧 feed 边界。
- `README.md`、`README.en.md`：提供固定正式版下载入口和 GitHub 回退。
- `TECHNICAL.md`、`TECHNICAL.en.md`：记录 GitHub feed 与 CDN enclosure 的职责边界。
- 私有官网仓库的 `website/v1/worker/download-proxy.js`：下载 Worker。
- 私有官网仓库的 `website/v1/src/data/site.ts` 与 `src/scripts/analytics.ts`：固定下载链接、说明和匿名事件目标。

## 发布顺序

必须先部署并验证 Worker，再发布带 CDN enclosure 的 Preview。GitHub 固定标签资产不存在时，Worker 应返回 404；publication workflow 只有在 GitHub、CDN 固定资产、preview 通道候选字节和 stable 通道正式版字节均验证后才报告成功。

## 已知限制

- 第一次访问尚未缓存的版本文件仍需要 GitHub 源站可用。
- appcast 通道解析仍依赖 Cloudflare 边缘访问公开 GitHub Releases API，但 60 秒缓存由所有客户端共享，不再消耗每台设备的未认证额度。
- Cloudflare 缓存提升下载稳定性，但不能替代 GitHub Release 的不可变资产和版本治理。
- 固定 `/mac` 依赖 GitHub `releases/latest` 的重定向语义；测试必须确认它只解析正式版。
