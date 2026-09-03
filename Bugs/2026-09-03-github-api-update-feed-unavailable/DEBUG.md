# 1.9.19 偶发显示“暂时无法获取更新信息”

## 状态

- 发现日期：2026-09-03
- 影响版本：至少 `1.9.19 (172)`
- 修复目标：`1.9.21` Pre-release
- 状态：根因确认，候选修复、自动化与生产通道部署完成，等待 `1.9.21` 真实 Sparkle UI 验收

## 复现

1. 在 `1.9.19 (172)` 开启预发布更新检查。
2. GitHub 未认证 API 额度不足或 Releases API 返回非 200 时，在关于页主动检查更新。
3. 观察页面和 `~/Library/Logs/RemoteMic/runtime.log`。

错误行为：页面显示“暂时无法获取更新信息”，日志出现 `UPDATE FEED prerelease_enabled=true resolved=false` 和 `UpdateFeedResolutionError error_code=0`。

正常边界：同一时间 GitHub 固定 Tag appcast 与 `download.sayall.app` 版本化 appcast 均能返回 200；Sparkle feed 文件和发布资产没有缺失。

## 日志与根因

现场日志多次记录预发布 feed 解析失败。代码检查确认客户端会先请求未认证的 `https://api.github.com/repos/HD838A/remote-mic-app/releases`，只有收到 HTTP 200 才能找到预发布 appcast；任意限流、网络代理或 GitHub API 异常都会在 Sparkle 读取 appcast 前失败。调查时 GitHub 未认证 API 额度仅剩 `14/60`，与失败路径一致。

根因不是 appcast 文件不可用，而是客户端把 GitHub Releases API 当作每台设备的预发布发现控制面。该 API 的未认证额度和可达性不适合作为客户端更新检查依赖。

## 修复

- Cloudflare Worker 新增 stable/preview 与 Apple Silicon/Intel 四个固定 appcast 通道，在边缘请求并短时缓存公开 Releases 列表，然后 302 到同域不可变版本化 appcast。
- App 内置 stable feed 改为 Cloudflare 通道；开启预发布检查时只把严格验证过的 `/stable/` 路径派生为 `/preview/`，不再请求 GitHub Releases API。
- preview 通道失败时不回退到较旧 stable 版本，避免把旧正式版误显示为候选；Sparkle 继续负责“有更新”与“已是最新”的判断。
- Preview publication 和 Stable promotion 增加通道最终字节门禁，并为 60 秒边缘缓存保留最长约 120 秒传播窗口。

## 验证

- `swift test --filter UpdateInformationTests`：11 项通过，覆盖 stable/preview、Apple Silicon/Intel、非法 feed fail closed 和本地 UI feed 注入。
- `node --test worker/download-proxy.test.mjs`：13 项通过，覆盖四个通道、403、缺失 feed、非法路径及版本化资产代理。
- `wrangler deploy --dry-run`：通过，仅有既有 Astro tsconfig warning。
- 发布脚本语法检查：通过。
- 生产 Worker 版本 `e68ec356-9d35-439a-aefc-d8ce09712f44`：四个通道均返回 `302 no-store`；stable 两架构指向 `v1.9.18`，preview 两架构指向 `v1.9.20`，最终字节均与对应 GitHub 固定 Tag appcast 一致。

尚未完成：`1.9.20 → 1.9.21` 真实 Sparkle UI 安装、双架构签名公证候选与公开发布验收。自动化和当前通道验证不能替代这些边界。
