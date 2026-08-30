# macOS 发布流程

本流程适用于无线麦SayAll.app 的公开 macOS Preview 和 Stable。当前会话是唯一的发布协调者；不依赖名为“SayAllMac发布管理”的固定命令或任务。

## 合法目标与不变量

- Preview：从已经合入 origin/main 的精确 SHA 构建一次，完成真实 UI 升级后发布一个公开 Pre-release。
- Stable：用户明确指定一个已经发布并验证通过的 Pre-release，将它改为正式版；不重新构建。
- 私有内部 Draft：使用 private-draft-release skill 的独立路径，目标仓库固定为 GetSayAll/SayAll，不在公开源码仓库创建内部 Draft。
- “发布正式版”不是独立构建命令。没有指定现有 Pre-release 时，只能准备 Preview 或报告缺少授权。
- stable latest 不写死版本号。Preview 开始前、公开后和失败恢复前后都必须动态读取 `releases/latest`，确认其为正式稳定版且前后一致；流程不得修改 stable feed。

发布流程只保留一个版本元数据 PR、一次受保护 staging、一次真实 Sparkle UI 验收和一个无 Apple 凭据 publication workflow。没有 release/pre-* 候选分支、qualification、Release Guard、编号 rerun、watchdog 或 SLO ledger 状态机。

## 发布前准备

1. 记录用户请求时间 request_started_at 和 request_id。T_ready 表示所有代码已合入主线、主线 CI 和依赖 pin 已通过、版本/Build/Release Notes 已冻结的时刻；Preview 和 Stable 从 T_ready 起均以 30 分钟为纯发布目标。重试不重置时间，也不以时间目标替代签名、公证、staple 或 UI 验收。
2. fetch origin main，确认发布 worktree 干净，main 与 origin/main 精确一致。发布不得从其他脏 worktree、旧 Tag 或旧预览包开始。
3. 检查产品 Commit 已经通过普通 PR 合入 main。若用户指定 Commit 尚未合入，先在独立集成分支重放指定改动，逐个解决机械冲突，完成普通 PR、双架构 CI 后再继续；冲突涉及产品取舍时报告并暂停该取舍，不接触 Apple 凭据。
4. 检查 config/release-dependencies.json、Package.swift、Package.resolved 和受保护 workflow 使用相同的完整依赖 SHA；运行 scripts/verify-release-dependency-pins.sh。
5. 运行 scripts/verify-release-ready-main-ci.sh，确认 Apple Silicon 与 Intel Ventura 的 main push CI 都完成 Swift tests、项目 self-test 和 Release build。发布控制面 fixture 不得冒充产品 CI。

## Preview 版本元数据

版本元数据必须通过普通 PR 合入 main：

1. 从最新 origin/main 创建普通开发分支和隔离 worktree。
2. 准备中英文 ReleaseHistory、Info.plist 的 CFBundleShortVersionString 和 CFBundleVersion：

   scripts/prepare-preview-release.sh <requested-version> <build> <zh-notes> <en-notes>

3. 脚本只修改这三个文件，并检查 Release Notes 不含内部入口、邀请码、凭据或实现细节。若 Tag、Release 或公开分发资产已经占用请求版本，只递增最后一位并选更高 Build；公开资产占用检查覆盖 11 个 CDN 固定路径，只有 HTTP 404 才算可用，2xx/3xx 视为占用，认证、权限、5xx、超时或其他未知响应 fail closed。单纯的 CI、Runner、GitHub、Apple 或网络故障不占用版本，不得升版本。
4. 运行 git diff --check、Swift/脚本测试和必要的 UI/功能测试，创建普通 PR 合入 main。合入后重新 fetch，记录用于 staging 的精确 main SHA。

元数据 PR 合入后不再创建版本候选分支，也不在发布分支上回流或重写版本文件。产品内容变化必须回到普通产品 PR；公开身份产生后不能覆盖旧 Tag 或资产。

## Preview staging：受保护的唯一签名入口

从与 origin/main 相同的 main worktree 执行：

    scripts/stage-macos-preview.sh preview

脚本先做无秘密检查：main 精确 SHA、版本/build、stable latest、main CI、依赖 pin、目标仓库、显式 GH_TOKEN 静态门禁和 11 个 CDN 固定路径全部为 HTTP 404，然后 dispatch .github/workflows/mac-release-package.yml，输入只有 mode 和 expected_commit。smoke 只用于受保护流程检查，不创建公开身份。

受保护 workflow 的 package job 才能读取 Apple/Match/Notary/Sparkle 凭据，并且必须：

- 在 mac-release Environment 内使用只读 Match、隔离临时 Keychain 和最小权限；
- 独立构建 Apple Silicon/macOS 14 与 Intel Ventura/macOS 13 两条 lane；
- 对 App、Framework、XPC、Helper、Installer、DMG 和 ZIP 完成 Developer ID 签名、Apple 公证、staple、Gatekeeper 和权限/符号链接校验；
- 使用独立 SwiftPM scratch/output，独立提交可并行的 PKG 公证；
- 生成 canonical public bundle、staged-assets.json 和 stage record；
- 上传不可变 payload artifact 与 stage record；
- 不创建 Tag、GitHub Release、appcast 公开地址或任何产品分支。

签名阶段内部 supervisor 540 秒，GitHub step 硬上限 600 秒。超时只终止本次阶段并保留第一份错误日志；不静默重打或以升版本掩盖基础设施故障。

## 真实 Sparkle UI 验收

受保护 staging 成功后，在公开 Tag/Release 建立前执行：

1. scripts/prepare-staged-preview-ui-test.sh 下载指定 Run、attempt 和 artifact ID，不使用 latest artifact；默认动态读取当前 `releases/latest` 作为稳定基线，也可设置 `PREVIEW_UI_BASELINE_TAG` 指定已发布的正式版本进行本地验收。
2. 用本地固定 feed，只把生产 appcast 的不可变 URL 前缀替换为本地地址，确保 enclosure 是 staging 的同一 ZIP。
3. 使用低于候选版本的基线 App 的真实 Sparkle UI 完成 check、download、install、首次启动、退出和二次启动；验证版本/Build、Team ID L3QHLDRPAY、公证、Gatekeeper、Sparkle helper 的 0755 权限和 Versions/Current 链接。该基线只在本地受保护 UI 验收中使用，不改变稳定 feed 或公开分类。
4. 检查没有新增崩溃报告、应用可以再次启动，并用 scripts/record-preview-ui-attestation.sh 生成结构化证明。仅运行 Sparkle CLI probe、单元测试或静态解压不能替代真实 UI 安装；该步骤未完成时不得公开 Preview。
5. scripts/verify-preview-ui-attestation.sh 必须重新核对 stage record、manifest、production/test appcast 摘要和安装结果。

## Preview publication：无 Apple 凭据

在真实 UI attestation 通过后，从精确 origin/main 的干净 worktree 执行：

    scripts/publish-staged-preview.sh <preview-ui-attestation.json>

它只 dispatch .github/workflows/mac-preview-publication.yml。该 workflow：

- 只在 main 上运行，显式配置 GH_TOKEN，不声明 mac-release Environment，不读取 secrets；
- 目标仓库固定为 `HD838A/remote-mic-app`，并 checkout 触发事件的精确 `github.sha`，不在运行中跟随会变化的 `main`；
- 按 Run/attempt/artifact ID 下载并验证同一 staged payload；
- 创建或复用与 source SHA 完全一致的轻量 Tag；
- 创建或恢复公开 Pre-release，上传 manifest 中的完整 11 项 payload 加 candidate-provenance.json；
- 对已有资产做大小和 GitHub digest 比较，只补缺失项，发现字节不同即 fail closed；
- 若远端 Tag 尚不存在，创建 Tag 前最后一次确认该版本的 11 个 CDN 固定路径全部返回 HTTP 404；任一已占用或未知响应都不创建 Tag。已有 Tag 的幂等恢复跳过占用检查，继续执行固定 Tag/CDN 字节复验；
- candidate-provenance.json 的 `stagedAt`/`publishedAt` 固定取受保护 staging 的时间戳；重试同一 staging 身份不会因当前时间变化而生成不同字节；
- 从 GitHub 固定 Tag URL 和 download.sayall.app 固定 Tag URL 下载每项公开资产并逐字节比较；
- 确认 releases/latest 仍指向发布前记录的正式稳定版，且 Release 为非 Draft、非 Pre-release。

publication 失败时先查询远端状态。若 Tag、Release、资产和摘要已经正确，只重做缺失的公开验证；不要删除 Release、移动 Tag、重签名或重复上传不同字节。公开 Pre-release 的标题和正文与本次候选不一致时也必须 fail closed，不能在重试中覆盖 Release Notes。任何 Tag/Release 查询的认证、网络或非 404 错误都必须 fail closed，不能被当作“版本可用”。

## Stable promotion

只有用户明确给出要晋升的现有 Pre-release Tag（例如 v1.9.11）时才执行：

    scripts/promote-preview-release.sh v1.9.11

脚本和 mac-stable-promote.yml 必须先确认：

- Release 存在且当前是公开 Pre-release；
- candidate-provenance.json、Tag Commit 和 source Commit 一致；
- Tag Commit 已包含在当前 origin/main；
- 11 项 payload 与 provenance 的大小、SHA-256、GitHub digest 完全一致。
- provenance 中的 sourceRunId/sourceRunAttempt 指向成功的 `.github/workflows/mac-release-package.yml` `workflow_dispatch` Run，且 `head_branch=main`、`head_sha=sourceCommit`、attempt 完全一致；signedArtifactId/digest 指向同一 Run 的未过期 payload artifact，另有唯一未过期的 Preview stage-record artifact，记录 `mode=preview` 并与 provenance 的 Run、artifact、manifest、Tag 和时间戳一致。
- 目标仓库固定为 `HD838A/remote-mic-app`，并使用 dispatch 事件的精确 `github.sha`；若 main 在 dispatch 后前进则 fail closed，重新从最新 main 发起晋升。

随后唯一的远端突变是 gh release edit --prerelease=false --latest。Tag、Release Notes、appcast、ZIP、DMG、PKG 和 provenance 均保持原字节；晋升不重新构建、签名、公证、staple 或上传。若上一次突变已成功且该 Tag 已是 `releases/latest`，重试只做完整只读复验，不再次突变；所有候选晋升共享一个并发锁，并在突变前再次核对 stable latest。

## 故障分类与重试

| 故障 | 处理 |
| --- | --- |
| 产品代码或版本输入未就绪 | 回到普通 PR 和 main CI，不能先进入 mac-release Environment |
| Runner、GitHub、Apple、网络或审批失败，尚无公开身份 | 在同一 main SHA、版本、Build 上重试同一 stage；复用成功 artifact |
| staging 已成功，UI 或 publication 失败 | 保留 artifact，修复对应控制面后重新验证；不重签、不升版本 |
| Tag/Release/公开资产已存在且内容需要改变 | 新建普通产品/元数据 PR，选择新的可用版本和更高 Build；旧身份不可修改 |
| stable promotion 条件不满足 | 保持 Pre-release，报告精确缺口；绝不从 main 重建正式包 |

## 发布后报告

报告 source Commit、版本、Build、两个架构、Run/attempt/artifact ID 与摘要、测试结果、签名/公证/下载字节验证、Sparkle UI 证明、Release 状态和 stable latest。分别报告从 request_started_at 到结果的总耗时，以及从 T_ready 起的 Preview/Stable 纯发布耗时；说明任何未执行的真实硬件、第三方 App 或可见 UI 验收。不得在日志、提交、Release Notes 或聊天中输出证书、私钥、密码、P8、Match 凭据或 Token。
