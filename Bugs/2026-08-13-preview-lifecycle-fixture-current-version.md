# 真实候选版本号导致预发布生命周期测试夹具失败

- 时间：2026-08-13
- 状态：已修复，自动化验证通过
- 影响范围：macOS 预发布候选 CI；Apple Silicon 与 Intel Ventura 两条候选任务
- 功能点：`release/pre-v*` 来源和版本生命周期回归测试
- 简单描述：创建真实 `release/pre-v1.8.15` 候选后，生命周期测试把当前候选 Build 107 复制成模拟的 `v1.8.14`，导致模拟 `v1.8.15 (107)` 被错误判定为 Build 未递增。
- 原始记录：GitHub Actions Run `31713606764`，两架构均在 `previewBranchLifecycleHasExecutableRegressionCoverage` 失败。

## 复现

在 `release/pre-v1.8.15` 候选提交 `05124e05` 上运行：

```zsh
./scripts/test-preview-branch-lifecycle.sh
```

失败输出：

```text
CFBundleVersion 107 must be greater than 107 from v1.8.14
```

正常边界：测试夹具的模拟 `v1.8.14` 应固定为 Build 106，模拟 `v1.8.15` 使用 Build 107 并通过；随后从该候选串联的模拟 `v1.8.16` 仍应被来源门禁拒绝。

## 日志结论

GitHub Actions 两架构日志均显示 Swift 编译和其他测试正常，唯一失败项是 `BuildSigningTests.swift` 中执行生命周期脚本后的退出码断言。Homebrew 的 `aws/tap` 信任提示是 runner 环境警告，不是退出原因。

## 根因

`scripts/test-preview-branch-lifecycle.sh` 从仓库当前 `Resources/Info.plist` 复制测试基线，但没有在创建模拟 `v1.8.14` Tag 前重置版本和 Build。仓库进入真实 `1.8.15 (107)` 候选后，模拟旧 Tag 因而也错误地成为 Build 107。

生产验证器 `scripts/verify-preview-branch.sh` 的版本单调性判断正确；错误只存在于测试夹具初始化。

## 修复

在测试夹具提交模拟主线前，显式把复制的 `Info.plist` 设置为 `1.8.14 (106)`。不修改生产候选验证器、GitHub Actions 或产品代码。

## 验证

重新执行原始复现脚本，要求同时满足：

- 模拟 `release/pre-v1.8.15` 输出 `PREVIEW BRANCH PASS`；
- 模拟串联 `release/pre-v1.8.16` 仍因父提交不等于最新 `origin/main` 而失败；
- 脚本最终输出 `PREVIEW BRANCH LIFECYCLE TEST PASS`；
- `swift test --filter BuildSigningTests` 通过。

本 Bug 只涉及自动化测试数据，不涉及 GUI、真实硬件、签名、公证或安装包运行时行为，无需真机验收。
