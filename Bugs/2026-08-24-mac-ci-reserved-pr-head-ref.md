# macOS CI 候选 PR 分支名被保留变量覆盖

- 时间：2026-08-24
- 状态：已修复，本地自动化通过；等待普通 PR CI 与受保护 pipeline qualification 复验
- 影响范围：`release/pre-vX.Y.Z` 的 Draft 回流 PR metadata-only CI；不影响 App 产品代码、签名身份或已生成资产
- 原始记录：PR `#191`，macOS CI Run `32681817795`

## 复现

1. 从 metadata-only 候选分支 `release/pre-v1.9.9` 创建指向 `main` 的 Draft PR。
2. 分类 Job 使用 `PR_HEAD_REF` 显式调用受信校验脚本并成功识别候选分支。
3. 两个架构 Job checkout PR Head 后执行 `Reuse exact parent main CI for release metadata`。
4. 该步骤日志中的 YAML 环境显示 `GITHUB_REF_NAME=release/pre-v1.9.9`，但受信脚本报错：`release metadata verification requires the single candidate branch release/pre-vX.Y.Z`。

正常边界：metadata-only PR 必须复用其直接父 `main` 的精确双架构证明，同时受信脚本必须收到 PR Head 分支 `release/pre-vX.Y.Z`，不能收到 `pull/<n>/merge`。

## 日志结论

候选 Push workflow Run `32681792438` 的 Apple Silicon 与 Intel metadata-only 门禁均成功。PR Run `32681817795` 的分类 Job 也成功，两个架构 Job 仅在同一受信校验调用处于约一秒内失败；没有执行 Swift 测试、产品构建、签名、公证或发布资产上传。

## 根因

`mac-ci.yml` 在步骤级 YAML `env` 中尝试把 `${{ github.head_ref }}` 写入 `GITHUB_REF_NAME`。`GITHUB_*` 是 GitHub Actions 保留的默认环境变量，不能依赖 YAML 覆盖。PR Job 因而仍可能把 merge ref 传给子进程，受信脚本正确地拒绝了不符合 `release/pre-vX.Y.Z` 的分支名。

分类 Job 没有失败，是因为它使用普通变量 `PR_HEAD_REF`，并在执行命令的同一个 shell 环境中显式设置 `GITHUB_REF_NAME="$PR_HEAD_REF"`。

## 修复

- 步骤环境改用非保留变量 `PREVIEW_CANDIDATE_BRANCH` 接收 `${{ github.head_ref }}`。
- 调用受信脚本时，在同一 shell 命令上显式设置 `GITHUB_REF_NAME="$PREVIEW_CANDIDATE_BRANCH"`。
- 发布流水线回归脚本同时要求上述显式传递，并拒绝再次通过 YAML `env` 覆盖保留变量。

## 验证

本地已执行：

```zsh
actionlint .github/workflows/mac-ci.yml
zsh -n scripts/test-release-pipeline-optimization.sh
./scripts/test-release-pipeline-optimization.sh
git diff --check
```

以上门禁全部通过。新增结构断言也已确认会拒绝 `origin/main` 中通过 YAML `env` 覆盖保留变量的旧 workflow。最终真实边界由普通 PR 的 Apple Silicon/Intel metadata-only Job 与同一 PR exact SHA 的受保护 pipeline qualification 验证。本地测试不读取或使用 Developer ID、Notary、Sparkle 私钥或 GitHub 发布凭据。

## 影响与兼容性

修复只改变候选 PR 校验脚本收到的分支名，不改变候选内容、父 main 证明选择、产品行为、依赖、签名、公证、Tag、Release 或资产字节。基础设施失败不占用版本或 Build；`v1.9.9 (135)` 保持不变。
