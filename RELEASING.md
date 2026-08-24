# macOS 发布主管与分支规范

## 发布主管职责与合法命令

- 无线麦SayAll.app 的每个 macOS 公开版本都由当前获得用户明确授权、并通过会话身份与工作目录校验的发布会话执行；不依赖名为“SayAllMac 发布管理”的固定任务。发布主管负责从用户指定的 Commit、分支或最新 `origin/main` 完成发布就绪整合、候选发布、公开字节验证和结果汇报。
- 合法的公开发布命令只有两类：发布一个新的 Pre-release；或将用户明确指定的现有 Pre-release `vX.Y.Z` 晋升为正式版。
- “发布正式版”不是合法命令。正式版不能凭空构建或发布，只能由已经发布并完成候选验证的指定 Pre-release 晋升产生。
- 正式晋升必须复用该 Pre-release 的同一 Tag、Tag Commit、`candidate-provenance.json` 和全部已验证资产；不得重新构建、重新签名、重新公证、替换资产或移动 Tag。
- 当前受审的稳定 `latest` 基线是 `v1.8.3`。每次 Preview 在凭据前、Release 创建或恢复前以及公开字节验证完成后都必须精确校验该值；“执行前后没有变化”不能替代对正确基线的校验。未来成功晋升新的正式版时，必须在独立普通 PR 中同步更新这项受审基线后，才能发布下一个 Preview。
- 发布请求指定的产品 Commit 或分支尚未进入 `origin/main` 时，发布主管从最新 `origin/main` 建立独立集成分支，只重放指定工作及必要依赖，通过普通 PR 和必需检查合入；发生会改变产品意图或丢失行为的冲突时才请求用户决策。
- 同时收到的新需求或 Bug 调查交给有边界的 subagent；发布主管保留发布主线、凭据边界和最终决策，并汇总 subagent 的证据、改动、验证和 Commit。

## 分支职责

- 功能、修复和用户可见文案先通过 Pull Request 合入 `main`。
- 每个预览版本只使用一个 `release/pre-vX.Y.Z` 分支、一个当前冻结的 exact SHA 和一个跟随该分支当前 head 的 Draft 回流 PR。分支只是当前 active attempt 的唯一协调 ref；候选 SHA、Run、attestation 和最终资产才是不可变证据。不得创建 `-rerun*`、`-canary-*` 或其他相同内容的版本候选别名分支，也不得为同一版本创建第二个回流 PR。
- 首个候选 attempt 必须从创建时最新 `origin/main` 创建，只允许包含版本号、Build、对应版本历史和测试手册目标版本等发布元数据。创建后冻结 `baseMainCommit`、候选 SHA、版本、Build、Release Notes 和发布流水线 digest。
- 不得在候选分支直接开发功能、合入其他开发分支或混入尚未验收的工作树内容。
- 同一 SHA 发生基础设施、Runner、审批、Apple、GitHub 或 CDN 失败时，只能在同一分支和 Draft PR 上重试同一 attempt；候选 SHA、版本、Build、`request_id` 和该 attempt 的 `release_ready_at` 均不得改变。
- 只有候选内容、基线或制品闭包确实变化时，才能结束旧 attempt，并在同一版本分支和同一 Draft PR 上建立新 SHA 的 replacement attempt。该版本分支仍只保留一个直接位于冻结 base 之后的 metadata-only candidate Commit；更新前必须核对远端 head 等于预期旧 SHA，并使用显式 compare-and-swap / `force-with-lease` 等受控更新。不得普通 force-push，也不得并存第二个 active 候选分支或 PR；旧 SHA、Run、attestation 和失败原因必须保留。
- 冻结后 `main` 可继续前进。候选的签名/打包制品闭包由原始 attestation 和候选 digest 固定；只要 `baseMainCommit` 仍是当前 `origin/main` 的祖先，候选仍有效。仅影响恢复、Release/API 编排、SLO/watchdog、provenance 读取或公开字节协调的控制面修复，不改变已签名制品，也不要求 replacement candidate、双架构产品 CI 或 protected qualification。
- 发布流水线资格验证只适用于会改变 App/PKG/DMG 生成、签名、公证、Sparkle 元数据、制品清单或最终字节验收闭包的变更。恢复控制面变更必须通过普通 PR、单机 macOS 静态/fixture 测试和主线保护检查；`resume-preview` 只验证原始候选的历史 pipeline digest 与签名 artifact，不得要求当前 main 为该 digest 重新生成 qualification artifact。资格证明按制品闭包 digest 复用，不依赖恢复脚本的每次修复，也不创建版本候选、Tag、Release、appcast 或产品分发资产，也不占用版本或 Build。
- 候选分支在正式晋升完成前必须保留在远端，供来源校验、自动合并和 Release 守卫使用。

## 发布交接清单

用户发出发布指令时立即记录唯一的 `request_started_at` 和 `request_id`，两者在整个用户请求期间不得重置。每个候选 SHA 是一个独立 attempt；当该 SHA 的冻结 `baseMainCommit` 双架构 CI、exact-SHA 候选门禁、当前 pipeline digest 资格证明以及版本、Build、Release Notes 全部完成时，将这些可信时间的最大值冻结为该 attempt 的 `release_ready_at`。同 SHA 的任何重试不得重置该时间；只有内容变化形成新 SHA 的 replacement attempt 才会在其自身门禁完成后冻结新的 `release_ready_at`。`request_started_at` 继续统计完整用户等待；Preview 和正式晋升的每个 ready attempt 都从各自 `release_ready_at` 起使用 30 分钟纯发布窗口。

- 计划发布的产品 Commit 已经 Push，并通过 PR 合入 `origin/main`。
- `mac-ci.yml`、`mac-preview-candidate.yml`、`mac-release-package.yml` 中 SayAllAI、SayAllMacroPlatform、SayAllMacRemote 均钉定同一组完整 40 位 Commit。
- 私有依赖 Commit 已经 Push，发布 workflow 的只读部署密钥能够获取这些 Commit。
- 候选冻结的 `baseMainCommit` 已有成功 macOS 双架构 CI 证明；若用户指定的产品 Commit 尚未合入，发布主管必须先在独立开发集成分支完成普通 PR 和必需检查，期间不得创建候选或接触 Apple 发布凭据。

任一条件不满足时，状态是“发布就绪整合中”或“尚未发布就绪”。发布主管应继续完成已获授权且可机械解决的集成工作；不得先创建候选再边发布边补代码。只有需要产品取舍、缺少必要权限或无法从现有证据安全解决时才停止并请求用户决策。

## 任务编排与耗时门禁

- 分析请求只做只读诊断并给出结论，不自动扩大为实现、加固或发布。请求同时包含分析和实施时，先在 3–5 分钟内回报阶段结论、改动范围和预计门禁，再开始修改；额外优化必须拆成独立任务，不能静默扩大当前范围。
- 委派任务连续 2 分钟没有工具活动、消息或可验证进展时，主会话必须主动检查；满 3 分钟仍无进展时立即中断并接管或重新委派。CI 已结束时，负责会话应在 30 秒内回报，不得等待下一次用户追问。
- 禁止使用交互式 `gh run watch` 等无法可靠收回控制权的等待方式。统一使用 `gh run view`、GitHub API 或等价的单次状态查询，轮询间隔限定为 30–60 秒，并在开始等待前声明总截止时间；达到截止时间后立即报告当前 Job、阶段和已耗时，不得无限等待或无提示自动重试。
- 普通非发布任务在必需的 PR 检查通过并完成普通合并后即可交付；合并后的 `main` CI 默认作为异步确认，不阻塞首轮回复，但必须保留 Run URL，并在失败时立即回报。修改 CI 门禁本身、共享发布脚本或用户明确要求验证 `main` 时，仍需等待对应 `main` 检查通过。
- 真实发布不得套用上述异步边界。候选 CI、PR 必需检查、Environment 审批、真实签名与公证、公开 GitHub/CDN 字节验证、Release Guard 和候选回流必须按发布流程全部完成后，才能报告发布完成。
- 每个真实发布必须把用户指令到达时的 Unix epoch 秒作为 `request_started_at` 传入 workflow，并生成可下载的 TSV 阶段账本。账本至少记录候选门禁、Environment/Runner 等待、签名与公证、发布和 GitHub/CDN 公开字节验证；失败必须分类为开发未就绪、审批等待、Apple/GitHub/CDN 外部等待或成功流水线时间，禁止从 Commit 或 CI 开始时间替代用户墙钟。任何 workflow step 只要调用 `gh` 或 GitHub API，都必须在该 step 显式设置 `GH_TOKEN: ${{ github.token }}`，不能依赖 Runner 的隐式环境；该门禁必须在进入 `mac-release` Environment 或读取 Apple 凭据前完成，并由无秘密静态测试覆盖。
- 当前授权发布会话收到指令后的第一项动作必须记录 `request_started_at` 和 `request_id`，并准备不依赖 GitHub Hosted Runner 的发布机 watchdog；在当前 attempt 的 `release_ready_at` 冻结后立即启动 30 分钟纯发布监管。Preview 和正式晋升都使用 `release_ready_at + 1740 秒` 的内部截止，为最终回报保留 60 秒；同 SHA 的重试、重新 dispatch 或代理接管均不得重置时间戳。候选内容变化时必须先明确结束旧 attempt，新 SHA 使用同一 `request_id` 和原始 `request_started_at`，但在自身门禁通过后产生新的 attempt attestation 和 `release_ready_at`。每次 Push/dispatch 得到的精确 workflow run ID 必须追加到对应 attempt 且属于本请求的 JSONL manifest。发布完成标记必须是包含 `mode`、`requestId`、`target`、`requestStartedAt`、`releaseReadyAt` 和 `status: published-and-verified` 的 JSON，不得使用空文件或复用其他请求/候选 SHA 的完成标记。发布机应使用 `scripts/release-user-wall-watchdog.sh preview|stable`，传入时间戳、候选分支或 Tag、完成 JSON 路径和 JSONL manifest；manifest 每行至少记录 `requestId`、`runId`、`workflow`、`headSha`、`headBranch`、`target`，且只登记当前 attempt 创建的 Run。GitHub 内 watchdog 只是同队列中的防御层，不能替代发布机 watchdog。
- 硬指标：Preview 和正式晋升从 `release_ready_at` 起均须在 30 分钟内成功或明确失败。达到内部 29 分钟截止仍未完成时，watchdog 必须取消本次登记的 Run 并明确失败，不得盲目重试、延长签名门限或继续静默等待。`request_started_at` 到最终结果的总耗时必须完整汇报，但不会截短尚未开始的 30 分钟纯发布窗口。
- Preview 优化目标继续保持候选元数据尽快完成、双架构签名与公证并行、GitHub/CDN 公开验证并行；这些是缩短发布时间的目标，不再构成额外的更短硬取消条件。签名 composite step 继续保留 10 分钟硬限，内部 supervisor 限 540 秒；publication supervisor 限 180 秒。

## 发布控制面快速路径

- 发布控制面包括恢复已签名 artifact、生成/校验 provenance、GitHub Release/Tag/API 操作、SLO ledger、watchdog、Release Guard 和公开字节协调；这些步骤不得重新构建、签名、公证或修改制品字节。
- 仅修改控制面脚本和对应 fixture/静态测试时，PR 使用 `release-control-plane-only` CI 快速路径：一次 macOS shell/fixture 测试即可，不启动 Apple Silicon/Intel Swift 双架构矩阵，不进入 `mac-release` Environment。
- 控制面 PR 合入 `main` 后，可以直接恢复同一候选 SHA、同一 Tag、同一签名 artifact 和同一 request ID；不得因为控制面 digest 变化而新建 qualification ref、重新签名或提高版本号。
- 如果控制面改动触及 `package-macos-release*`、签名/公证、DMG/PKG、Sparkle appcast、制品清单或改变签名/来源信任边界的 verifier，必须重新归类为制品闭包变更，恢复快速路径立即失效并按完整 qualification 处理。只读取既有已签名资产、校验版本/摘要/公开下载字节的 verifier 修复，仍属于控制面，但必须用固定 signed-artifact fixture 覆盖。

## 预览候选流程

1. 将计划发布的功能通过 PR 合入 `main`，等待 macOS CI 通过。
2. 计算制品闭包 digest。若已有同 digest 的成功受保护资格证明，直接复用。只有影响 App/PKG/DMG 生成、签名、公证、Sparkle 元数据、制品清单或最终字节验收的流水线变更，才在其普通 PR 合入 `main` 前，将该 PR exact SHA 临时映射为 `release/pipeline-qualification/<pr号或短SHA>` ref，并执行 `release_mode=qualification`；不得为 alias 再建 PR。恢复/Release/API/SLO 控制面变更走单机 macOS fixture 快速路径，不进入该 Environment。资格验证使用真实 Developer ID/Notary 路径，但只上传按 digest 命名的资格证明和必要的无敏感账本，不创建版本候选、Tag、Release、appcast 或产品分发资产。普通 PR 合入后，产品候选 verifier 还必须通过原 PR ref 重算制品闭包 digest，确认资格证明精确覆盖当前流水线。
3. 从当时最新 `origin/main` 创建唯一 `release/pre-vX.Y.Z` 分支，只修改 `Resources/Info.plist`、中英文 `ReleaseHistory.md`，以及确有必要的 `Testing/*.md` 目标版本。候选必须是冻结 `baseMainCommit` 之后的单个 metadata-only Commit，并冻结 exact SHA、版本、Build、Release Notes 与 pipeline digest。
4. Push 候选后立即运行 `scripts/prepare-preview-recording-pr.sh`，只创建一个指向 exact SHA 的 Draft 回流 PR。`macOS Preview Candidate` 与 Draft PR CI 可同时运行；两者在严格 metadata-only 时复用冻结 `baseMainCommit` 已通过的 Apple Silicon/Intel Swift tests、项目自检和 Release build 证明，不重复编译同一产品代码。产品代码、依赖、workflow、entitlements 或打包差异必须返回开发，不得以 fast path 发布。
5. Preview 候选结构检查和 Draft PR CI 可并行；受保护签名、公证与公开 Preview 发布不能与它们并行。只有 exact SHA、唯一 Draft PR、两个架构必需检查、冻结 base 的 main CI 以及当前 digest 资格证明全部成功后，才能冻结该 attempt 的 `release_ready_at` 并进入 `mac-release` Environment。
6. 从同一候选分支和 exact SHA 运行 `macOS Signed Release Packages`，使用 `release_mode=preview`，显式传入 exact commit、pipeline digest、最初 `request_started_at` 和不可变 `request_id`。若 `main` 已前进，必须证明 `baseMainCommit` 仍是当前 main 的祖先且 pipeline digest 未变；否则结束当前 attempt 并建立 replacement attempt。
7. 同 SHA 的基础设施失败只生成新 workflow run，不新建分支/PR，不改版本、Build、`request_id` 或 `release_ready_at`；若已存在可信签名 artifact、正确的 Tag/Release 字节或仅剩公开交付验证，必须从已确认失败的阶段继续，不得重建或覆盖已生成字节。只有内容确实变化且尚未产生 Tag、Release、appcast 或公开分发资产时，才建立新 SHA 的 replacement attempt：保留原 `request_started_at` 和 `request_id`，保留旧证据，核对旧远端 head 后以 compare-and-swap / `force-with-lease` 更新唯一版本分支与 Draft PR，并在新 SHA 门禁完成后生成新的 attempt attestation 和 `release_ready_at`。公开身份或公开字节已经存在后，内容变化才必须改用新版本和递增 Build；单纯的签名、公证、Runner 或外部服务失败不占用版本。
8. Environment 审批后，Apple Silicon 与 Intel 使用独立 SwiftPM scratch 并行构建、签名和公证；每种架构的安装与卸载 PKG 也并行提交公证。签名失败或 540 秒 supervisor 到期只失败一次，不自动重建或静默重试。
9. 签名 Job 只持有读取源码和凭据所需权限；独立 publish Job 不接触 Apple 凭据，只取得 `contents/actions: write`。它在 GitHub 内部直接接收签名 artifact、创建不可变 Tag 和 Pre-release，并以 `candidate-provenance.json`/canonical manifest 列出的全部资产为准，从 GitHub 与 CDN 并行下载逐字节复核；不得在文档或验证器中假定固定资产数量。
10. 只有公开字节、provenance、feeds 和更新路径全部验证通过，workflow 才上传 `release-slo-ledger-published-*` 完成标志，watchdog 才结束；Release Guard 随后将同一 Draft PR 转 Ready 并启用 Auto-merge。稳定 `latest` 在整个预览发布和验证期间必须始终精确等于当前受审基线 `v1.8.3`，而不只是相对执行前保持不变。

GitHub 自动生成的 CI App 只用于验证打包结构，不是已签名、公证的公开安装包。公开 Preview 的完整签名、公证、发布与公开字节验证只有 `mac-release` 受保护 Environment 中的 `macOS Signed Release Packages` workflow 一个权威入口；本地命令只能做无秘密预检并 dispatch 该 workflow，不得直接签名或发布。

候选结构检查与 Draft PR 无凭据 CI 可以并行；它们必须全部完成后才能开始受保护签名与预览发布。Developer ID 签名、公证、staple、Gatekeeper、公开字节和 Sparkle 更新验证均不得省略。下一次预览发布应记录候选 CI、PR CI、Environment 等待、双架构构建、公证、公开验证各阶段耗时，用真实数据确认优化效果。

## 私有 Draft 内部测试包

- 私有 Draft 不属于公开 Pre-release 或正式版，也不授权 Push 源码；但可安装的 macOS 资产必须使用与公开包同等级的 Developer ID 签名和 Apple 公证，禁止 ad-hoc、未公证或未 staple 的 App、DMG、PKG 和包含这些内容的 ZIP。
- 从已提交且可识别的精确源码状态，在隔离 worktree 中调用项目原生签名、公证和打包路径。Apple 凭据只允许由 `mac-release` 受保护 Environment、隔离临时 Keychain 或既有无交互发布机承载；验证步骤不能代替签名、公证，也不得输出任何凭据值。
- 上传前对最终资产验证 Developer ID Application / Installer、Team ID `L3QHLDRPAY`、Hardened Runtime、嵌套组件 `codesign --deep --strict`、`stapler validate` 和 `spctl`。ZIP 不要求自身 staple，但必须解压，并对内部 App、DMG 或 PKG 分别完成上述适用检查。
- Draft 创建后必须重新下载每一项资产，核对 GitHub `sha256:` digest、本地 SHA-256 与逐字节一致性，并再次执行 macOS 资产验证。只有远端复验全部通过后才能执行旧 Draft 保留策略；失败时保留当前与旧 Draft，报告阻断原因，不得降级重打 ad-hoc 包。
- Release Notes 必须明确这是私有内部测试包，并记录版本、Build、源码 Commit、预期 Team ID、签名公证复验和 SHA-256；不得写入证书名称、私钥路径、密码、P8、notary 凭据或 Token。
- 纯非 macOS 私有 Draft 继续按其平台原生门禁发布，不强制 Apple Team ID。

## 正式晋升

- 不存在“发布正式版”命令。只有用户明确指定一个当前为 Pre-release 的版本，并要求“将预览版 `vX.Y.Z` 晋升为正式版”时才允许执行。
- 先通过 PR 将原候选提交合入 `main`，保留原 Tag 和原资产，不重新构建。
- 晋升前必须证明 Tag 提交已包含在 `origin/main`，并复核 `candidate-provenance.json` 中的分支、提交和资产摘要。
- 正式晋升只修改现有 GitHub Release 的分类和 `latest` 状态，不替换任何候选资产，也绝不重新进入 Apple 签名、公证或打包流程。
- 正式晋升的 30 分钟纯发布窗口只允许由当前获得该次精确晋升授权的发布会话手动 dispatch，并必须传入用户请求时的 `request_started_at`、不可变 `request_id`。合法命令已经指定一个发布并验证过的 Pre-release；首次 stable attestation 冻结该请求的 `release_ready_at`，随后 workflow 重新验证 Tag、main 祖先关系、Pre-release 分类、provenance 和资产摘要，任一不满足即失败而不是重新构建。workflow 按 Tag 持久化首次 stable attestation，重试时 request ID、请求时间或已冻结的 ready 时间不一致必须 fail closed，watchdog 和 promote 只能读取该账本。发布机上的独立 watchdog 覆盖 GitHub Runner 尚未启动的等待。GitHub 页面手改 Release 后产生的 `workflow_run` reconciliation 只是恢复机制，没有原始用户授权和时间戳，不得执行正式晋升；它必须回到当前授权发布会话重新发起“将指定预览版晋升为正式版”的命令。
- GitHub 页面上的人工“设为正式版”只视为晋升请求；Release 守卫会先恢复为 Pre-release，校验候选来源，创建或复用候选分支到 `main` 的 PR、显式调度必需 CI 并启用 Auto-merge。CI 成功后，受保护的晋升工作流确认带授权标签的 PR 已合入 `main`，再只晋升原 Tag 和原资产。
- 晋升脚本从候选的 `candidate-provenance.json` 读取版本和 Build，不依赖 `main` 当时的 `Info.plist`；因此后续开发已经提高版本号时，仍可安全晋升较早的已验收候选。

## Release Notes

- 只记录普通用户能够看到或受益的功能、体验、兼容性和可靠性变化。
- 不写提交标题、哈希、CI、文档维护、测试数量、签名、公证、分支规范或发布流程。
- 已撤回、删除或从未公开的版本不进入 App 内版本历史。
