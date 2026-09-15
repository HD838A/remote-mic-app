# 分支与提交管理策略

本文件规定产品开发、版本元数据、macOS 预览发布和正式晋升的最小分支边界。发布实现细节和流程设计见 RELEASING.md。

## main 不变量

- 开始任何操作前执行 git fetch origin main，并记录 origin/main 的完整 SHA。
- main 工作区只用于同步已合入的远端主线，不直接开发、保存临时改动或准备版本元数据。
- 功能、Bug、发布流程和文档改动都在独立分支和持久化 worktree 中完成；分支创建点必须是当时最新的 origin/main。唯一例外是下方 TODO-only 流程使用长期共享分支 `codex/todo_list`，但仍必须通过 PR 合入 `main`。
- 除 Hotfix 的临时审核 PR 外，PR 的目标分支只能是远端 main。合入后再次 fetch，确认本地 main 与 origin/main 精确一致。
- `main` 必须始终处于可发布状态；未完成必要验收的功能不得先合入再等待发布分支筛选。
- 普通 Preview 和 Stable 的发布控制面与源码都只能使用精确 `origin/main`；GitHub Actions 必须从 `main` 触发并验证它仍是远端 HEAD。
- 不使用普通 force-push、广泛 reset 或把其他 worktree 的未验收内容直接复制到发布分支。

## 标准功能与 Bug 流程

1. **同步基线**：开始工作前执行 `git fetch origin main`，确认本地 `origin/main` 是最新远端主线。
2. **创建分支**：从该 SHA 创建独立分支和持久化 worktree；分支创建后不得再把其他功能、Bug、发布或规范改动混入其中。纯 TODO-only 记录按下方专用流程处理。
3. **开发与验证**：在独立 worktree 中开发。功能必须完成必要的自动化验证和对应测试手册；Bug 必须按复现、日志、代码、修复、验证顺序处理，并记录到 `Bugs/`。
4. **提交**：验证通过后创建只包含当前工作项的 commit；提交前检查 diff、敏感信息和单文件大小，超过 5 MB 的文件必须先获得用户批准。
5. **创建 PR**：通过下方“PR 创建门禁”后 Push 分支并创建目标为远端 `main` 的 PR。可以提前创建 Draft PR 供审查，但未完成本地验证、必要文档或必需 CI 前，不得将其标记为 Ready，也不得合入。
6. **更新基线**：PR 准备 Ready 前重新 fetch `origin/main`。如果主线已前进，先把当前分支同步到最新 `origin/main`，解决冲突并重新执行受影响的验证；不得用过期基线直接请求合入。
7. **合入**：功能和 Bug 工作只有 PR 审查完成且所有必需检查通过后，才能通过 PR 合入 `main`；合并方式遵守本文件的 PR 合并策略。
8. **合入后收尾**：合入完成后 fetch 远端，将本地 `main` 快进到 `origin/main`，确认两者 SHA 一致并记录合入 commit。已合入分支和 worktree 先标记为已完成，清理或删除必须单独确认，不能借整理之名删除未核对的工作。

## PR 创建门禁

- 每个 PR 必须且只能对应一项独立、可审查的功能、新增需求、Bug 修复或明确的规范变更；禁止把多个互不相关的工作项放入同一个 PR。
- 创建任何 PR（包括 Draft PR）前，必须重新 fetch 并检查最新 `origin/main` 的相关代码和 commit 历史，确认主线尚未实现同类功能或修复相同、类似的问题；如果主线已经解决，不得创建重复 PR。
- 创建 PR 前还必须检索远端仓库已有的 Open、Draft、Merged 和 Closed PR，确认是否存在内容相同或高度重叠的 PR。已有活动 PR 覆盖相同工作项时，不得重复创建；只有部分重叠或此前 PR 已关闭时，必须先确认范围差异，并在新 PR 中明确说明关联、差异及重新创建的原因。
- 创建任何 PR（包括 Draft PR）前，必须检查相对目标分支的完整 diff 和 commit 列表。只要发现包含两个或更多互不相关的工作项，就必须停止创建 PR，先将其拆分到各自独立的分支、commit 和 PR；拆分完成前不允许创建该 PR。
- PR 包含 UI 变更时，必须在 PR 描述中附上清晰的功能截图，展示本次修改后的实际界面和功能效果；截图缺失时，该 PR 只能保持 Draft，不得标记为 Ready 或合入。
- 当前工作项直接必需的测试、测试手册、简短文档、配置和兼容性调整可以随同提交，但必须服务于同一工作项，不得以“配套修改”为由夹带可独立交付的其他功能。

## 工作区状态审计

- worktree 数量多、分支落后或存在未合入分支，不等于当前功能代码未提交；但每次开始新任务前必须识别当前 worktree、分支、基线和未提交改动，不能把历史 worktree 当作当前任务的干净基线。
- 规则文档不能自动修复历史分支和 worktree。发现 `ahead/behind`、未跟踪文件、未提交改动或已合入但仍保留的旧 worktree 时，先建立清单和归属，再按用户批准的方案逐项处理。
- 未经核对不得批量删除、清空、reset、rebase 或强制 Push 分支；尤其不能为了让列表变短而破坏仍可能包含用户工作的 worktree。

## TODO-only 工作流程

- 本流程只适用于新增或更新 `TODO.md`（以及同一次记录所需的简短公开文档引用），且不修改业务代码、测试、配置、依赖、发布资产或用户可观察行为。
- 所有 TODO-only 记录统一使用长期分支 `codex/todo_list`，不为每一条 TODO 新建分支或 worktree。每次记录仍创建独立 commit，commit 只能包含当前 TODO 记录及其必要的文档改动。
- 开始记录前先 fetch `origin/main`，确认 `codex/todo_list` 已同步到最新主线；记录完成并通过 `git diff --check`、文件范围、敏感信息和文件大小检查后，立即 Push 并创建只包含该 TODO commit、目标为 `main` 的 PR。PR 仍受 `main` 的 Pull Request 和 Required status checks 保护；macOS CI 对 docs-only 变更只运行文档级步骤并返回既有 required contexts，不执行产品构建、测试、签名或发布。
- 合入后 fetch 远端并确认本地 `main == origin/main`，再把 `codex/todo_list` 同步到最新主线，继续承载下一条 TODO。该长期分支不因单条 TODO 删除；任何清理仍需单独确认。
- 如果一次 TODO 记录实际需要修改代码、测试、配置、依赖或发布行为，立即退出本流程，改按标准功能或 Bug 流程创建独立分支和 worktree，并执行相应 CI 与验收。

## 独立工作项提交边界

- 每个独立功能、新增需求、Bug 修复或规范变更完成必要验证后，必须先创建一个仅包含该工作项的 commit，才能继续开发下一个工作项，避免多个已完成工作堆叠在同一未提交工作区中。
- commit 不得夹带其他工作项或用户已有的无关改动。工作失败、尚未完成或未达到必要验证要求时，不得伪装成已完成提交。
- 交付时必须回报 commit SHA，并明确说明该提交是否尚未 Push。
- 任何单个待提交文件超过 5 MB 时，必须在创建 commit 前暂停并等待用户明确批准；未获批准不得通过 commit、合并或 Push 方式提交该文件。

## 规范变更隔离与防护

- `AGENTS.md`、`BRANCH_MANAGEMENT.md`、`FEATURE_DEVELOPMENT.md` 和 `.github/PULL_REQUEST_TEMPLATE.md` 属于核心治理规范；`scripts/verify-repository-governance.sh` 与 `.github/workflows/repository-governance.yml` 属于治理守护实现。除恢复缺失规则、修复明确治理缺陷或同步专项规范边界外，产品功能、Bug、发布流程和普通测试手册 PR 不得修改这些文件。
- 核心治理文件确需修改时，必须使用独立 PR；PR 描述必须列出变更前后规则、影响范围、迁移方式和明确不做事项，并在相关提交信息中包含 `[governance-change]`。
- 核心治理 PR 必须保持 Draft，直到仓库维护者或用户逐项确认规范覆盖对照、无功能文件改动和静态检查结果；确认后必须在 PR 正文记录明确的批准来源，才能转为 Ready 并按正常门禁合入。自动化 Agent 不得在缺少该确认时自行将其标记 Ready、批准或合入。该人工确认不能由 required check、零审批 ruleset 或机器人 bypass 替代。
- 发布流程可以更新 `RELEASING.md` 及其直接测试手册，但不得借发布流程重构删除或弱化核心治理规则；发布 PR 若同时修改核心治理文件，必须通过治理变更门禁并单独说明原因。
- `scripts/verify-repository-governance.sh` 和 `.github/workflows/repository-governance.yml` 是本文件关键规则的静态守护检查。`Repository governance` 必须配置为 `main` 的 Required status check；规则增删必须与该检查、PR 模板和迁移说明在同一个独立治理 PR 中同步更新，不得只改规范文本而不更新守护检查。治理 PR 可以同时修改 `DOCUMENTATION.md`、README 的稳定文档入口和与本次规则直接冲突的专项规范、产品合同或测试合同，但必须使用静态 allowlist，且不得包含 `Sources/`、`Tests/` 下的可执行功能测试代码、产品配置、依赖或发布资产。

## PR 合并策略

- PR 默认使用 GitHub 的普通 Merge（保留合并提交），保留 PR 分支中的独立提交、作者、时间顺序和完整 Git history；即使 PR 只有一个提交，也不自动改用 squash。
- 只有用户明确要求，或仓库维护者在该 PR/项目规范中明确记录了具体例外时，才允许使用 squash merge 或 rebase merge。执行前必须在交付说明中写明合并方式及其影响。
- 自动化工具不得因为“提交较少”“历史更整洁”或界面默认按钮而擅自选择 squash/rebase；未指定时按本节的普通 Merge 执行。
- 合并后必须重新 `git fetch origin main`，记录远端 `main` 的合并提交 SHA，并确认目标分支已包含该 PR；已经合入的提交不得为了更换合并方式而改写 `main` 历史。

## 公开构建与私有集成边界

- 公开仓库的默认 checkout 不得要求任何私有仓库权限。`Package.swift`、`Package.resolved` 和公开构建入口不得解析私有 Git URL；只有公开仓库访问权限的贡献者必须能完成 SwiftPM resolve、完整测试、双架构 Release build 和本地 App 构建。
- 私有组件通过显式本地 Package 路径接入。未提供路径时，公开兼容层只保留编译契约并明确报告相关能力不可用，不得复制私有实现，也不得影响实体 HID、音频、设置等公开功能运行。
- macOS CI 的公开测试与构建是强制门禁，必须显式清空私有 Package 路径后执行，不能因为 Secret、deploy key 或私有仓库不可访问而跳过。公开门禁失败时 Job 必须失败。
- CI 探测到全部受版本清单约束的私有依赖都可访问时，必须按固定 Commit 追加私有集成测试和双架构 Release build；这些检查失败时 Job 必须失败。权限缺失或私有仓库不可访问时，只允许跳过私有集成步骤，并输出明确的非敏感状态，不得打印 key 或凭据。
- 受保护发布 Workflow 与普通 CI 不同，必须 fail closed：缺少任一发布所需私有组件、固定 Commit 校验失败或私有 checkout 失败时不得生成发布包。

## release-main 历史冻结

- `release-main` 只保留历史审计，不再接收 Commit、PR、合并、Preview staging、Preview publication 或新的 Stable promotion 入口；已经公开的历史 Pre-release 可以由 `main` 控制面按兼容晋升门禁完成正式化。
- CI 和发布 Workflow 明确拒绝 `release-main`；不得为了发布新版本重新同步、快进或复活该分支。
- 不再创建新的 `release/pre-vX.Y.Z`、canary、rerun 或 qualification 分支；历史分支同样不得作为新发布入口。

## Hotfix 唯一例外

- 只有用户明确要求紧急 Hotfix 时，才允许从当时 GitHub `releases/latest` 对应稳定 Tag 的精确 Commit 创建 `hotfix/vX.Y.Z`；版本必须是同一 major/minor 下更高的 patch，并与 `Resources/Info.plist` 完全一致。
- Hotfix 分支只包含该修复、直接相关测试和版本/Release Notes 元数据；必须保持从稳定 Tag 开始的线性历史，不合并 `main` 或其他功能分支。
- Hotfix 审核 PR 可以临时以对应 `hotfix/vX.Y.Z` 为目标分支。发布源码必须是该远端分支的精确 HEAD，并通过 Hotfix 分支双架构 CI。
- 发布 Workflow 本身仍只从精确 `main` 运行；`hotfix/vX.Y.Z` 只是经过严格验证的源码输入，不能修改或替代发布控制面。
- Hotfix 发布完成后，修复必须通过普通 PR 同步回 `main`；Hotfix 分支在同步完成前保留，不得继续承载下一次发布。

## 产品开发与发布元数据

1. 功能或 Bug 先通过普通 PR 合入 main。若用户指定的 Commit 尚未进入主线，先从最新 origin/main 建立独立集成分支，只重放指定工作和必要依赖；冲突必须逐文件核对，不能以整支旧分支覆盖当前主线。
2. 版本号、Build 和中英文 ReleaseHistory 属于发布元数据，也必须在普通 PR 中修改。使用 scripts/prepare-preview-release.sh 前，分支必须是从最新 origin/main 创建的干净分支；脚本只允许修改 Resources/Info.plist 和两份 ReleaseHistory.md。
3. 普通版本的元数据 PR 合入后，发布源就是该次合入后的精确 `origin/main` SHA；不再做第二次分支同步或挑选 Commit。Hotfix 的版本元数据则与修复一起保留在对应 `hotfix/vX.Y.Z`。
4. 请求版本已被公开 Tag、Release 或已上传的公开分发资产占用时，脚本只递增最后一位并选择更高 Build。公开资产占用检查覆盖 canonical CDN 固定路径：13 个 payload URL 只有明确 HTTP 404 才算可用；2xx/3xx 视为占用，认证、权限、5xx、超时或其他无法判断的响应 fail closed。Runner、GitHub、Apple、签名、公证或网络故障不会占用版本，不得因为这些故障升版本。

## 预览发布引用

- 预览 staging 的发布控制 Workflow 只从精确 `origin/main` 触发。scripts/stage-macos-preview.sh 接受精确 `main` 源码，或唯一例外的精确 `hotfix/vX.Y.Z` 源码；先验证源码分支、稳定 Tag 基线、双架构 CI、依赖 pin 和当前 `main` 控制面，再 dispatch 受保护 workflow。
- 受保护 workflow 的唯一职责是 Apple Silicon 与 Intel Ventura 双架构构建、Developer ID 签名、公证、staple、最终校验，并上传不可变 payload artifact 和 stage record。它不创建 Tag、Release 或公开 appcast。
- 真实 Sparkle UI 升级必须使用该 exact artifact，在公开身份建立前完成。之后由 `main` 上无 Apple 凭据的 publication workflow 创建公开 Pre-release，并逐字节复用同一 artifact；首次创建 Tag 前再次确认 13 个 CDN 固定路径全部返回 404。
- 发布身份由 source branch/kind/SHA、Hotfix 稳定基线、main workflow SHA、Run/attempt、artifact ID/digest、asset manifest 和 UI attestation 绑定；不能用“最新 Run”或相同名称的 artifact 猜测来源。

## 失败、重试与内容变化

- 同一 SHA 的基础设施或外部服务失败：在同一 `main` 或已批准 Hotfix 源码 SHA、版本、Build 和 artifact 身份上重试对应阶段；不新建分支、PR、Tag，不重新签名已经成功的字节。
- staging 成功后 publication 失败：先查询远端状态，复用已有 Tag 和已上传资产，只补缺失项或重做明确失败的公开验证。已有资产大小或 digest 不一致，或公开 Release Notes 与候选不一致时停止并保留现场。
- 公开 Pre-release 建立后，Tag、资产和 appcast 视为不可变。产品内容变化必须回到产品 PR，合入 main 后使用新的可用版本和更高 Build；不能改写旧 Tag 或覆盖资产。
- 任何失败都必须保留 Run URL、错误类别和本地验证输出，不能用多个 rerun 分支掩盖历史。

## 正式版晋升

- 不存在独立的“发布正式版”构建命令。只有用户明确指定一个已经发布且验证通过的 Pre-release，才可运行 mac-stable-promote.yml。
- 晋升 Workflow 只能从精确 `origin/main` 运行。晋升前必须按 provenance schema 执行候选身份校验：当前 schema 5 候选须来自 `main` 或合法 `hotfix/vX.Y.Z`，历史 schema 4 候选可来自冻结的 `release-main`；两者都必须核对 Tag Commit、资产数量/大小/GitHub digest、staging Run/attempt、payload artifact 和 Preview stage-record artifact。未知 schema、缺失来源绑定或来源不再可审计时拒绝晋升。
- 晋升只执行 gh release edit，将同一 Release 标记为非预览并设为 latest；不构建、不签名、不公证、不上传、不移动 Tag。
- stable latest 由 GitHub `releases/latest` 在每次流程开始和结束时动态读取并校验。基线变更必须通过独立普通 PR 记录，不能由预览发布脚本隐式修改。

## worktree、提交和清理

- 当前工作区只要存在未验收、与本次发布无关或尚未计划发布的改动，即使这些改动已经 commit，也不得直接从该工作区发布。
- 发布前必须 fetch 远端，并从明确批准、已经 Push 且与目标远端 SHA 一致的提交使用隔离 worktree；发布源码、版本、Tag、制品和远端来源必须解析到同一个已验证身份。
- 不得为了整理发布工作区而合并、rebase、force-push、清空或广泛提交原工作区中的其他改动。发布完成后仍要保留未验收功能所在的原分支。
- 每个独立工作项创建只包含该工作项的 commit，并在交付时报告完整 SHA、Push 状态和验证命令。
- 需要移除本地文件或 worktree 时，先精确核对目标并移动到 macOS Trash；不得永久删除或使用无法恢复的批量清理。
- 远端旧分支的清理不是发布成功条件。只有在确认没有用户工作、Tag、Release 或审计证据依赖后，才可按单独授权清理。

## 私有 Draft 边界

- 私有内部 Draft 使用 private-draft-release skill 指定的 GetSayAll/SayAll 仓库，先确认 visibility 为 PRIVATE。
- 私有 Draft 不在公开源码仓库创建 Tag 或 Release，也不调用公开 Preview publication workflow。
- 可安装的私有 macOS 包仍必须 Developer ID 签名、公证、staple 和下载后复验；私有分发不降低信任要求。
