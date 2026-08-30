# macOS 发布引用与生命周期测试手册

## 适用范围

本手册验证新的 main-based Preview、真实 UI 验收、公开 Pre-release 和 Stable promotion。它不把旧的候选分支或历史 Release 当作新流程入口。

## 测试前准备

1. 在隔离 worktree 执行 git fetch origin main --tags。
2. 确认 main 工作区干净且 HEAD 与 origin/main 完全相同。
3. 动态读取 `releases/latest`，确认其为正式稳定版（非 Draft、非 Pre-release）。
4. 确认 config/release-dependencies.json、Package.swift、Package.resolved 和两个受保护 workflow 的依赖 SHA 一致。
5. 准备临时 fixture；不得读取或打印 Apple、Match、Notary、Sparkle 私钥。

## 用例 1：版本元数据 PR

1. 从 origin/main 创建普通分支。
2. 运行 scripts/prepare-preview-release.sh，传入请求版本、Build 和中英文说明。
3. 检查 git diff --name-only。

预期：只修改 Resources/Info.plist、Resources/en.lproj/ReleaseHistory.md 和 Resources/zh-Hans.lproj/ReleaseHistory.md。版本已被 Tag、Release 或 11 个 CDN 固定路径占用时只递增 patch；只有 CDN HTTP 404 才算可用，未知响应 fail closed。脚本不会创建 Tag、Release 或发布分支。

失败判定：从旧 Tag/旧版本分支开始、修改产品代码、版本因 CI 失败而递增，或 Release Notes 含内部入口/凭据。

## 用例 2：精确 main staging

1. 将元数据 PR 合入 main 并 fetch。
2. 在干净 main worktree 运行 scripts/stage-macos-preview.sh smoke。
3. 检查 workflow 输入和 Run 标题。

预期：只使用 main 的精确 SHA；前置检查包括 main CI、依赖 pin、稳定 latest、11 个 CDN 固定路径全为 HTTP 404 和 GH_TOKEN 静态门禁。workflow 名称为 mac-release smoke <commit>，不创建 Tag/Release。

失败判定：接受 detached/旧 SHA、从功能分支直接签名、找不到 main CI 仍进入 Environment，或 Run 使用隐式 GH_TOKEN。

## 用例 3：受保护 staging 的职责

1. 运行 macOS Signed Release Staging 的 preview 模式。
2. 检查两个架构 Job、artifact 名称和 stage record。

预期：Apple Silicon 与 Intel 都完成签名、公证、staple、Gatekeeper、manifest 和 ZIP/DMG/PKG 校验；上传一个 payload artifact 和一个 stage record；没有 Tag、Release、公开 appcast 或公开资产。

失败判定：只构建一个架构、上传 ad-hoc 包、创建公开身份、重复签名同一 artifact，或把 smoke 当成 Preview 发布。

## 用例 4：真实 Sparkle UI 门禁

1. 使用 prepare-staged-preview-ui-test.sh 恢复指定 Run/attempt/artifact。
2. 从当前 `releases/latest` 下载并验证稳定基线。
3. 启动脚本输出的本地 feed，并使用输出的 `REMOTE_MIC_UI_TEST_MODE=1`、`REMOTE_MIC_UI_TEST_FEED_URL` 和 `REMOTE_MIC_UI_TEST_VERSION` 环境变量直接运行稳定 App；稳定 App 真实执行 check、download、install、首次启动、退出、二次启动。该环境变量只接受 `127.0.0.1` 的 HTTP appcast，默认更新路径仍使用 GitHub Releases API。
4. 使用 record-preview-ui-attestation.sh 和 verify-preview-ui-attestation.sh。

预期：attestation 绑定 source SHA、artifact ID/digest、manifest、两份 appcast、候选 ZIP、安装后版本/Build、Team ID、公证、Gatekeeper、Sparkle helper 0755/链接和无新增崩溃。只运行 probe 或单元测试不能通过。

## 用例 5：幂等 publication

1. 从精确 main worktree 运行 publish-staged-preview.sh。
2. 注入一次 GitHub 上传或 CDN 验证失败。
3. 用同一 attestation 重试。

预期：publication workflow 不读取 Apple 凭据；首次创建或复用 exact Tag 和 Pre-release，只上传缺失且摘要匹配的 11 项 payload 与 provenance。重试不重签、不升版本、不创建新分支；已有不同字节时 fail closed。

## 用例 6：Stable 只改分类

1. 选择已发布且已验证的 Pre-release Tag。
2. 运行 promote-preview-release.sh。
3. 比较晋升前后的全部资产名称、大小和 digest。

预期：确认 Tag Commit 已进入 origin/main，并通过 GitHub API 核对 provenance 对应的成功 protected Run/attempt、payload artifact 和 `mode=preview` stage record 后，只修改 Release 的 prerelease/latest 分类；资产、Tag、appcast 和 provenance 字节不变。

失败判定：选择 Draft/不存在的 Release、Tag 未进入 main、触发构建/签名/上传或替换资产。

## 用例 7：同 SHA 故障恢复

1. 在 staging 或 publication 中模拟 Runner、GitHub 或网络失败。
2. 用同一个 main SHA、版本、Build 和 artifact 身份重试。

预期：只新增 workflow Run；不升版本、不创建 rerun/canary 分支、不创建第二个 PR/Tag，成功的签名字节被复用。

## 稳定功能回归

- stable latest 在 Preview 前后仍为发布前动态记录的同一正式版本。
- 公开 Preview 保持 Pre-release，不触发 Stable workflow。
- Private Draft 只写入 GetSayAll/SayAll，不污染公开源码仓库。
- 两架构资产和固定 Tag URL 完整，11 项 payload 加 provenance 的摘要一致。
- 所有调用 gh 的 workflow step 都显式设置 GH_TOKEN。

## 日志与边界

保存 source SHA、Run/attempt、artifact ID/digest、manifest、attestation、下载比较和失败类别；不要保存秘密值。受保护签名、公证、真实 UI、实体遥控器和第三方 App 的真实验收结果必须分别标记，自动化 fixture 不能冒充真机结论。
