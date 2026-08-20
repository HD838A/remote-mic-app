# macOS 发布墙钟 SLO 验证

## 适用范围

- `macOS Preview Candidate`
- `macOS Signed Release Packages`
- `macOS Stable Promotion`
- metadata-only `release/pre-vX.Y.Z` 候选

## 自动化验证

1. 运行 `actionlint` 检查四条 macOS workflow。
2. 运行 `./scripts/verify-release-workflow-gh-token.sh`，对每个包含 `gh`/GitHub API 调用的 workflow step 做无秘密静态检查，确认显式设置 `GH_TOKEN: ${{ github.token }}`；特别覆盖 `Validate release identity`，并确认该步骤位于任何 Apple 凭据读取之前。
3. 运行 `./scripts/test-release-pipeline-optimization.sh`。
4. 运行 `swift test --filter BuildSigningTests`。
5. 确认 Preview 和 Draft PR 的 metadata-only 路径调用 `verify-release-ready-main-ci.sh`；符合资格时不执行完整产品 CI，不符合时自动执行 Swift tests、Self Test、双架构 Release build 与 ad-hoc DMG 验证。
6. 确认父 `main` 证明必须是精确 SHA 的 push run，并且 Apple Silicon、Intel Job 内的 Swift tests、Self Test 和 Release build 均成功；文档-only main run不得被误复用。
7. 确认真实预览 dispatch 缺少 `request_started_at` 或 `release_ready_at` 会立即失败；两者必须有序且不可由重试重置。
8. 在 workflow 尚未获得 Runner 的场景启动本机 watchdog；确认 Preview 和正式晋升都只在 ready 后 1740 秒内部截止取消本次显式登记的运行，并在 30 分钟前留下明确失败信息。使用 `scripts/release-user-wall-watchdog.sh`，为每个 Run 登记完整的 `requestId`/workflow/SHA/branch/target，轮询间隔有界；不要只依赖 GitHub 队列内 watchdog。
9. 将 Draft PR 的 Apple Silicon 或 Intel required check 分别置为 pending/failed，确认签名 workflow 在接触 Apple 凭据前拒绝继续。
10. 确认双架构签名 composite step 仍为 10 分钟硬限，内部 signed-release supervisor 为 540 秒，publication supervisor 最多 180 秒。
11. 确认 publish Job 不持有 Apple 凭据，签名 Job 没有 `contents: write`；publish Job 才拥有创建 Tag、Release 和 dispatch Guard 所需的最小写权限。
12. 确认正式晋升只调用 `publish-release.sh promote`，不调用任何 build、sign、notary 或 package 脚本。

## 真实发布验收

1. 用户发出发布指令时立即记录 `request_started_at`；代码合入 passing main 后记录 `release_ready_at`，将两者一同传入 workflow。
2. 预览成功时下载 `release-slo-ledger-published-<run-id>`，确认 release-ready 墙钟 `≤1740` 秒，并完整记录从 `request_started_at` 起的总用户等待。
3. 正式晋升成功时下载 `stable-slo-ledger-complete-<run-id>`，确认指定 Pre-release 完成资格冻结后的 release-ready 墙钟 `≤1740` 秒；发布机独立 watchdog 同样必须在运行。
4. 触发 `workflow_run` reconciliation，确认它不会在缺少发布管理任务原始授权时自动进入正式 Environment 或晋升 Release，而是要求回到发布管理任务手动发起指定 Pre-release 晋升。
5. 分别记录候选门禁、Environment/Runner 等待、签名/公证、artifact 交接、发布与公开验证耗时。
6. Apple、GitHub、CDN 或 Environment 审批超过预算时，预期结果是 ready 后 30 分钟内明确失败；不得延长签名门限、重建同一版本或自动重跑。

## 验证边界

- 静态测试可以证明门禁、权限、计时和取消逻辑存在，不能证明 Apple 公证或 GitHub/CDN 每次都在预算内完成。
- Preview 和正式晋升的 ready 后 30 分钟硬指标保证“预算内完成，或预算内明确失败”；`request_started_at` 总耗时必须如实报告。外部服务不可控时不通过跳过签名、公证、staple、Gatekeeper 或公开字节验证来强行成功。
