# Control-plane 合入后 release-ready 错误要求重复产品 CI

## 状态

- 已复现并确认根因。
- 影响：PR #218 只修改资格证明控制面并通过专用 fixture，但其合入后的最新 `main` SHA 没有重新执行产品 Swift 测试和 Release build；旧 verifier 因而拒绝创建 `v1.9.10` 候选。

## 复现与证据

1. 产品合入 Commit `4646267c5a7c3316a5d72e254fa0e473ab22ea8c` 的 main Push Run `32714462994` 完成 Apple Silicon 与 Intel 的 Swift tests、项目 self-test 和 Release build。
2. 证明控制面修复合入 Commit `9ee758a06f39ffd03ac3faf8191bdb4cb7c22ae1` 的 main Push Run `32715180831` 只执行 release control-plane fixture；两个产品 Job 中的完整测试和构建步骤均为 skipped。
3. 旧 `verify-release-ready-main-ci.sh` 只接受目标 main SHA 自身包含完整双架构步骤，因此无法复用其 first-parent 产品证明。

## 根因

Release-ready verifier 把“当前 main 控制面状态”和“最近一次完整产品字节证明”错误地绑定为同一个 SHA。控制面变更没有触及 App、依赖、签名或打包字节，却被迫重新运行完整双架构产品 CI。

## 修复

- 当前 main 自身有完整产品 CI 时保持原行为。
- 当前 main 只有成功的 release control-plane fixture 时，沿 first-parent 有界查找最近的完整双架构 main Push Run。
- 只有从该产品证明 Commit 到当前 main 的完整 diff 通过 `verify-release-control-plane-diff.sh`，才允许继承；任何产品代码、依赖、签名、打包或未允许文件变化都会失败关闭。
- 证明同时记录当前 main Run 与被继承的产品 Commit/Run，使候选冻结和审计仍可追溯。
- 将该只读 CI 证明解析器归入 control-plane 脚本，后续修复不再改变 App 制品闭包 digest，也不触发重复双架构产品 CI。

## 验证边界

- 使用真实 GitHub main Run 验证 `9ee758a0…` 可严格继承 `4646267c…` 的双架构产品证明。
- 使用 fixture 验证普通完整 main 仍通过，错误 SHA、缺少 Intel 或仅文档 Run 仍失败。
- 普通 PR 必须由 macOS CI 分类为 release-control-plane-only；完整 Swift tests、自检和 Release build 均不得执行。
