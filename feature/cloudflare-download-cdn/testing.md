# 验证记录

当前状态：Worker 与官网生产验证完成，等待统一 Mac 预览版集成和候选发布验证。

自动化和人工测试步骤统一记录在 [Testing/CloudflareDownloadCDN.md](../../Testing/CloudflareDownloadCDN.md)。

## 已完成验证

- `sayall-download` Worker 单元测试：7/7 通过；Wrangler dry-run 通过，生产 Worker 版本为 `7e9c4426-96ef-4c1b-8aa3-8856c895c433`。
- Astro 生产构建通过，共生成 4 个页面；Cloudflare Pages 生产部署为 `https://dd76e014.8586ai.pages.dev`，`sayall.app` 与英文、历史页面均可访问。
- 生产中文、英文首页分别发现 5 个 `https://download.sayall.app/mac` 链接，两个历史页面分别发现 2 个；`www.sayall.app`、`8586ai.com` 与 `www.8586ai.com` 均 301 到主域。
- 固定入口 302 到当前正式版 `v1.8.3` 的同域名版本化 DMG；版本化 `HEAD` 连续 5 次返回 200，`Range: bytes=0-1023` 返回 206 和 1024 字节。
- `Remote-Mic-1.8.3.dmg` 从 GitHub 和 CDN 下载后逐字节一致，SHA-256 均为 `00ed41f584a7e44a11dd5c675ca06bff888faa716fbc26f33bc1f74e55fd3c23`。
- 公开仓库发布脚本语法检查与 `BuildSigningTests` 7/7 通过；完整 `swift test` 为 208/208，`scripts/test.sh` 自检为 42/42。
- 使用独立 SwiftPM scratch path 加载私有硬件模拟器，完整测试为 224/224，包含 RC001/RC003 直接语音流、12 个原始按键、36 个手势、7 个连发场景、分片、同步、异常、重连和双设备隔离。
- `scripts/build-app.sh` 完成 Release 配置的 ad-hoc App 构建，`scripts/verify-app.sh`、本地化资源检查和严格 codesign 验证通过；该产物不是候选安装包，也未执行 Developer ID 签名或公证。

## 尚未完成边界

- 本功能分支不独立修改版本号、建立 Tag、创建 Release、生成候选 appcast 或合并 `main`；这些步骤由统一 Mac 预览版流程完成。
- 候选 ZIP、PKG、DMG、SHA256、appcast、中英文更新说明和 provenance 尚未完成 GitHub/CDN 全资产字节回验。
- Sparkle enclosure 签名、从当前正式版发现候选、最终 ZIP 无人值守启动、PKG 等价性与 UI 驱动安装尚未执行。
- 不同国家、运营商、企业代理、跨网络断点续传和长期缓存命中率仍属于真实用户环境验收范围。
