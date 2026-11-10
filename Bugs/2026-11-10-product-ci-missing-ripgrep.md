# 纯产品 PR 的默认公开 App 校验缺少 ripgrep

- 时间：2026-11-10
- 状态：**修复已实现；真实 Xcode 27 runner 结果以当前 PR 的 GitHub CI 为准**
- 影响范围：纯产品改动的 `macOS CI` 必需检查；完整测试和双架构构建通过后，默认公开 App 校验仍会失败并阻塞 PR 进入 Ready
- 现场证据：PR #954 的 GitHub Actions Run 42746467290

## Observations

- PR #954 的 `Run Swift tests`、核心首次语音旅程门禁、项目自检、Apple Silicon Release 构建和 Intel Ventura Release 构建全部通过。
- `Build the default public App` 已完成公开模式编译、App 组装和签名，随后 `scripts/verify-app.sh` 在第一个 `rg` 调用处报告 `command not found: rg`，以退出码 127 失败。
- 同一主线提交的 push CI 可以通过默认公开 App 校验。该次提交包含发布控制面改动，因此 `release_checks=true`，在运行 App 校验前执行了安装 `ripgrep` 的发布 fixture 步骤。
- 纯产品 PR 的 `release_checks=false`，上述发布 fixture 被跳过；这解释了相同 runner 标签和主线代码下结果不同，不是 Onboarding 实现或 App 打包字节导致。

## Root Cause

`.github/workflows/mac-ci.yml` 把 `ripgrep` 安装放在仅当 `release_checks=true` 才运行的发布 fixture 中，但 `scripts/verify-app.sh` 是纯产品路径的必执行校验，并长期使用 `rg` 检查本地化、签名、Mach-O 元数据和包内容。

因此工具准备条件小于实际消费者条件：`product_change=true, release_checks=false` 时 job 使用 Xcode 27 macOS runner，却没有保证 `rg` 存在。runner 镜像偶尔预装该命令不能构成 CI 契约。

## 修复

在公共 macOS job checkout 后增加统一工具准备步骤。当 `product_change=true` 或 `release_checks=true` 时，先检查 `rg`，缺失时通过 Homebrew 安装 `ripgrep`。docs/tooling/repository-only 路径继续使用 Ubuntu 且跳过该步骤。

保留发布 fixture 内已有的防御性检查，避免扩大本次修复到发布流程重构；命令已存在时不会重复安装。现有 release-flow fixture 增加静态回归，锁定工具准备同时覆盖纯产品和发布路径，并位于后续产品校验之前。

## 验证与边界

- 本地执行 workflow YAML 解析、Shell 语法和 `scripts/test-macos-release-flow.sh`。
- 本 PR 自身会因修改 `mac-ci.yml` 运行完整产品和发布门禁，用真实 Xcode 27 runner 验证工具准备与默认公开 App 校验。
- 本次不修改 `scripts/verify-app.sh` 的校验内容，不修改产品源码、依赖、签名、公证或发布行为。
- PR #983 已合入并同步到本分支；它调整发布 fixture 的执行顺序，不覆盖纯产品路径的工具准备，两个改动保持互补。
