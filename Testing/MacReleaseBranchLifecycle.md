# macOS 发布分支与 attempt 生命周期测试手册

## 适用范围

- 适用分支：包含单一版本候选、冻结 base、pipeline qualification 和 exact-SHA attempt attestation 门禁的 `main`，以及后续唯一 `release/pre-vX.Y.Z` 候选分支。
- 适用流程：macOS Preview Candidate、macOS Signed Release Packages、Release Guard、macOS CI、macOS Stable Promotion。
- 本手册只验证发布分支与资产生命周期，不代替 App 功能、安装、Intel Ventura、签名或公证的专项验收。

## 测试前准备

1. 使用干净工作区，执行 `git fetch origin main --tags`，确认本地 `main` 与 `origin/main` 一致。
2. 选择尚未占用的测试版本和递增 Build；该版本只能使用一个 `release/pre-vX.Y.Z` 候选分支，不创建 `-rerun*` 或 `-canary-*` 版本别名。
3. 候选只修改 `Resources/Info.plist` 的版本/build、两份 `ReleaseHistory.md` 和必要的 `Testing/*.md`。
4. 记录用户请求的 `request_started_at` 和 `request_id`；后续同 SHA 重试或 replacement attempt 均不得替换这两个值。
5. 计算 `./scripts/release-pipeline-digest.sh`，确认该 digest 已有成功受保护资格证明；证明必须记录一个已经合入 `main` 的普通流水线变更 PR 及其 exact source Commit。只有 digest 变化且无可复用证明时才执行新的 pipeline qualification。
6. 真正发布 Pre-release 前，仍需通过受保护 Environment 审批、两种架构打包、签名、公证及下载字节校验。

## 用例 1：从最新 main 创建单提交候选

1. 从最新 `origin/main` 创建 `release/pre-vX.Y.Z`。
2. 完成允许的发布元数据修改并生成一个普通提交。
3. Push 候选分支，运行 `./scripts/verify-preview-branch.sh`。

预期结果：输出 `PREVIEW BRANCH PASS`，`BASE_MAIN_COMMIT` 等于候选直接父提交和当时最新 `origin/main`，候选相对 main 只有一个提交。

失败判定：候选包含多个提交、merge commit、父提交不是最新 main，或包含产品代码时仍通过。

## 用例 2：禁止从旧预览分支或 Tag 串联

1. 以旧 `release/pre-vA.B.C` 或对应 Tag 为起点创建新的 `release/pre-vX.Y.Z`。
2. 更新版本元数据并运行候选校验。

预期结果：创建门禁失败，并明确提示首个候选 attempt 必须从创建时最新 `origin/main` 创建。“冻结后 main 前进”只适用于已建立候选的后续验证，不允许以旧候选或 Tag 串联新版本。

失败判定：只因 main 是历史祖先就允许从旧预览分支创建新候选，或把 frozen-base 恢复规则误用到新候选的创建阶段。

## 用例 3：禁止候选承载产品代码

1. 在合规候选中额外修改 `Sources/`、`Apps/`、`Package.swift` 或其他非允许文件。
2. 运行候选校验。

预期结果：校验列出首个非发布改动，并要求先将产品代码通过 PR 合入 main。

失败判定：产品代码进入候选或只在发布后才被发现。

## 用例 4：Pre-release 发布后回流 main

1. 候选 Push 后先创建唯一 exact-SHA Draft 回流 PR，再完成签名、公证和 GitHub Pre-release 发布。
2. 等待发布脚本完成 GitHub/CDN 下载字节比较，并确认它调度 Release Guard。
3. 检查 Release Guard 复用候选创建时的同一 PR，将其从 Draft 转为 Ready 并启用 auto-merge。
4. 等待 Apple Silicon 与 Intel Ventura 必需检查通过。

预期结果：候选提交通过 merge commit 进入 main；GitHub Release 仍为 Pre-release；Tag 和所有签名、公证资产未变化，未运行正式晋升。

失败判定：下载字节未验证就将 PR 转 Ready，Release Guard 另建第二 PR，PR 绕过必需检查，Release 被改为正式版，或 Tag/资产被重建替换。

## 用例 5：从回流后的 main 创建下一候选

1. 候选 PR 合入 main 后，更新本地 `origin/main`。
2. 产品开发分支从该 main 创建并通过 PR 合入 main。
3. 下一 `release/pre-vX.Y.Z` 再从新的最新 main 创建。

预期结果：新候选继承已回流的版本元数据和后续产品代码，且仍只有一个新的发布元数据提交。

失败判定：需要从旧候选分支继续开发，或新候选直接父提交不是最新 main。

## 用例 6：正式版复用已验证候选

1. 明确选择一个已经发布、验证且 Tag 提交已包含于 `origin/main` 的 Pre-release。
2. 触发正式晋升，不修改候选分支、Tag 或 Release 资产。
3. 比较晋升前后的资产名称、大小和 SHA-256。

预期结果：同一个 Tag 从 Pre-release 变为 Stable，所有候选资产摘要完全一致，只新增正式晋升证明；未重新签名、公证或打包。

失败判定：候选未进入 main 就晋升、选择了未发布候选、创建新 Tag、替换任一资产或从 main 重建。

## 用例 7：同 SHA 基础设施重试不产生新候选

1. 让 exact SHA 在无内容变化的 Runner 排队、Environment 审批、GitHub API、Apple 或 CDN 阶段失败，确认尚未产生可见的新产品身份。
2. 以同一分支、SHA、Draft PR、版本、Build、`request_id` 和 `request_started_at` 重新 dispatch。
3. 比较前后 attempt attestation 与 watchdog manifest。

预期结果：只新增 workflow Run ID；候选身份与该 attempt 的 `release_ready_at` 不变，不出现 `-rerun*` 分支，不递增版本或 Build，不创建第二个 Draft PR。

失败判定：为了清除失败 check 而生成新 SHA，复用新 `request_id`，重置 `release_ready_at`，或在没有内容变化时提高版本/Build。

## 用例 8：仅内容变化产生 replacement attempt

1. 在进入真实发布不可变阶段前，发现必须修改的候选元数据、冻结基线或 pipeline digest 差异。
2. 明确终止旧 attempt，保留旧 SHA、Run、attestation 和失败原因。
3. 核对远端旧 head 精确等于预期旧 SHA，由受控 replacement 流程使用 compare-and-swap / `force-with-lease` 将同一 `release/pre-vX.Y.Z` 分支和既有 Draft PR 更新到新 SHA；该分支仍只有一个直接位于冻结 base 之后的 metadata-only candidate Commit，不创建第二分支或 PR。
4. 重新完成新 SHA 的候选与 PR 门禁，生成新 attempt attestation。

预期结果：`request_started_at` 和 `request_id` 仍为原请求值；新 SHA 成为唯一 active attempt，并在自身门禁完成后冻结新 `release_ready_at`；旧证据可审计但不再可发布。

失败判定：无内容变化仍建 replacement、未核对预期旧 head、使用普通 force-push、丢失旧证据、新建 `-rerun*` 分支/PR，或让新旧 SHA 同时保持 active。

## 用例 9：main 前进后复用冻结 base

1. 冻结候选，然后让 `main` 合入一个不改发布流水线 digest 的无关提交。
2. Fetch 新 `origin/main`，确认 `baseMainCommit` 仍是新 main 的祖先，并重新执行受信 frozen-base 验证。
3. 再构造一个会改 pipeline digest 的 main 后续提交作为反向用例。

预期结果：无关 main 前进不使原 exact SHA 失效；base 不再是 main 祖先或 pipeline digest 变化时，在读取 Apple 凭据前拒绝，并要求 replacement attempt。

失败判定：只因 main 有无关新提交就创建新候选，或当 pipeline digest 已变时仍复用旧资格证明。

## 用例 10：pipeline qualification 与产品候选解耦

1. 在一个已有的同仓普通流水线变更 PR 中修改会进入 `release-pipeline-digest.sh` 的发布路径，记录该 PR 的 exact head Commit 和 digest。
2. 不创建第二个 PR，只把该 exact SHA 临时映射到 `release/pipeline-qualification/<pr号或短SHA>` ref，以满足受保护 Environment 的分支策略，并以 exact commit/digest 运行 `release_mode=qualification`。
3. 检查 `release-pipeline-qualification.json` 为 schema 3，并记录 workflow path、Run/attempt、artifact ID/digest、原 PR/source Commit、完整 pipeline digest、外部 Action/凭据仓库 full Commit，以及 age、Fastlane、Xcode/Build、Runner image 和验证 CLI 的实际版本。产品依赖清单值记录为观察输入，但不参与未变化工具链的资格失效判断。
4. 资格验证成功后合入原普通 PR；再让产品候选 verifier 确认该 PR 已合入 `main`，从 `refs/pull/<n>/head` 取得原 source Commit并重算 digest。
5. 对未改变的 digest 查询并复用既有成功资格证明，确认 Preview Runner 的上述 Commit 与工具链逐项完全一致，再使用唯一 `release/pre-vX.Y.Z` 候选分支发布产品版本。

预期结果：资格验证只产生按 digest 命名的证明和必要的无敏感账本，不创建第二个 PR、产品 Tag、Release、appcast 或可分发包，不占用版本/Build；证明记录原普通 PR、artifact 和不可变外部依赖，且不依赖临时 alias ref 永久存在；产品候选只复用精确匹配、已随原 PR 合入 main 且工具链完全一致的 digest 证明。

失败判定：为 alias 创建第二个 qualification PR、alias head 与原 PR exact SHA 不同、原 PR 未合入 main 仍可被产品候选复用、`refs/pull/<n>/head` 重算 digest 不一致仍通过、artifact/外部 Commit/工具链不一致仍通过、每个版本都新建 `-canary-*` 候选分支、旧 digest 证明可用于新 digest，或 qualification 创建/修改产品 Release。

## 用例 11：候选与 Draft PR CI 并行边界

1. Push 严格 metadata-only 候选并立即创建唯一 Draft PR。
2. 确认 `macOS Preview Candidate` 与 PR 的无凭据检查同时运行，且均复用 frozen base main 的 exact-SHA 双架构产品代码证明。
3. 在任一候选/PR 必需检查尚未成功时，尝试进入 `mac-release` Environment。

预期结果：无凭据候选与 PR CI 可并行；受保护签名、公证和 Preview 发布必须等待 exact SHA、唯一 Draft PR、两架构检查和 pipeline qualification 全部成功。

失败判定：把“候选 CI 与受保护发布并行”当成快路径，在 PR 检查尚未成功时接触 Apple 凭据。

## 用例 12：签名 staging、真实 UI 验收与幂等 publication

1. 使用 `release_mode=stage-preview` 让受保护 workflow 完成双架构签名、公证、staple、最终验证，并上传唯一 signed artifact 与 `preview-stage.json`；确认此时没有 Tag、GitHub Release 或公开 appcast。
2. 使用 `prepare-staged-preview-ui-test.sh` 下载 exact Run/Artifact，从公开稳定版 `v1.8.3` 建立基线，并通过本地固定 feed 运行真实 Sparkle UI 下载、安装、首次启动、退出和二次启动。
3. 使用 `record-preview-ui-attestation.sh` 记录生产 appcast SHA、仅替换 URL 的测试 appcast SHA、candidate ZIP SHA、稳定基线 asset ID/digest、安装后签名/公证/Gatekeeper、Sparkle helper `0755`、链接、启动顺序和崩溃检查。
4. 从 `main` dispatch `macOS Preview Publication`，确认它精确恢复 staged Run/Artifact、重新计算上述摘要、创建或复用 exact Tag，并发布逐字节相同的 staged assets。
5. 在 Tag 创建后或部分资产上传后注入一次 publication 失败，再运行同一个 publication workflow，确认只补传缺失的 exact assets，既有资产大小或 GitHub digest 不一致时 fail closed。

预期结果：真实 UI 更新发生在公开之前；staging 只运行一次签名/公证；publication 不进入 `mac-release` Environment、不读取 Apple/Notary/Match/Sparkle 私钥；首次发布和恢复共用同一控制面，不新建分支、版本、Build 或签名字节。

失败判定：没有真实 Sparkle UI 安装就公开；先公开最终 appcast 再测试；只按 artifact 名称或最新 Run 猜测来源；Run、SHA、请求、pipeline digest、appcast/ZIP 摘要或任一安装证据不一致仍发布；控制面失败后重新签名、升版本或创建第二候选分支。

## 用例 13：Preview 固定稳定 latest 基线

1. 保持 GitHub `releases/latest` 为当前受审稳定版 `v1.8.3`，执行 Preview 的凭据前状态解析、首次创建和已发布恢复验证。
2. 在隔离 mock 中令 `releases/latest` 返回其他 Tag，分别重跑上述入口。

预期结果：`v1.8.3` 时三个阶段均可继续；任何其他 Tag 都在发布突变前失败，并明确报告期望值和实际值。成功创建或恢复 Preview 后再次确认仍为 `v1.8.3`。

失败判定：只保存执行前值并检查执行后“没有变化”；起点已经错误时仍允许 Preview；Preview 被 GitHub 误标为 latest 后未阻断。

## 稳定功能回归

- `mac-preview-candidate.yml` 的普通候选 Push 仍不读取 Apple 发布证书。
- `release_mode=qualification` 只在 pipeline digest 变化且无可复用证明时执行；qualification ref 必须只是已有普通 PR exact SHA 的 Environment alias，不能创建第二个 PR，只产生 digest 资格证明和必要账本，不创建 Tag、Release、appcast 或产品分发包。
- `release_mode=stage-preview` 只接受唯一 `release/pre-vX.Y.Z` 分支的 exact SHA，且必须复用对应 pipeline digest 资格证明；受保护 workflow 不创建 Tag、Release 或公开 appcast。
- 签名 Job 继续只有 `contents: read`，签名密钥仅在受保护 Environment 中使用；独立 `macOS Preview Publication` workflow 从 `main` 运行，不进入该 Environment、不引用 Apple secrets，只取得发布所需写权限。
- main PR 仍要求 Apple Silicon 与 Intel Ventura 两项必需检查。
- 重试产生多个同名 check 时，候选验证器使用 exact PR/SHA 的最新已完成成功结果，不以“同名 check 数量必须等于 1”拒绝合法重试。
- 普通候选回流 PR 的 CI 不得触发 Stable Promotion；只有正式晋升流程显式调度的候选 CI 才可进入晋升 workflow，且没有 `stable-promotion-approved` 时必须明确跳过。
- 历史 schema 1/2 候选仍可按既有正式晋升流程验证，但新预览候选的 request attestation 使用 schema 5，并必须按 exact candidate SHA/attempt 隔离且记录三个产品依赖 Commit。
- 当前 Preview 的稳定 `latest` 必须在凭据前、发布/恢复和最终公开验证阶段精确等于 `v1.8.3`；未来正式晋升后必须通过独立普通 PR 更新该受审基线。

## 日志收集

- 候选来源：保存 `verify-preview-branch.sh` 的完整输出、候选 SHA、`BASE_MAIN_COMMIT`、pipeline digest 和 `git log -1 --format='%H %P'`。
- 资格验证：保存 qualification Run URL/attempt、artifact ID/digest、原普通 PR 号、exact source Commit、临时 alias ref、pipeline digest、外部依赖 Commit、工具链版本、完成时间和 `release-pipeline-qualification.json`；复用时记录原 PR 已合入、`refs/pull/<n>/head` 重算结果和 Preview exact-match 结果，不记录凭据值。
- attempt：保存 `request_id`、`request_started_at`、candidate SHA、`release_ready_at`、Run manifest 和完成 JSON。replacement 时同时保存旧新 SHA 的关系和变更原因。
- UI 验收：保存 `preview-stage.json`、`preview-ui-attestation.json`、稳定基线 asset ID/digest、production/test appcast SHA、candidate ZIP SHA、两次启动和崩溃检查结果。
- 发布资产：保存 publication Run、`candidate-provenance.json`、canonical asset manifest、Release Guard Run URL、回流 PR URL和两项必需检查结果；资产数量以 manifest 为准。
- 正式晋升：保存晋升前后 Release 状态、`stable-promotion.json` 和资产 SHA-256 对比。
- 失败时不得粘贴 Apple 证书、私钥、API key、Match 密码或 Environment secret；只记录脱敏错误和 workflow step。

## 验证边界

- 自动化可验证分支命名、单候选 SHA、frozen base 祖先关系、pipeline digest、允许文件范围、唯一 PR、attempt attestation 和 manifest 资产摘要。
- 本地回归应覆盖“从当时最新 main 创建通过”、“无关 main 前进后 frozen base 继续有效”、“pipeline digest 变化拒绝”、“重复 PR 拒绝”和“同 SHA 重试不变身份”，不会修改真实远端。
- 代理可只读检查 GitHub Release、workflow、PR 和提交关系；没有用户明确发布授权时不得创建分支、Tag、Release 或执行晋升。
- Environment 审批、真实签名/公证、Intel Ventura 安装和真实 Sparkle UI 升级仍需各自真实环境验收；这些结果不能由静态脚本测试替代，UI 升级未完成时阻断 Preview publication。
