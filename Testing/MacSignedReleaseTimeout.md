# macOS 受保护 staging 超时与并发测试手册

## 适用范围

验证 .github/workflows/mac-release-package.yml 的双架构签名 staging 和 scripts/run-release-stage.sh 的进程边界。它不创建公开 Release，也不替代真实 Apple 服务验收。

## 测试前准备

1. 使用干净隔离 worktree。
2. 不提供 Apple 证书、P8、Match 密码、Sparkle 私钥或 Token。
3. 确认 actionlint、zsh -n、bash -n 和 fixture 测试可用。

## 用例 1：600 秒硬上限

1. 检查签名 Job 的 GitHub step timeout-minutes 为 10。
2. 检查内部 signed-release supervisor 为 540 秒。
3. 用假命令让阶段超过内部期限。

预期：supervisor 返回 124，完整子进程树被终止，第一份错误日志保留；不会静默重试或延长期限。

失败判定：只有 job 级 180 分钟限制、后台 notarytool/pkgbuild 继续运行、超时后自动重打或改版本。

## 用例 2：双架构隔离

1. 并发执行 Apple Silicon 和 Intel lane。
2. 检查 SwiftPM scratch、cache、dist 和临时 Keychain 路径。

预期：两条 lane 使用不同路径；输出分别为 arm64/macOS 14 和 x86_64/macOS 13，不共享会导致冲突的构建目录。

## 用例 3：PKG/DMG 顺序

1. 检查两个架构的 App、卸载 PKG、DMG 和 appcast 生成顺序。
2. 确认内嵌 component PKG 先生成，外层产品 PKG 再签名、公证和 staple。

预期：独立 PKG 可并行提交公证；DMG 只在内嵌内容完成后生成，最终验证器检查外层 Installer 信任边界。

## 用例 4：错误传播

1. 令 Intel lane 返回非零，让 Apple Silicon lane 启动长时间子进程。
2. 运行并行 packaging fixture。

预期：父流程失败并终止另一条 lane 的完整进程树，不留下孤儿进程，也不上传部分资产。

## 用例 5：凭据和 token 边界

1. 运行 scripts/verify-release-workflow-gh-token.sh。
2. 静态检查 staging workflow 的每个 gh/API step。

预期：每个 step 都显式设置 GH_TOKEN；publication workflow 不声明 Apple Environment 或 secrets；日志不包含凭据值。

## 用例 6：主线 smoke

1. 在合入后的精确 main SHA 运行 scripts/stage-macos-preview.sh smoke。
2. 检查受保护 workflow 只上传 payload/stage artifact。

预期：smoke 可以证明 workflow 路径、双架构和门禁配置，没有创建 Tag、Release、appcast 或产品候选分支。

## 稳定功能回归

- 失败只影响本次 staging，不会升版本、Build 或创建 rerun 分支。
- 已经成功的 artifact 可由 publication 复用，不重新进入 Apple 签名。
- scripts/test-macos-release-flow.sh、scripts/test-prepare-preview-release.sh 和 BuildSigningTests 通过。

## 日志与边界

保存 lane、stage、elapsed、退出码和 artifact 摘要；不要保存秘密。无凭据 fixture 不能证明真实 Developer ID、Notary 或 staple 成功，真实结果必须由受保护 Run 提供。
