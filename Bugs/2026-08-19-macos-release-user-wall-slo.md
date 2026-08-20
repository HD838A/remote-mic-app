# macOS 发布用户墙钟与重复构建

> 2026-08-21 规则更新：本文件记录的“用户请求起 30 分钟、release-ready 后 15 分钟”是当时实现。当前规则已统一为 Preview 和正式晋升均从 `release_ready_at` 起拥有 30 分钟纯发布窗口；`request_started_at` 继续用于完整耗时账本和交付汇报，不再作为截短纯发布窗口的硬取消条件。

## 现场与复现

- 用户确认 `1.9.0` 从发布指令到最终结果约 2 小时，`1.9.1` 约 46 分钟。
- 旧统计从候选 Commit 或 GitHub Run 开始，遗漏候选准备、代理交接、Environment 等待、失败修复、artifact 本机中转、公开验证和最终回复，因此低估用户真实等待。
- metadata-only 候选仍依次运行 Preview 双架构完整测试/DMG、Draft PR 双架构完整 CI、正式签名双架构构建。同一产品代码被编译三次。

## 日志与代码结论

- `1.9.0` Preview 约 5 分钟，首次签名约 5 分钟后失败，但发布任务还包含失败诊断、修复和重新执行；GitHub 成功 Run 时长不是用户墙钟。
- `1.9.1` Preview 约 5 分钟、PR CI 约 4 分钟、签名约 9 分钟，候选前准备、Environment/交接和最终验证继续位于这些 Run 之外。
- 重复入口位于 `.github/workflows/mac-preview-candidate.yml`、`.github/workflows/mac-ci.yml` 和 `.github/workflows/mac-release-package.yml`。
- 原签名 workflow 只上传 Actions artifact，随后由本机下载、再上传 GitHub Release，增加一次人工交接和网络往返。

## 根因

1. 没有从用户指令开始的统一 `request_started_at` 和阶段账本。
2. 仅在 GitHub workflow 内运行 watchdog，无法覆盖 workflow 自身的 Runner 排队、额度阻断和候选/PR/Preview 准备时间。
3. 签名前只验证 Draft PR 存在，没有验证其双架构 required checks 已完成并成功。
2. Preview 与 PR CI 没有识别“最新 passing main 的单个 metadata-only 直接子提交”，无法安全复用父 `main` 双架构证明。
3. 签名产物与 Release 发布分属 GitHub Actions 和本机，CI 成功后仍依赖人工继续。
4. Environment、Apple、GitHub 和 CDN 等待没有覆盖整次用户墙钟的 watchdog。

## 修复

- 新增严格 metadata-only diff 门禁与父 `main` exact-SHA CI 复用校验；要求两种架构 Job 真正执行 Swift tests、Self Test 和 Release build，拒绝 docs-only 假成功。
- 候选 Push 后即可创建 Draft PR，使 Preview 和 PR CI 并行；两条 PR required context 保持名称不变。
- 签名保持双架构真实重建、Developer ID、公证和 10 分钟硬限，内部 supervisor 收紧到 540 秒。
- 在同一 workflow 中增加不持有 Apple 凭据的 publish Job，直接消费签名 artifact、创建不可变 Tag/Pre-release，并完成 GitHub/CDN 并行逐字节验证。
- 当时实现为双时钟 watchdog：用户请求起总计 30 分钟、代码 release-ready 后 15 分钟。该规则已由 2026-08-21 的统一 ready 后 30 分钟规则取代；重试、重建或重新 dispatch 仍不得重置时间戳。
- 稳定晋升继续只复用预览原字节，不进入签名、公证或打包。

## 验证

- `actionlint`：四条 macOS workflow 通过。
- `scripts/test-release-pipeline-optimization.sh`：通过；覆盖 main CI success、wrong SHA、missing Intel、docs-only 假成功、metadata-only success、产品代码拒绝、ledger invalid/future/pass/report/overrun 124。
- `swift test --filter BuildSigningTests`：15 项通过。

## 边界

- 静态和 fake-service 自动化不能证明 Apple 公证或 GitHub/CDN 每次都在预算内完成。
- 当前硬指标定义为 Preview 和正式晋升均在 ready 后 30 分钟内“成功或明确失败”；外部服务过慢时不允许跳过签名、公证、staple 或公开字节验证来制造成功。
- 修改后的真实 Developer ID 路径在合入 `main` 前仍需受保护 canary 验证；本提交不 Push、不运行真实发布。
