# DEBUG：治理改动误触发产品矩阵与 main CI 取消

- 时间：2026-10-02
- 状态：候选修复、应用前审查与本地回归通过，待 PR/main CI
- 范围：CI 分流、并发和发布 CI 证明；不改产品功能、依赖、签名或公证门禁
- 基线：`25ddb362d2957c0d0fda74f91f1f0ba3711e135b`

## Observations：复现与日志

原样运行 `scripts/verify-release-control-plane-diff.sh --classify 5a10bba28bd1514892a2a7400ae594629f728da7 66cfdceccc17b2ddf56be43b822b51ef38de304a`。
四个改动文件只有 AGENTS.md、DOCUMENTATION.md、PR 模板及治理守护脚本，却输出 `product_change=true release_checks=true`；正常结果应只检查仓库治理，不执行 Swift 或私有依赖构建。

[#547 PR CI](https://github.com/HD838A/remote-mic-app/actions/runs/36969902701) 用时 21分32秒，分类器排队 316秒，Intel free lane 排队 367秒；治理 job 仅执行 7秒。产品构建耗时和外部 runner 排队是不同阶段，不能保证 GitHub 排队时间。

[#547 main CI](https://github.com/HD838A/remote-mic-app/actions/runs/36971772831) 最终为 cancelled，不是产品测试已经确认失败。官方 check annotation：`Canceling since a higher priority waiting request for mac-ci-macOS CI-refs/heads/main exists`。还提示 macOS arm64 runner 容量限制；没有账号具体配额证据。

## Hypotheses

1. 分类器未知脚本兜底把治理脚本归为产品（ROOT HYPOTHESIS）。支持：原始四文件 diff 可重复输出；反证：无。实验：只读重放原始分类命令。
2. 分类算法计算慢。支持：分类 job 整体等了数分钟；反证：实际分类命令不到一秒。实验：核对 job 排队与步骤时间，排除计算慢，确认是 Mac runner 排队。
3. main 测试自身失败。支持：summary failure；反证：四个私有 job 被取消。实验：查看最终 run 和 check annotation，排除已确认测试失败，确认同 ref 自动取消。
4. 只改 `cancel-in-progress=false` 就能保留所有 main 验证。支持：可避免取消 running；反证：同 group 的 pending 仍可能被新 pending 替换。实验：审查 concurrency 语义；main/hotfix 按 SHA 隔离，PR 才按 ref 取消。

## Experiments 与 Root Cause

以上只读实验已完成，无需制造真实取消事故。根因是非产品改动缺少精确治理分类、轻量任务占用 Mac runner，以及所有 main SHA 共用可取消的 concurrency group。

## 应用前 Code Review

本次为主代理自审，非独立人员审查。应用前按以下具体条件核对拟议补丁：

- 精确 allowlist 只涵盖治理守护和文档；未知脚本、混合产品路径、mac-ci.yml 和分类器自身改动不豁免。
- 分类器从 zsh 改为 macOS Bash 3 / Ubuntu Bash 均支持的语法；路径解析、正则和输出同步迁移，Git diff 错误不得被 process substitution 吞掉。
- 公开 required job 名称不变；非产品 lane 用 Ubuntu，治理检查真实执行；未知分类或分类失败不能生成绿灯。发布控制面仍执行双架构原 fixture。
- PR 保留按 ref 自动取消；main/hotfix 按 SHA 分组且不自动取消，避免 pending 替换。
- 快速 CI 必须通过精确 SHA、branch、push、success 检查；只能继承同分支 first-parent 成功产品证明，重新分类整个祖先差异。没有证明、差异含产品、公共架构不完整时拒绝。
- 保留本次完整 PR/main CI，不让 CI 修复自我豁免；不增加脚本或产品改动。

## Fix 与验证

修改五个现有文件：分类器增加精确治理分流并迁移 Bash；mac-ci.yml 将轻量检查移到 Ubuntu、隔离 source SHA 并显式拒绝未知分类及不完整私有结果；release-ready verifier 识别真实治理检查，但继续继承独立产品证明；现有正式 fixture 增加回归；RELEASING.md 说明证明边界。没有新增脚本（仍为 38 个 `.sh`）、产品源码或核心治理修改。

第二轮 diff review 逐项复核 allowlist、required job 名称、公开/私有矩阵、发布控制面双架构 fixture 和证明继承。负向回归发现 macOS Bash 3 的 `set -e` 对复合 `[[ ... || ... ]]` 不可靠，显式增加 `|| exit 1` 后未知分类正确拒绝。此问题在远端应用前修正。

已执行并通过：

- 原始 #547 四文件 diff：现为 `repository_only=true product_change=false release_checks=false`。
- `scripts/test-macos-release-flow.sh all`：原发布流程、元数据、16种路径分类、mixed/docs、无效 diff、12组真实 summary shell 输入、现代公共产品证明、control/tooling/repository 继承、错 SHA、PR event、检查失败和未验证产品变化拒绝。
- macOS `/bin/bash` 3.2 语法和执行；zsh fixture 语法检查。
- `actionlint .github/workflows/mac-ci.yml`、YAML 解析、`git diff --check`、`verify-repository-governance.sh <baseline>` 和 `check-repository-boundaries.sh`。

未在本地重复编译未改变的产品；远端 PR/main 完整公开双架构和可访问的私有四 lane 仍为门禁。调度表达式及失败门禁已自动验证；真实 GitHub runner 分流与 main 结果仍须远端 CI 确认，不保证外部排队时间。本次不涉及真机产品验收、Apple 凭据或发布包。外部手工取消仍可停止 CI。
