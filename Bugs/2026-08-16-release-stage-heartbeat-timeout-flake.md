# 发布阶段 heartbeat 与 timeout 同时到期导致 CI 偶发失败

- 时间：2026-08-16
- 状态：已修复
- 影响范围：macOS CI 的发布流程回归测试；不影响已生成安装包、签名、公证或 10 分钟发布门禁
- 功能点：macOS 发布阶段 supervisor 与 `optimizedReleasePipelineHasExecutableRegressionCoverage()`
- 简单描述：Hosted Runner 出现短暂调度停顿时，阶段恢复后先执行 timeout，跳过已到期 heartbeat，使回归测试误报失败并需要重跑。

## 观察与 CI 日志

两个独立架构在首次运行时出现相同失败，重跑同一提交后通过：

- Run `31939540417` attempt 1，Apple Silicon Job `95146604289`：测试在约 6.2 秒后因子脚本退出 `1` 失败；attempt 2 通过。
- Run `31943321950` attempt 1，Intel Job `95155520580`：测试在约 5.9 秒后因子脚本退出 `1` 失败；attempt 2 通过。

两次日志均停在 `BuildSigningTests.swift` 对子脚本退出码的断言。测试原先把 stdout/stderr 接入匿名 `Pipe`，失败原因没有进入 CI 日志。

## 复现

直接运行 `scripts/test-release-pipeline-optimization.sh` 20 次均通过，每次约 6–9 秒，说明不是确定性脚本错误。

使用以下等价实验模拟 Runner 在阶段启动后暂停调度：

1. 启动 `run-release-stage.sh`，timeout 为 2 秒、heartbeat 为 1 秒。
2. 等待 `RELEASE STAGE START` 后暂停 supervisor 进程 3 秒。
3. 恢复进程。

修复前稳定得到：

```text
RELEASE STAGE START lane=test stage=scheduler-pause timeout=2s
RELEASE STAGE TIMEOUT lane=test stage=scheduler-pause elapsed=3s limit=2s
```

已到期的 `RELEASE STAGE HEARTBEAT` 缺失，与回归脚本的可执行日志门禁冲突。

## 根因

`scripts/run-release-stage.sh` 在每次轮询中先判断 timeout，再判断 heartbeat。当调度停顿一次跨过 heartbeat 与 timeout 两个截止点时，timeout 分支立即清理进程树并 `break`，heartbeat 分支永远不会执行。

回归脚本使用 1 秒 heartbeat 和 2 秒 timeout 来快速覆盖两种行为，因此比真实 590 秒发布上限更容易撞到这一调度窗口。测试检查的是 supervisor 的可观测性，不应因 Runner 调度顺序随机失败。

## 修复

- `scripts/run-release-stage.sh`：同一次轮询先输出已经到期的 heartbeat，再执行 timeout 与原有进程树清理；没有改变 timeout 数值、退出码或清理逻辑。
- `Tests/RemoteMicTests/BuildSigningTests.swift`：固定 heartbeat 判定必须位于 timeout 判定之前，并在子脚本失败时输出 stdout/stderr，避免以后只能看到退出码。

## 验证

- 原始暂停调度实验：修复前稳定只有 timeout、缺少 heartbeat；修复后恢复时依次出现 heartbeat 与 timeout，timeout 和进程树清理仍执行。
- `scripts/test-release-pipeline-optimization.sh`：8 路并发、4 轮，共 32 次全部通过。
- `swift test --filter optimizedReleasePipelineHasExecutableRegressionCoverage`：修复后连续 7 次通过，其中最新 `origin/main` 基线上通过。
- `swift test --skip-build`：224 项测试全部通过。
- `zsh -n scripts/run-release-stage.sh scripts/test-release-pipeline-optimization.sh` 与 `git diff --check`：通过。

## 验证边界

这是发布 supervisor 的自动化与日志顺序修复，不涉及 App 运行时、界面、蓝牙、音频或真实硬件。没有重新签名、公证或发布安装包；本修复也不授权 Tag、Release 或其他发布操作。
