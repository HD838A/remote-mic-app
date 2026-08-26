# macOS 公开资产矩阵测试手册

## 适用范围

验证 macOS Preview publication 生成的固定 Tag 资产、appcast 和 CDN 路径。当前公开源码仓库为 HD838A/remote-mic-app；私有 Draft 另走 GetSayAll/SayAll。

## Canonical 资产集合

每个公开 Preview 必须有以下 11 项 payload，另加 1 项 candidate-provenance.json：

| 类别 | 文件 |
| --- | --- |
| Apple Silicon | Remote-Mic-VERSION.zip、Remote-Mic-VERSION.dmg、Remote-Mic-VERSION-Uninstaller.pkg、appcast.xml |
| Intel Ventura | Remote-Mic-VERSION-Intel.zip、Remote-Mic-VERSION-Intel.dmg、Remote-Mic-VERSION-Intel-Uninstaller.pkg、appcast-intel.xml |
| 共享 | Remote-Mic-VERSION.zh.txt、Remote-Mic-VERSION.en.txt、Remote-Mic-VERSION.dmg.sha256 |
| 来源证明 | candidate-provenance.json |

内嵌 Install PKG 保留在对应 DMG 内，不重复作为公开独立资产上传。

## 用例 1：生成与 manifest

1. 从受保护 staging 的 dist 目录运行 scripts/prepare-public-release-assets.sh。
2. 运行 scripts/verify-staged-release-assets.sh。
3. 检查 staged-assets.json。

预期：manifest schemaVersion 为 1，版本/tag/sourceCommit/build 合法，payload 恰好 11 项、名称唯一、无路径分隔符、无 symlink/非普通文件；每项 size 和 SHA-256 与文件完全一致。

失败判定：缺少任一架构、额外文件、重复名称、standalone Install PKG、空 manifest 或摘要不一致。

## 用例 2：appcast 与说明

1. 检查 appcast.xml 引用 Apple Silicon ZIP，appcast-intel.xml 引用 Intel ZIP。
2. 检查两份 appcast 都使用固定 Tag 的 CDN URL，并包含版本、Build 和 Ed25519 签名。
3. 检查共享中英文说明的 URL 和文件名。

预期：不使用 latest-release enclosure URL；两个 appcast 的版本/Build 相同且不会交叉下载错误架构。

## 用例 3：DMG/PKG 静态信任链

对两个架构分别执行：

1. hdiutil verify 和只读挂载。
2. 确认 DMG 根目录只有 Install Remote Mic.pkg。
3. 验证外层 Developer ID Installer、staple、spctl -t install 和内嵌 App/driver 结构。
4. 解压 ZIP，验证 Developer ID Application、Hardened Runtime、Sparkle helper 0755、Versions/Current 符号链接、最低系统和架构。

预期：Apple Silicon 为 arm64/macOS 14，Intel 为 x86_64/macOS 13；安装 PKG 和 DMG 不含不匹配架构或开发机绝对路径。

## 用例 4：GitHub、CDN 和 appcast 字节

1. 从 GitHub fixed-tag URL 下载 11 项 payload。
2. 从 download.sayall.app/mac/releases/TAG/ 下载同名 payload。
3. 对每项执行 SHA-256 和 cmp；对 appcast 再检查 enclosure URL。
4. 检查 releases/latest 仍为 v1.8.3。

预期：本地 staging、GitHub 和 CDN 三方字节完全一致；Preview 不改变稳定 latest。

失败判定：只抽样下载、CDN 缺少新文件、缓存代理返回不同内容、appcast 指向 latest 或 latest 被改动。

版本首次占用检查还必须对上述 11 个 CDN 固定路径执行 HEAD（必要时 Range GET）探测：只有 HTTP 404 算可用，2xx/3xx 算已占用，认证/权限/5xx/超时或未知响应必须 fail closed。

## 用例 5：publication 重试

1. 在上传或 CDN 验证阶段故意制造一次失败。
2. 使用相同 sourceCommit、Run/attempt、artifact digest 和 UI attestation 重试。

预期：只补缺失资产或重新验证；既有资产大小和 digest 不变，不重新签名、不创建新 Tag/版本。

## 稳定功能回归

- candidate-provenance.json 不参与自身 digest 计算，上传后单独校验。
- 下载后的 ZIP/DMG/PKG 必须再次执行签名、公证、权限和结构检查。
- Stable promotion 前后所有资产摘要保持一致。
- Stable promotion 还要从 GitHub API 核对 provenance 绑定的成功 staging Run/attempt、payload artifact 和唯一未过期 Preview stage-record artifact；stage record 必须为 `mode=preview` 并与 Tag、SHA、manifest 和时间戳一致。
- 不合法名称、路径遍历、未知扩展名和缺失架构名称必须被 verifier 拒绝。

## 日志与边界

保存 manifest、文件名、size、SHA-256、HTTP 状态和比较结果；不要保存凭据。自动化矩阵不等于真实安装、卸载、Sparkle UI 或实体硬件验收。
