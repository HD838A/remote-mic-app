# macOS 公开资产矩阵测试手册

## 适用范围

验证 macOS Preview publication 生成的固定 Tag 资产、appcast 和 CDN 路径。当前公开源码仓库为 HD838A/remote-mic-app；私有 Draft 另走 GetSayAll/SayAll。

## Canonical 资产集合

每个公开 Preview 必须有以下 10 项 payload，另加 1 项 candidate-provenance.json：

| 类别 | 文件 |
| --- | --- |
| Apple Silicon | SayAll-VERSION-BUILD.zip、SayAll-VERSION-BUILD-AppleSilicon-install.pkg、SayAll-VERSION-BUILD-AppleSilicon-uninstall.pkg、appcast.xml |
| Intel Ventura | SayAll-VERSION-BUILD-Intel.zip、SayAll-VERSION-BUILD-Intel-install.pkg、SayAll-VERSION-BUILD-Intel-uninstall.pkg、appcast-intel.xml |
| 共享 | SayAll-VERSION-BUILD.zh.txt、SayAll-VERSION-BUILD.en.txt |
| 来源证明 | candidate-provenance.json |

Install PKG 作为 SayAll 品牌的公开独立资产上传。公开下载不再提供 DMG。

## 用例 1：生成与 manifest

1. 从受保护 staging 的 dist 目录运行 scripts/prepare-public-release-assets.sh。
2. 运行 scripts/verify-staged-release-assets.sh。
3. 检查 staged-assets.json。

预期：新 manifest schemaVersion 为 2，版本/tag/sourceCommit/build 合法，payload 恰好 10 项、名称唯一、无路径分隔符、无 symlink/非普通文件；每项 size 和 SHA-256 与文件完全一致。

失败判定：缺少任一架构、缺少独立 Install/Uninstall PKG、出现 DMG、额外文件、重复名称、空 manifest 或摘要不一致。

## 用例 2：appcast 与说明

1. 检查 appcast.xml 引用 Apple Silicon ZIP，appcast-intel.xml 引用 Intel ZIP。
2. 检查两份 appcast 都使用固定 Tag 的 CDN URL，并包含版本、Build 和 Ed25519 签名。
3. 检查共享中英文说明的 URL 和文件名。

预期：Appcast XML 可以解析。两个 Appcast 的版本、Build、ZIP 长度和签名格式符合 manifest。下载地址使用固定 Tag 和对应架构的 `SayAll-*` ZIP。两份说明地址使用共享的 `SayAll-*` 文件。

失败判定：旧名称、错误架构、错误域名、错误长度、错误版本、缺失签名或无效 XML。注释中出现正确名称不能代替正确下载地址。

历史兼容：manifest schema 1 和 provenance schema 5 保留旧的混合命名；provenance schema 4 保留旧的 11 项资产。新 manifest 使用 schema 2，新 provenance 使用 schema 6。历史候选的文件和摘要保持原值。

## 用例 3：PKG 静态信任链

对两个架构分别执行：

1. 验证 Installer PKG 的 Developer ID Installer、staple、spctl -t install 和内嵌 App/driver 结构。
2. 解压 ZIP，验证 Developer ID Application、Hardened Runtime、Sparkle helper 0755、Versions/Current 符号链接、最低系统和架构。

预期：Apple Silicon 为 arm64/macOS 14，Intel 为 x86_64/macOS 13；安装 PKG 不含不匹配架构或开发机绝对路径。

## 用例 4：GitHub、CDN 和 appcast 字节

1. 从 GitHub fixed-tag URL 下载 10 项 payload。
2. 从 download.sayall.app/mac/releases/TAG/ 下载同名 payload。
3. 对每项执行 SHA-256 和 cmp；对 appcast 再检查 enclosure URL。
4. 检查 releases/latest 仍为发布前动态记录的同一正式稳定版本。

预期：本地 staging、GitHub 和 CDN 三方字节完全一致；Preview 不改变稳定 latest。

失败判定：只抽样下载、CDN 缺少新文件、缓存代理返回不同内容、appcast 指向 latest 或 latest 被改动。

版本首次占用检查还必须对上述 10 个 CDN 固定路径执行 HEAD（必要时 Range GET）探测：只有 HTTP 404 算可用，2xx/3xx 算已占用，认证/权限/5xx/超时或未知响应必须 fail closed。

## 用例 5：publication 重试

1. 在上传或 CDN 验证阶段故意制造一次失败。
2. 使用相同 sourceCommit、Run/attempt、artifact digest 和 UI attestation 重试。

预期：只补缺失资产或重新验证；既有资产大小和 digest 不变，不重新签名、不创建新 Tag/版本。

## 用例 6 私有实现内容检查

1. 执行 `python3 scripts/test-private-platform.py`，覆盖 ZIP、嵌套 ZIP 与真实 PKG payload 的拒绝样本。
2. 对最终公开资产目录执行 `scripts/verify-staged-release-assets.sh`，确认内容检查发生在 Artifact 上传之前。
3. 在独立合成 fixture 中分别放入 Swift 源码、开发接口、原始 XCFramework、dSYM、日志、凭据样本和本机路径。
4. 使用同一 verifier 恢复候选资产，复验 manifest、字节和内容。

预期为所有禁止内容在上传前被拒绝。公开 Sentry SDK 中经过批准的构建路径和安装脚本的动态用户路径可通过。错误日志只记录拒绝结果，原始文件名和内容留在受控调查环境。

失败条件为只扫描归档外层、安装器 payload 未展开、额外归档未检查，或内容拒绝后仍继续上传。

阶段诊断同时验证生产签名 shell 片段。子进程分别成功退出、以非零码退出、超时和取消，公开输出应保留 supervisor 的阶段与原始结果。向子进程 stdout 写入 canary 和相似的阶段文本，确认这些内容保存在详细日志中。对两架构并行追加状态及同目录重试做回归，异常状态文件应输出通用失败标记。

## 用例 7 公开与官方构建权限

1. 清空私有凭据和私有 Package 路径，执行完整 Swift 测试、两个架构 Release build 和普通 App 打包。
2. 检查默认公开打包使用兼容层，过程只访问公开依赖。
3. 在合成 fixture 中将官方附件读取凭据置空，运行 staging 的实际准备片段。
4. 分别提供错误 Tag Commit、非主线 Tag、来源不一致的 provenance 与损坏摘要。
5. 在私有仓库或维护者本机执行相同宿主 SHA 与清单 Tag 的免费、付费宿主集成测试及双架构构建。

预期为公开路径独立通过，官方错误输入在构建和上传前停止。分发渠道传入源码路径或尚未具备二进制协议的 AI 组件时停止。

失败条件为公开路径访问私有资源、官方缺件退回公开包、缺少凭据后编译私有源码，或将私有源码和详细编译日志写入公开工作流。

## 稳定功能回归

- candidate-provenance.json 不参与自身 digest 计算，上传后单独校验。
- 下载后的 ZIP/PKG 必须再次执行签名、公证、权限和结构检查。
- Stable promotion 前后所有资产摘要保持一致。
- Stable promotion 还要从 GitHub API 核对 provenance 绑定的成功 staging Run/attempt、payload artifact 和唯一未过期 Preview stage-record artifact；stage record 必须为 `mode=preview` 并与 Tag、SHA、manifest 和时间戳一致。
- 不合法名称、路径遍历、未知扩展名和缺失架构名称必须被 verifier 拒绝。

## 日志与边界

保存 manifest、文件名、size、SHA-256、HTTP 状态和比较结果；不要保存凭据。自动化矩阵不等于真实安装、卸载、Sparkle UI 或实体硬件验收。
