# 预览发布身份校验缺少 GH_TOKEN

- 时间：2026-08-21
- 状态：已修复；修复后的 `v1.9.6` 预览版已完成受保护签名、公证和公开字节验证
- 影响范围：macOS 预览版 `Validate release identity` 步骤
- 功能点：发布工作流的 GitHub 身份与来源校验
- 简单描述：步骤调用 `gh` 查询 GitHub，但没有显式注入 `GH_TOKEN`，在接触任何 Developer ID/Notary 凭据前以退出码 4 失败，导致预发布被无关的编排缺陷阻断。

## 复现与正常边界

在受保护预览发布中执行 `Validate release identity`，让步骤运行其 `gh` 查询：

- 错误行为：步骤以退出码 4 失败，发布停在身份校验阶段。
- 正常行为：步骤使用工作流 token 完成 Tag/Release/候选来源查询；无论查询结果如何，都应给出明确的来源结论后再决定是否继续。
- 现场边界：失败发生在 Apple 凭据读取之前，没有生成或上传签名、公证、Sparkle 或公开 Release 资产；因此没有占用版本，也不应触发版本递增。

## 日志与根因

步骤内调用了 `gh`，但环境没有 `GH_TOKEN`。GitHub-hosted Runner 的隐式环境不能作为工作流契约，`gh` 因无法完成 API 查询返回退出码 4，错误与产品源码、版本内容和 Apple 凭据无关。

## 最小修复

- 在调用 `gh`/GitHub API 的 workflow step 内显式设置 `GH_TOKEN: ${{ github.token }}`。
- 将该要求写入 `RELEASING.md`、发布 skill 和 SLO 测试手册。
- 在 `scripts/test-release-pipeline-optimization.sh` 中增加无秘密静态断言，防止 `Validate release identity` 再次缺少 token。

## 恢复规则

修复通过普通 PR 合入 `main` 后，从最新 `origin/main` 创建同版本编号恢复候选（`-rerun`、`-rerun2`……）。旧失败 Run 和候选分支保留作证据；只有已经产生 Tag、Release、appcast、可分发资产或进入签名/公证等不可变阶段，才需要递增版本与 Build。

## 验证边界

- 无秘密：workflow 静态检查、发布管线回归脚本、`BuildSigningTests`。
- 受保护：`v1.9.6` 完成双架构 Developer ID 签名、公证、staple、provenance 和 GitHub/CDN 公开字节验证。
- 本记录不把 CI ad-hoc 包当作公开安装包，也不记录任何 token、证书、私钥或 Notary 凭据值。
