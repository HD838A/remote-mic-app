# 分支与提交管理策略

本文件统一规定本仓库的分支、工作区、提交和 Push 边界。具体 macOS 发布步骤仍以 [`RELEASING.md`](RELEASING.md) 为准。

## 主分支不变量

- `main` 必须始终与最新已获取的 `origin/main` 精确一致；检查或交付前必须先 fetch 远端并重新核对 SHA。
- 不得在 `main` 工作区直接开发功能、修复 Bug 或临时保存未提交改动；产品工作必须使用独立分支和 worktree。
- 每个功能或 Bug 分支都必须从最新已获取的 `origin/main` 创建；创建前必须 fetch 并确认分支基线与 `origin/main` 的 SHA 一致。
- 每个功能或 Bug 分支提交 PR 时，目标分支必须是远端 `main`（即 GitHub 上的 `origin/main`）；不得将 PR 指向旧分支、候选分支或其他工作分支。
- 分支、worktree、提交或发布操作不得为了方便而让 `main` 暂时承载其他工作项；完成操作后仍必须恢复 `main == origin/main`。

## 独立工作项提交边界

- 每个独立功能、新增需求或 Bug 修复完成必要验证后，必须先创建一个仅包含该工作项的 commit，才能继续开发下一个工作项，避免多个已完成工作堆叠在同一未提交工作区中。
- 默认只 commit、不 Push；只有用户明确要求 Push 时才允许 Push。用户明确要求本次不 commit 时，服从用户要求。
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
- 每个候选版本使用一次性的 `release/pre-vX.Y.Z` 分支，并从最新 `origin/main` 创建。
- 候选分支只允许修改版本号、Build、中英文版本历史和必要的测试手册目标版本；Push 后由 GitHub Actions 自动校验来源、运行完整 Mac 测试并生成临时 CI App 包。
- 精确候选 SHA 的 Apple Silicon 与 Intel 候选 Job 成功后，可提前创建候选分支到 `main` 的 Draft 回流 PR，让受保护 PR CI 与正式签名、公证并行；公开 Release 字节、provenance 和固定候选更新验证完成前，该 PR 必须保持 Draft，禁止 Ready 或合并。
- 公开 Pre-release 仍必须使用 Developer ID 签名、公证、Sparkle 签名和公开资产复核；GitHub CI 的 ad-hoc App 不能当作公开安装包。
- 候选 Tag、远端候选分支和发布资产必须指向同一提交；候选分支在正式晋升完成前不得删除或 force-push。
- 不存在“发布正式版”命令。正式版只能由用户明确指定一个已发布并验证的 Pre-release，再将该预览版的同一 Tag、Commit 和同一批资产晋升为正式版；禁止从 `main` 重新构建正式包。
- 完整流程与 Release Notes 规则见 [`RELEASING.md`](RELEASING.md)。
