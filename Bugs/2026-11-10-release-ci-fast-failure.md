# 发布流程 CI 快速失败

## 错误证据与根因

旧 CI 在 Swift 编译后才通过 BuildSigningTests 执行 Shell/Python 发布夹具。纯发布回归脚本未列入控制面 allowlist，导致发布逻辑修改反复触发完整产品构建。可通过分类器输入单文件改动复现。

## 修复

完整发布夹具作为独立前置步骤，在 Swift 编译前执行。BuildSigningTests 在 CI 跳过已经单独执行的该项夹具，保留其余全部检查和本地默认行为。明确的发布契约、内容校验、supervisor 和回归脚本列入控制面 allowlist。CI、分类器、依赖与未知路径继续完整验证，混合产品改动也拒绝快速路径。

## 回归

`scripts/test-macos-release-flow.sh` 包含单文件、混合产品、未知路径、无效 Git 范围和 CI 顺序检查。`swift test --disable-keychain --filter BuildSigningTests --skip releaseControlPlaneFixtureHasExecutableRegressionCoverage` 验证保留的 Swift 检查。真实 CI 的排队与运行耗时另行记录。
