# macOS 发布分支生命周期测试手册

## 适用范围

- 适用分支：包含候选基线、provenance schema 2 和候选回流门禁的 `main` 及后续 `release/pre-vX.Y.Z`。
- 适用流程：macOS Preview Candidate、macOS Signed Release Packages、Release Guard、macOS CI、macOS Stable Promotion。
- 本手册只验证发布分支与资产生命周期，不代替 App 功能、安装、Intel Ventura、签名或公证的专项验收。

## 测试前准备

1. 使用干净工作区，执行 `git fetch origin main --tags`，确认本地 `main` 与 `origin/main` 一致。
2. 选择尚未使用的测试版本和递增 build；候选分支必须命名为 `release/pre-vX.Y.Z`。
3. 候选只修改 `Resources/Info.plist` 的版本/build、两份 `ReleaseHistory.md` 和必要的 `Testing/*.md`。
4. 真正发布 Pre-release 前，仍需通过受保护 Environment 审批、两种架构打包、签名、公证及下载字节校验。

## 用例 1：从最新 main 创建单提交候选

1. 从最新 `origin/main` 创建 `release/pre-vX.Y.Z`。
2. 完成允许的发布元数据修改并生成一个普通提交。
3. Push 候选分支，运行 `./scripts/verify-preview-branch.sh`。

预期结果：输出 `PREVIEW BRANCH PASS`，`BASE_MAIN_COMMIT` 等于候选直接父提交和当时最新 `origin/main`，候选相对 main 只有一个提交。

失败判定：候选包含多个提交、merge commit、父提交不是最新 main，或包含产品代码时仍通过。

## 用例 2：禁止从旧预览分支或 Tag 串联

1. 以旧 `release/pre-vA.B.C` 或对应 Tag 为起点创建新的 `release/pre-vX.Y.Z`。
2. 更新版本元数据并运行候选校验。

预期结果：校验失败，并明确提示候选直接父提交必须精确等于最新 `origin/main`，应重新从 main 创建。

失败判定：只因 main 是历史祖先就允许候选通过。

## 用例 3：禁止候选承载产品代码

1. 在合规候选中额外修改 `Sources/`、`Apps/`、`Package.swift` 或其他非允许文件。
2. 运行候选校验。

预期结果：校验列出首个非发布改动，并要求先将产品代码通过 PR 合入 main。

失败判定：产品代码进入候选或只在发布后才被发现。

## 用例 4：Pre-release 发布后回流 main

1. 完成签名、公证和本地验证，发布 schema 2 的 GitHub Pre-release。
2. 等待发布脚本完成 GitHub/CDN 下载字节比较，并确认它调度 Release Guard。
3. 检查 Release Guard 创建标题为 `Record vX.Y.Z preview candidate in main` 的 PR，并启用 auto-merge。
4. 等待 Apple Silicon 与 Intel Ventura 必需检查通过。

预期结果：候选提交通过 merge commit 进入 main；GitHub Release 仍为 Pre-release；Tag 和所有签名、公证资产未变化，未运行正式晋升。

失败判定：下载字节未验证就创建回流 PR、PR 绕过必需检查、Release 被改为正式版、Tag 或资产被重建/替换。

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

## 稳定功能回归

- `mac-preview-candidate.yml` 的普通候选 Push 仍不读取 Apple 发布证书。
- `mac-release-package.yml` 继续只有 `contents: read`，签名密钥仅在受保护 Environment 中使用。
- main PR 仍要求 Apple Silicon 与 Intel Ventura 两项必需检查。
- 普通候选回流 PR 的 CI 不得触发 Stable Promotion；只有正式晋升流程显式调度的候选 CI 才可进入晋升 workflow，且没有 `stable-promotion-approved` 时必须明确跳过。
- 历史 schema 1 候选仍可按既有正式晋升流程验证，但不会因普通 Pre-release 事件自动回流 main。

## 日志收集

- 候选来源：保存 `verify-preview-branch.sh` 的完整输出、候选 SHA、`BASE_MAIN_COMMIT` 和 `git log -1 --format='%H %P'`。
- 发布资产：保存 `candidate-provenance.json`、Release Guard run URL、回流 PR URL、两项必需检查结果。
- 正式晋升：保存晋升前后 Release 状态、`stable-promotion.json` 和资产 SHA-256 对比。
- 失败时不得粘贴 Apple 证书、私钥、API key、Match 密码或 Environment secret；只记录脱敏错误和 workflow step。

## 验证边界

- 自动化可验证分支父子关系、允许文件范围、provenance、PR/CI 门禁和资产摘要。
- 本地执行 `./scripts/test-preview-branch-lifecycle.sh` 可在临时 bare remote 中验证“从最新 main 创建单候选提交通过、从旧候选串联失败”，不会修改真实远端。
- 代理可只读检查 GitHub Release、workflow、PR 和提交关系；没有用户明确发布授权时不得创建分支、Tag、Release 或执行晋升。
- Environment 审批、真实签名/公证、Intel Ventura 安装和可见 App 行为仍需各自真实环境验收；这些结果不能由静态脚本测试替代。
