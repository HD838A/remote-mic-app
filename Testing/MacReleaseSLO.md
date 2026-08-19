# macOS 发布墙钟 SLO 验证

## 适用范围

- `macOS Preview Candidate`
- `macOS Signed Release Packages`
- `macOS Stable Promotion`
- metadata-only `release/pre-vX.Y.Z` 候选

## 自动化验证

1. 运行 `actionlint` 检查四条 macOS workflow。
2. 运行 `./scripts/test-release-pipeline-optimization.sh`。
3. 运行 `swift test --filter BuildSigningTests`。
4. 确认 Preview 和 Draft PR 的 metadata-only 路径调用 `verify-release-ready-main-ci.sh`，且没有执行 `swift test`、`scripts/test.sh`、`build-dmg.sh` 或 `swift build`。
5. 确认父 `main` 证明必须是精确 SHA 的 push run，并且 Apple Silicon、Intel Job 内的 Swift tests、Self Test 和 Release build 均成功；文档-only main run不得被误复用。
6. 确认真实预览 dispatch 缺少 `request_started_at` 会立即失败；达到 900 秒时 watchdog 只取消一次，不 dispatch 重试。
7. 在 workflow 尚未获得 Runner 的场景，以用户请求时间后台启动本机 `release-user-wall-watchdog.sh`；确认 840 秒内部截止会取消本次 run-id 文件中显式登记的 Preview、PR CI 和签名 workflow，并在 15 分钟用户截止前留下明确失败信息。空 run-id 文件不得取消任何运行，非法 ID 必须忽略，其他版本的并行发布不得受影响。
8. 将 Draft PR 的 Apple Silicon 或 Intel required check 分别置为 pending/failed，确认签名 workflow 在接触 Apple 凭据前拒绝继续。
7. 确认双架构签名 composite step 仍为 10 分钟硬限，内部 signed-release supervisor 为 540 秒，publication supervisor 最多 180 秒。
8. 确认 publish Job 不持有 Apple 凭据，签名 Job 没有 `contents: write`；publish Job 才拥有创建 Tag、Release 和 dispatch Guard 所需的最小写权限。
9. 确认正式晋升只调用 `publish-release.sh promote`，不调用任何 build、sign、notary 或 package 脚本。

## 真实发布验收

1. 用户发出发布指令时立即记录 Unix epoch 秒，并作为 `request_started_at` 传入 workflow。
2. 预览成功时下载 `release-slo-ledger-published-<run-id>`，确认总墙钟 `≤840` 秒，留出最多 60 秒回报用户；整个 Run 的 900 秒 watchdog 不应触发。
3. 正式晋升成功时下载 `stable-slo-ledger-complete-<run-id>`，确认总墙钟 `≤1740` 秒，整个 Run 的 1800 秒 watchdog 不应触发；发布机独立 watchdog 同样必须在运行。
4. 触发 `workflow_run` reconciliation，确认它不会在缺少原始用户请求时间戳时自动进入正式 Environment 或晋升 Release，而是要求回到发布管理任务手动发起 exact-version 晋升。
4. 分别记录候选门禁、Environment/Runner 等待、签名/公证、artifact 交接、发布与公开验证耗时。
5. Apple、GitHub、CDN 或 Environment 审批超过预算时，预期结果是预算内明确失败；不得延长签名门限、重建同一版本或自动重跑。

## 验证边界

- 静态测试可以证明门禁、权限、计时和取消逻辑存在，不能证明 Apple 公证或 GitHub/CDN 每次都在预算内完成。
- 15/30 分钟硬指标保证“预算内完成，或预算内明确失败”；外部服务不可控时不通过跳过签名、公证、staple、Gatekeeper 或公开字节验证来强行成功。
