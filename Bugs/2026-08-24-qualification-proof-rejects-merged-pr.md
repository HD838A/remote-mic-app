# Qualification 证明记录错误拒绝已合并 PR

## 状态

- 已复现并确认根因。
- 修复目标：普通 PR 与 release control-plane fixture 通过后合入，再恢复 `v1.9.10` 预览发布。
- 失败 Run：`32713713953`，失败步骤：`Record protected release pipeline qualification`。

## 复现与日志

1. 对 PR #217 的 exact SHA `9494fed8e491e4d7c1d1b124726aaf56b73bbf9a` 启动 protected pipeline qualification。
2. PR 的 Apple Silicon 与 Intel 普通 CI 通过后，PR 在 qualification 仍执行签名、公证时正常合入 `main`。
3. Qualification 的双架构签名、公证、staple 和制品验证全部成功。
4. 最后记录证明时，workflow 使用 `.state == "open"` 查询来源 PR；此时 PR 已为 merged，因此 `source_pr` 为空并以 exit 1 失败。

前置 `verify-release-pipeline-qualification-source.sh` 已明确接受唯一的 open 或 merged PR。失败不是 App、签名、公证或私有依赖问题，而是证明记录步骤与前置来源规则不一致。

## 根因

`.github/workflows/mac-release-package.yml` 的 qualification 证明记录逻辑只接受 open PR；同一 workflow 前置校验则接受 open 或 merged PR。普通 CI 自动合入和 protected qualification 并行时，PR 状态在两个步骤之间发生合法变化，触发竞态。

## 修复

- 证明记录查询改为接受唯一的 open 或 merged PR，同时继续严格校验目标分支、exact head SHA 和同仓库来源。
- `verify-release-control-plane-diff.sh` 只把这两个等价 PR 状态表达式归一化，确保该证明控制面修复走单机 release-control-plane fixture，不重复运行双架构 App CI。
- `test-release-resume-workflow.sh` 增加静态回归断言，防止记录逻辑再次退回仅接受 open PR。

## 验证边界

- 本地执行 `scripts/test-release-resume-workflow.sh`、`scripts/test-release-pipeline-optimization.sh`、`scripts/verify-release-control-plane-diff.sh <base> HEAD` 和 `git diff --check`。
- 普通 PR 只运行 release control-plane fixture，不把证明写入修复误分类为 App 字节变化。
- 真实 Developer ID/Notary 已在失败 Run 的签名步骤通过；修复合入后恢复 qualification 证明与预览发布。任何未生成的资格 artifact 不能从本地结果推断为已经存在。
