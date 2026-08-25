# 分支与提交管理策略

本文件统一规定本仓库的分支、工作区、提交、PR 和 Push 边界。具体 macOS 发布步骤仍以 [`RELEASING.md`](RELEASING.md) 为准。

## 主分支不变量

- `main` 必须始终与最新已获取的 `origin/main` 精确一致；检查或交付前必须先 fetch 远端并重新核对 SHA。
- 不得在 `main` 工作区直接开发功能、修复 Bug 或临时保存未提交改动；产品工作必须使用独立分支和 worktree。仅修改 `TODO.md` 且不改变代码、配置、测试或发布行为的 TODO-only 工作，按下方专用流程处理。
- 每个功能或 Bug 分支都必须从最新已获取的 `origin/main` 创建；创建前必须 fetch 并确认分支基线与 `origin/main` 的 SHA 一致。
- 每个功能或 Bug 分支提交 PR 时，目标分支必须是远端 `main`（即 GitHub 上的 `origin/main`）；不得将 PR 指向旧分支、候选分支或其他工作分支。
- 分支、worktree、提交或发布操作不得为了方便而让 `main` 暂时承载其他工作项；完成操作后仍必须恢复 `main == origin/main`。

## 标准功能与 Bug 流程

1. **同步基线**：开始工作前执行 `git fetch origin main`，确认本地 `origin/main` 是最新远端主线。
2. **创建分支**：从该 SHA 创建独立分支和 worktree；分支创建后不得再把其他功能、Bug 或发布改动混入其中。
3. **开发与验证**：在独立 worktree 中开发。功能必须完成必要的自动化验证和对应测试手册；Bug 必须按复现、日志、代码、修复、验证顺序处理，并记录到 `Bugs/`。
4. **提交**：验证通过后创建只包含当前工作项的 commit；提交前检查 diff、敏感信息和单文件大小，超过 5 MB 的文件必须先获得用户批准。
5. **创建 PR**：通过下方“PR 创建门禁”后，Push 分支并创建目标为远端 `main` 的 PR。可以提前创建 Draft PR 供审查，但未完成本地验证、必要文档或必需 CI 前，不得将其标记为 Ready，也不得合入。
6. **更新基线**：PR 准备 Ready 前重新 fetch `origin/main`。如果主线已前进，先把当前分支同步到最新 `origin/main`，解决冲突并重新执行受影响的验证；不得用过期基线直接请求合入。
7. **合入**：功能和 Bug 工作只有 PR 审查完成且所有必需检查通过后，才能通过 PR 合入 `main`；TODO-only 工作按下方专用流程直接合入，禁止把 TODO-only 变更混入产品分支。
8. **合入后收尾**：合入完成后 fetch 远端，将本地 `main` 快进到 `origin/main`，确认两者 SHA 一致并记录合入 commit。已合入分支和 worktree 先标记为已完成，清理或删除必须单独确认，不能借整理之名删除未核对的工作。

## PR 创建门禁

- 每个 PR 必须且只能对应一项独立、可审查的功能、新增需求或 Bug 修复；禁止把多个互不相关的功能、需求或修复放入同一个 PR。
- 创建任何 PR（包括 Draft PR）前，必须重新 fetch 并检查最新 `origin/main` 的相关代码和 commit 历史，确认主线尚未实现同类功能或修复相同、类似的问题；如果主线已经解决，不得创建重复 PR。
- 创建 PR 前还必须检索远端仓库已有的 Open、Draft、Merged 和 Closed PR，确认是否存在内容相同或高度重叠的 PR。已有活动 PR 覆盖相同工作项时，不得重复创建；只有部分重叠或此前 PR 已关闭时，必须先确认范围差异，并在新 PR 中明确说明关联、差异及重新创建的原因。
- 创建任何 PR（包括 Draft PR）前，必须检查相对目标分支的完整 diff 和 commit 列表。只要发现包含两个或更多互不相关的工作项，就必须停止创建 PR，先将其拆分到各自独立的分支、commit 和 PR；拆分完成前不允许创建该 PR。
- 当前工作项直接必需的测试、测试手册、简短文档、配置和兼容性调整可以随同提交，但必须服务于同一工作项，不得以“配套修改”为由夹带可独立交付的其他功能。

## 工作区状态审计

- worktree 数量多、分支落后或存在未合入分支，不等于当前功能代码未提交；但每次开始新任务前必须识别当前 worktree、分支、基线和未提交改动，不能把历史 worktree 当作当前任务的干净基线。
- 规则文档不能自动修复历史分支和 worktree。发现 `ahead/behind`、未跟踪文件、未提交改动或已合入但仍保留的旧 worktree 时，先建立清单和归属，再按用户批准的方案逐项处理。
- 未经核对不得批量删除、清空、reset、rebase 或强制 Push 分支；尤其不能为了让列表变短而破坏仍可能包含用户工作的 worktree。

## TODO-only 工作流程

- 本流程只适用于新增或更新 `TODO.md`（以及同一次记录所需的简短公开文档引用），且不修改业务代码、测试、配置、依赖、发布资产或用户可观察行为。
- 所有 TODO-only 记录统一使用长期分支 `codex/todo_list`，不为每一条 TODO 新建分支或 worktree。每次记录仍创建独立 commit，commit 只能包含当前 TODO 记录及其必要的文档改动。
- 开始记录前先 fetch `origin/main`，确认 `codex/todo_list` 已同步到最新主线；记录完成并通过 `git diff --check`、文件范围、敏感信息和文件大小检查后，立即将该 commit 合入 `main`。该路径不触发产品构建、测试、签名、发布等 CI；仅保留必要的文档级检查。
- 合入后 fetch 远端并确认本地 `main == origin/main`，再把 `codex/todo_list` 同步到最新主线，继续承载下一条 TODO。该长期分支不因单条 TODO 删除；任何清理仍需单独确认。
- 如果一次 TODO 记录实际需要修改代码、测试、配置、依赖或发布行为，立即退出本流程，改按标准功能或 Bug 流程创建独立分支和 worktree，并执行相应 CI 与验收。

## 独立工作项提交边界

- 每个独立功能、新增需求或 Bug 修复完成必要验证后，必须先创建一个仅包含该工作项的 commit，才能继续开发下一个工作项，避免多个已完成工作堆叠在同一未提交工作区中。
- commit 不得夹带其他工作项或用户已有的无关改动。工作失败、尚未完成或未达到必要验证要求时，不得伪装成已完成提交。
- 交付时必须回报 commit SHA，并明确说明该提交是否尚未 Push。
- 任何单个待提交文件超过 5 MB 时，必须在创建 commit 前暂停并等待用户明确批准；未获批准不得通过 commit、合并或 Push 方式提交该文件。

## 工作区与发布分支隔离

- 当前工作区只要存在未验收、与本次发布无关或尚未计划发布的改动，即使这些改动已经 commit，也不得直接从该工作区发布。
- 发布前必须 fetch 远端，并从明确批准且已经 Push 的目标提交创建隔离 worktree；发布提交、版本、Tag、制品和远端分支必须解析到同一个提交。
- 不得为了整理发布工作区而合并、rebase、force-push、清空或广泛提交原工作区中的其他改动。发布完成后仍要保留未验收功能所在的原分支。

## macOS 预览候选分支

- 功能和修复必须先通过 PR 合入 `main`；不得直接在预览候选分支开发产品功能。
- 发布会话收到尚未合入 `origin/main` 的产品 Commit 时，必须从最新 `origin/main` 建立独立开发集成分支，只重放用户指定工作及必要依赖，通过普通 PR 和必需检查合入；机械冲突可依据代码、测试和文档解决，涉及产品取舍或行为丢失时才请求用户决策。集成完成前不得创建候选或接触 Apple 发布凭据。
- 每个版本只允许一个远端候选分支 `release/pre-vX.Y.Z`、一个当前冻结的候选 SHA 和一个跟随该分支当前 head 的 Draft 回流 PR。候选分支只是当前 active attempt 的唯一协调 ref；真正不可变、可审计的发布身份是候选 SHA、Run、attestation 和最终资产。禁止创建 `-rerun`、`-rerun2` 或其他指向相同内容的候选别名分支，也禁止为同一版本创建第二个回流 PR。
- 首个候选 attempt 必须从创建时最新的 `origin/main` 建立，并冻结 `baseMainCommit`、候选 SHA、版本、Build、Release Notes 和制品闭包 digest。冻结后 `main` 可继续前进；候选签名/打包制品闭包由原始 attestation 和候选 digest 固定，只要 `baseMainCommit` 仍是当前 `origin/main` 的祖先，不得仅因恢复或发布控制面的 `main` 后续提交而废弃已冻结候选。
- 候选分支只允许修改版本号、Build、中英文版本历史和必要的测试手册目标版本；不得包含产品代码、依赖、entitlements、签名、打包或 workflow 修改。
- 同一候选 SHA 的 Runner、GitHub、Environment 审批、Apple 或 CDN 等基础设施失败，只能使用同一分支、SHA、Draft PR、版本、Build、`request_id` 和 `release_ready_at` 重试 workflow；不得新建候选分支、提高版本或 Build，也不得通过新 SHA 清除失败检查证据。
- 只有候选内容、冻结基线或制品闭包确实必须变更时，才允许结束旧 attempt 并在同一 `release/pre-vX.Y.Z` 分支和同一 Draft PR 上建立 replacement attempt。该版本分支仍只保留一个直接位于冻结 base 之后的 metadata-only candidate Commit；远端 head 必须先与预期旧 SHA 完全一致，再由显式 compare-and-swap / `force-with-lease` 等受控方式原子更新。禁止普通 force-push、禁止绕过旧 head 核对，也禁止并存第二个候选分支或 PR。旧 SHA、Run、attestation 和失败原因必须保留作为证据，同一时刻只能有一个 active attempt。
- 发布流水线资格验证与产品候选解耦：仅当变更影响 App/PKG/DMG 生成、签名、公证、Sparkle 元数据、制品清单或签名/来源信任边界时，才把普通流水线变更 PR exact SHA 临时映射到 `release/pipeline-qualification/<pr号或短SHA>` ref，以满足受保护 Environment 的分支策略，并以 `release_mode=qualification` 执行真实 Developer ID/Notary 路径。恢复控制面变更只需普通 PR、单机 macOS fixture/静态测试和主线保护检查；只读取既有 signed artifact 的版本、摘要和公开下载 verifier 也走该快速路径。`resume-preview` 只绑定原始候选的历史制品 digest，不校验当前 main 是否重新产生 qualification artifact。该 ref alias 不创建第二个 PR，也不是产品候选；资格证明按制品闭包 digest 复用，不创建版本候选、Tag、Release、appcast 或产品分发资产，也不占用版本或 Build。
- 候选 Push 后必须立即创建唯一 exact-SHA Draft 回流 PR；`macOS Preview Candidate` 和该 PR 的无凭据检查可以并行，并且在严格 metadata-only 时复用冻结 `baseMainCommit` 已通过的双架构产品代码证明。受保护签名、公证和 Preview 发布不得与未完成的候选/PR 门禁并行；只有 exact SHA、唯一 Draft PR、双架构检查和制品闭包资格证明全部成功后才能进入 `mac-release` Environment。恢复既有签名 artifact 的控制面修复不进入该 Environment。
- 公开 Pre-release 仍必须使用 Developer ID 签名、公证、Sparkle 签名和公开资产复核；GitHub CI 的 ad-hoc App 不能当作公开安装包。
- 候选 Tag、远端候选分支和发布资产必须指向同一冻结 SHA。Runner、GitHub、Apple、签名、公证或其他非内容失败本身不占用版本与 Build；未产生公开不可变身份时，同一 SHA 只在同一分支原地重跑，内容确需变化时才在同一分支建立 replacement attempt。Tag、Release、appcast 或公开分发资产一旦存在，其身份与字节不可替换；后续仅恢复和验证同一批公开字节，若产品内容确需变化则选择新版本与递增 Build。候选分支在正式晋升完成前不得删除。
- 不存在“发布正式版”命令。正式版只能由用户明确指定一个已发布并验证的 Pre-release，再将该预览版的同一 Tag、Commit 和同一批资产晋升为正式版；禁止从 `main` 重新构建正式包。
- 完整流程与 Release Notes 规则见 [`RELEASING.md`](RELEASING.md)。
