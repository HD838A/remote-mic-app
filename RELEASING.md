# macOS 发布分支规范

## 分支职责

- 功能、修复和用户可见文案先通过 Pull Request 合入 `main`。
- macOS 预览候选使用一次性的 `release/pre-vX.Y.Z` 分支。
- 候选分支必须从最新 `origin/main` 创建，只允许包含版本号、Build、对应版本历史和测试手册目标版本等发布元数据。
- 不得在候选分支直接开发功能、合入其他开发分支或混入尚未验收的工作树内容。
- 每个版本只使用一个候选分支；失败候选保持 Tag 和 Release 不变，修复后递增版本与 Build，并创建新的候选分支。
- 候选分支在正式晋升完成前必须保留在远端，供来源校验、自动合并和 Release 守卫使用。

## 发布交接清单

开始发布计时前，开发侧必须同时满足：

- 计划发布的产品 Commit 已经 Push，并通过 PR 合入 `origin/main`。
- `mac-ci.yml`、`mac-preview-candidate.yml`、`mac-release-package.yml` 中 SayAllAI、SayAllMacroPlatform、SayAllMacRemote 均钉定同一组完整 40 位 Commit。
- 私有依赖 Commit 已经 Push，发布 workflow 的只读部署密钥能够获取这些 Commit。
- 最新 `main` 的 macOS CI 已成功；发布会话不承担临时整合产品代码、解决开发冲突或补齐尚未交付的私有依赖。

任一条件不满足时，状态是“尚未发布就绪”，不得先创建候选再边发布边补代码。

## 任务编排与耗时门禁

- 分析请求只做只读诊断并给出结论，不自动扩大为实现、加固或发布。请求同时包含分析和实施时，先在 3–5 分钟内回报阶段结论、改动范围和预计门禁，再开始修改；额外优化必须拆成独立任务，不能静默扩大当前范围。
- 委派任务连续 2 分钟没有工具活动、消息或可验证进展时，主会话必须主动检查；满 3 分钟仍无进展时立即中断并接管或重新委派。CI 已结束时，负责会话应在 30 秒内回报，不得等待下一次用户追问。
- 禁止使用交互式 `gh run watch` 等无法可靠收回控制权的等待方式。统一使用 `gh run view`、GitHub API 或等价的单次状态查询，轮询间隔限定为 30–60 秒，并在开始等待前声明总截止时间；达到截止时间后立即报告当前 Job、阶段和已耗时，不得无限等待或无提示自动重试。
- 普通非发布任务在必需的 PR 检查通过并完成普通合并后即可交付；合并后的 `main` CI 默认作为异步确认，不阻塞首轮回复，但必须保留 Run URL，并在失败时立即回报。修改 CI 门禁本身、共享发布脚本或用户明确要求验证 `main` 时，仍需等待对应 `main` 检查通过。
- 真实发布不得套用上述异步边界。候选 CI、PR 必需检查、Environment 审批、真实签名与公证、公开 GitHub/CDN 字节验证、Release Guard 和候选回流必须按发布流程全部完成后，才能报告发布完成。
- 每个任务维护阶段耗时账本，至少记录：只读分析、开发/文档、测试、PR CI、Environment 等待、签名与公证、公开验证、Guard/合并，以及外部服务或人工审批等待；并区分必要耗时、并行耗时和可避免的静默等待。
- 耗时目标：分析类请求 5–8 分钟内给出完整结论；已经发布就绪的 macOS 候选从发起到安装包可下载目标为 20–25 分钟，完成公开验证和 Release Guard 目标为 30 分钟内。总发布流程超过 35 分钟视为异常，必须立即指出正在耗时的阶段、已采取的止损动作和新的有界截止时间。

## 预览候选流程

1. 将计划发布的功能通过 PR 合入 `main`，等待 macOS CI 通过。
2. 从最新 `origin/main` 创建 `release/pre-vX.Y.Z`。
3. 只修改 `Resources/Info.plist`、中英文 `ReleaseHistory.md`，以及确有必要的 `Testing/*.md` 目标版本。
4. Push 候选分支。`macOS Preview Candidate` 自动执行分支来源、私有依赖钉定、Swift Testing、Self Test、双架构 Release 编译和临时 App 打包。
5. 两个候选 Job 对精确候选 SHA 成功后，运行 `scripts/prepare-preview-recording-pr.sh` 创建 Draft 回流 PR。Draft PR 的受保护 CI 可以提前运行，但公开验证完成前不得转 Ready 或合并。
6. 手动从同一候选分支运行 `macOS Signed Release Packages`。workflow 在进入 `mac-release` Environment、接触 Apple 凭据前，重新核对精确候选 SHA 的成功 push run、两种架构 Job、三条 workflow 的私有依赖 Commit 和 Draft PR。
7. Environment 审批后，Apple Silicon 与 Intel 使用独立 SwiftPM scratch 并行构建、签名和公证；每种架构的安装与卸载 PKG 也并行提交公证。这里复用步骤 4 对精确 SHA 的测试证明，不重复执行等价的 Swift Testing 和 Self Test。
8. 发布为 Pre-release 后，从 GitHub 与 CDN 重新下载公开资产并逐字节复核。新矩阵必须严格为 12 项：两架构 DMG、ZIP、appcast 和卸载 PKG，共享中英文说明、合并 SHA-256 清单及 provenance；安装 PKG 只保留在对应 DMG 内并从 DMG 重新验证。核对 Tag、远端候选分支、provenance 和发布资产指向同一提交；使用公开稳定版执行固定候选 appcast 的真实 Sparkle 更新。历史 15/17 项候选继续允许晋升，但不得改写旧资产。
9. 只有步骤 8 全部通过，Release Guard 才可将 Draft PR 转 Ready 并启用 Auto-merge。稳定 `latest` 在整个预览发布和验证期间不得变化。

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

- 只有用户明确指定具体版本并要求正式发布时才允许晋升。
- 先通过 PR 将原候选提交合入 `main`，保留原 Tag 和原资产，不重新构建。
- 晋升前必须证明 Tag 提交已包含在 `origin/main`，并复核 `candidate-provenance.json` 中的分支、提交和资产摘要。
- 正式晋升只修改现有 GitHub Release 的分类和 `latest` 状态，不替换任何候选资产。
- GitHub 页面上的人工“设为正式版”只视为晋升请求；Release 守卫会先恢复为 Pre-release，校验候选来源，创建或复用候选分支到 `main` 的 PR、显式调度必需 CI 并启用 Auto-merge。CI 成功后，受保护的晋升工作流确认带授权标签的 PR 已合入 `main`，再只晋升原 Tag 和原资产。
- 晋升脚本从候选的 `candidate-provenance.json` 读取版本和 Build，不依赖 `main` 当时的 `Info.plist`；因此后续开发已经提高版本号时，仍可安全晋升较早的已验收候选。

## Release Notes

- 只记录普通用户能够看到或受益的功能、体验、兼容性和可靠性变化。
- 不写提交标题、哈希、CI、文档维护、测试数量、签名、公证、分支规范或发布流程。
- 已撤回、删除或从未公开的版本不进入 App 内版本历史。
