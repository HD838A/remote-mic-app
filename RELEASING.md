# macOS 发布主管与分支规范

## 发布主管职责与合法命令

- 无线麦SayAll.app 的每个 macOS 公开版本都由固定的发布管理任务执行；发布主管负责从用户指定的 Commit、分支或最新 `origin/main` 完成发布就绪整合、候选发布、公开字节验证和结果汇报。
- 合法的公开发布命令只有两类：发布一个新的 Pre-release；或将用户明确指定的现有 Pre-release `vX.Y.Z` 晋升为正式版。
- “发布正式版”不是合法命令。正式版不能凭空构建或发布，只能由已经发布并完成候选验证的指定 Pre-release 晋升产生。
- 正式晋升必须复用该 Pre-release 的同一 Tag、Tag Commit、`candidate-provenance.json` 和全部已验证资产；不得重新构建、重新签名、重新公证、替换资产或移动 Tag。
- 发布请求指定的产品 Commit 或分支尚未进入 `origin/main` 时，发布主管从最新 `origin/main` 建立独立集成分支，只重放指定工作及必要依赖，通过普通 PR 和必需检查合入；发生会改变产品意图或丢失行为的冲突时才请求用户决策。
- 同时收到的新需求或 Bug 调查交给有边界的 subagent；发布主管保留发布主线、凭据边界和最终决策，并汇总 subagent 的证据、改动、验证和 Commit。

## 分支职责

- 功能、修复和用户可见文案先通过 Pull Request 合入 `main`。
- macOS 预览候选使用一次性的 `release/pre-vX.Y.Z` 分支。
- 候选分支必须从最新 `origin/main` 创建，只允许包含版本号、Build、对应版本历史和测试手册目标版本等发布元数据。
- 不得在候选分支直接开发功能、合入其他开发分支或混入尚未验收的工作树内容。
- 每个版本只使用一个候选分支；失败候选保持 Tag 和 Release 不变，修复后递增版本与 Build，并创建新的候选分支。
- 候选分支在正式晋升完成前必须保留在远端，供来源校验、自动合并和 Release 守卫使用。

## 发布交接清单

用户发出发布指令时立即记录 `request_started_at`；指定代码合入最新 `origin/main`、该 SHA 的双架构 CI 成功，并且首次候选 exact-SHA metadata/provenance gate 完成且版本、Build、Release Notes 冻结后，将三者可信时间的最大值冻结为不可重置的 `release_ready_at`。`request_started_at` 用于完整记录和汇报用户总等待，不作为早于纯发布窗口的取消条件；Preview 和正式晋升的纯发布窗口都从各自 `release_ready_at` 起不超过 30 分钟。

- 计划发布的产品 Commit 已经 Push，并通过 PR 合入 `origin/main`。
- `mac-ci.yml`、`mac-preview-candidate.yml`、`mac-release-package.yml` 中 SayAllAI、SayAllMacroPlatform、SayAllMacRemote 均钉定同一组完整 40 位 Commit。
- 私有依赖 Commit 已经 Push，发布 workflow 的只读部署密钥能够获取这些 Commit。
- 最新 `main` 的 macOS CI 已成功；若用户指定的产品 Commit 尚未合入，发布主管必须先在独立开发集成分支完成普通 PR 和必需检查，期间不得创建候选或接触 Apple 发布凭据。

任一条件不满足时，状态是“发布就绪整合中”或“尚未发布就绪”。发布主管应继续完成已获授权且可机械解决的集成工作；不得先创建候选再边发布边补代码。只有需要产品取舍、缺少必要权限或无法从现有证据安全解决时才停止并请求用户决策。

## 任务编排与耗时门禁

- 分析请求只做只读诊断并给出结论，不自动扩大为实现、加固或发布。请求同时包含分析和实施时，先在 3–5 分钟内回报阶段结论、改动范围和预计门禁，再开始修改；额外优化必须拆成独立任务，不能静默扩大当前范围。
- 委派任务连续 2 分钟没有工具活动、消息或可验证进展时，主会话必须主动检查；满 3 分钟仍无进展时立即中断并接管或重新委派。CI 已结束时，负责会话应在 30 秒内回报，不得等待下一次用户追问。
- 禁止使用交互式 `gh run watch` 等无法可靠收回控制权的等待方式。统一使用 `gh run view`、GitHub API 或等价的单次状态查询，轮询间隔限定为 30–60 秒，并在开始等待前声明总截止时间；达到截止时间后立即报告当前 Job、阶段和已耗时，不得无限等待或无提示自动重试。
- 普通非发布任务在必需的 PR 检查通过并完成普通合并后即可交付；合并后的 `main` CI 默认作为异步确认，不阻塞首轮回复，但必须保留 Run URL，并在失败时立即回报。修改 CI 门禁本身、共享发布脚本或用户明确要求验证 `main` 时，仍需等待对应 `main` 检查通过。
- 真实发布不得套用上述异步边界。候选 CI、PR 必需检查、Environment 审批、真实签名与公证、公开 GitHub/CDN 字节验证、Release Guard 和候选回流必须按发布流程全部完成后，才能报告发布完成。
- 每个真实发布必须把用户指令到达时的 Unix epoch 秒作为 `request_started_at` 传入 workflow，并生成可下载的 TSV 阶段账本。账本至少记录候选门禁、Environment/Runner 等待、签名与公证、发布和 GitHub/CDN 公开字节验证；失败必须分类为开发未就绪、审批等待、Apple/GitHub/CDN 外部等待或成功流水线时间，禁止从 Commit 或 CI 开始时间替代用户墙钟。
- 发布管理任务收到指令后的第一项动作必须记录 `request_started_at` 并准备不依赖 GitHub Hosted Runner 的发布机 watchdog；在 `release_ready_at` 冻结后立即启动 30 分钟纯发布监管。Preview 和正式晋升都使用 `release_ready_at + 1740 秒` 的内部截止，为最终回报保留 60 秒；任何重试、重新 dispatch 或候选重建都不得重置时间戳。每次 Push/dispatch 得到的精确 workflow run ID 必须只追加到本次请求独有的 JSONL manifest。发布完成标记必须是包含 `mode`、`requestId`、`target`、`requestStartedAt`、`releaseReadyAt` 和 `status: published-and-verified` 的 JSON，不得使用空文件或复用其他请求的完成标记。
- 硬指标：Preview 和正式晋升从 `release_ready_at` 起均须在 30 分钟内成功或明确失败。达到内部 29 分钟截止仍未完成时，watchdog 必须取消本次登记的 Run 并明确失败，不得盲目重试、延长签名门限或继续静默等待。`request_started_at` 到最终结果的总耗时必须完整汇报，但不会截短尚未开始的 30 分钟纯发布窗口。
- Preview 优化目标继续保持候选元数据尽快完成、双架构签名与公证并行、GitHub/CDN 公开验证并行；这些是缩短发布时间的目标，不再构成额外的更短硬取消条件。签名 composite step 继续保留 10 分钟硬限，内部 supervisor 限 540 秒；publication supervisor 限 180 秒。

## 预览候选流程

1. 将计划发布的功能通过 PR 合入 `main`，等待 macOS CI 通过。
2. 从最新 `origin/main` 创建 `release/pre-vX.Y.Z`。
3. 只修改 `Resources/Info.plist`、中英文 `ReleaseHistory.md`，以及确有必要的 `Testing/*.md` 目标版本。
4. Push 候选分支后立即运行 `scripts/prepare-preview-recording-pr.sh` 创建 Draft 回流 PR，让 Preview 与 PR CI 并行。候选必须是父提交精确等于最新 `origin/main` 的单个 metadata-only Commit；任一产品代码、依赖、签名或流水线变更都会拒绝 fast path 并返回开发。
5. `macOS Preview Candidate` 与 Draft PR 仅在严格 metadata-only 直接子提交且父 `main` 精确 SHA 的 Apple Silicon/Intel 测试、自检和 Release 构建均成功时复用该证明。源码、依赖、workflow、entitlements、打包脚本、非直接父、SHA 不匹配、父 main 缺失/失败或 docs-only 证明都会拒绝复用。Preview 不再自行运行第二套完整 CI；需要完整 exact-candidate CI 时只由 Draft recording PR 生产一次，随后返回开发修正候选结构。
6. 从同一候选分支运行 `macOS Signed Release Packages`，传入最初的 `request_started_at` 和不可变 `request_id`。workflow 从精确父 `main` CI 证明推导并持久化 `release_ready_at`，重试必须复用同一份 attestation；在进入 `mac-release` Environment、接触 Apple 凭据前，重新核对精确候选 Preview、两种架构证明、三条 workflow 私有依赖 Commit，以及 Draft PR 的 Apple Silicon/Intel 必需检查均已成功。独立 GitHub watchdog 与发布机 watchdog 都按 `release_ready_at` 监管 30 分钟纯发布窗口，同时继续记录从 `request_started_at` 起的完整总耗时。
7. Environment 审批后，Apple Silicon 与 Intel 使用独立 SwiftPM scratch 并行构建、签名和公证；每种架构的安装与卸载 PKG 也并行提交公证。签名失败或 540 秒 supervisor 到期只失败一次，不自动重建或重试。
8. 签名 Job 只持有读取源码和凭据所需权限；独立 publish Job 不接触 Apple 凭据，只取得 `contents/actions: write`。它在 GitHub 内部直接接收签名 artifact、创建不可变 Tag 和 Pre-release，并从 GitHub 与 CDN 并行下载 12 项公开资产逐字节复核，避免“上传 Actions artifact → 下载到本机 → 再上传 Release”的往返。
9. 只有步骤 8 全部通过，workflow 才上传 `release-slo-ledger-published-*` 完成标志，watchdog 才结束；Release Guard 随后将 Draft PR 转 Ready并启用 Auto-merge。稳定 `latest` 在整个预览发布和验证期间不得变化。

GitHub 自动生成的 CI App 只用于验证打包结构，不是已签名、公证的公开安装包。完整签名发布在受保护的 CI 发布环境完成前，继续使用既有无交互发布机流程。

候选 CI 和正式打包允许并行的是已经相互隔离的工作；Developer ID 签名、公证、staple、Gatekeeper、公开字节和 Sparkle 更新验证均不得省略。下一次预览发布应记录候选 CI、PR CI、Environment 等待、双架构构建、公证、公开验证各阶段耗时，用真实数据确认优化效果。

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
- 正式晋升的 30 分钟纯发布窗口只允许从发布管理任务手动 dispatch，并必须传入用户请求时的 `request_started_at`、不可变 `request_id`。合法命令已经指定一个发布并验证过的 Pre-release；首次 stable attestation 冻结该请求的 `release_ready_at`，随后 workflow 重新验证 Tag、main 祖先关系、Pre-release 分类、provenance 和资产摘要，任一不满足即失败而不是重新构建。workflow 按 Tag 持久化首次 stable attestation，重试时 request ID、请求时间或已冻结的 ready 时间不一致必须 fail closed，watchdog 和 promote 只能读取该账本。发布机上的独立 watchdog 覆盖 GitHub Runner 尚未启动的等待。GitHub 页面手改 Release 后产生的 `workflow_run` reconciliation 只是恢复机制，没有原始用户授权和时间戳，不得执行正式晋升；它必须回到发布管理任务重新发起“将指定预览版晋升为正式版”的命令。
- GitHub 页面上的人工“设为正式版”只视为晋升请求；Release 守卫会先恢复为 Pre-release，校验候选来源，创建或复用候选分支到 `main` 的 PR、显式调度必需 CI 并启用 Auto-merge。CI 成功后，受保护的晋升工作流确认带授权标签的 PR 已合入 `main`，再只晋升原 Tag 和原资产。
- 晋升脚本从候选的 `candidate-provenance.json` 读取版本和 Build，不依赖 `main` 当时的 `Info.plist`；因此后续开发已经提高版本号时，仍可安全晋升较早的已验收候选。

## Release Notes

- 只记录普通用户能够看到或受益的功能、体验、兼容性和可靠性变化。
- 不写提交标题、哈希、CI、文档维护、测试数量、签名、公证、分支规范或发布流程。
- 已撤回、删除或从未公开的版本不进入 App 内版本历史。
