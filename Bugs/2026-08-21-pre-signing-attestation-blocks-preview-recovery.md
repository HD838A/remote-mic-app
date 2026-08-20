# 签名前失败的 attestation 阻止同版本预览恢复

- 时间：2026-08-21
- 状态：已修复，自动化验证通过；等待下一次受保护预览发布验证
- 影响范围：macOS 预览版受保护发布工作流；失败发生在读取 Apple 发布凭据之前
- 功能点：发布请求 attestation 的不可变身份与签名前恢复
- 简单描述：同版本候选在签名前失败且没有 Tag、Release 或发布资产时，旧 attestation 仍会把新候选 SHA 判为非法修改，阻止按规则恢复发布。
- 原始记录：GitHub Actions Run `32411738842` 在 `Resolve immutable request attestation` 失败；PR #128 首次 CI Run `32412021145` 暴露回归测试夹具未模拟新 GitHub 查询。

## 复现

1. 为 `v1.9.6` 运行受保护发布工作流并在签名前失败，保留首次 workflow artifact 中的 attestation。
2. 确认远端不存在 `v1.9.6` Tag、GitHub Release、appcast 或可分发资产。
3. 从最新 `origin/main` 创建新的同版本候选，再次运行发布工作流。
4. 旧逻辑在 attestation 中的候选提交或请求身份不一致时直接退出，无法进入签名阶段。

正常边界：只有 Tag 或 Release 已经存在时才必须保持旧发布身份不可变；纯签名前失败且没有公开身份时，应生成并保存当前恢复候选的新 attestation。

## 日志结论

Run `32411738842` 通过候选来源和双架构证明后，在解析不可变请求 attestation 时退出；没有读取 Developer ID、Notary 或 Sparkle 凭据，也没有生成或上传发布资产。

PR #128 的 Apple Silicon Job `96564419079` 与 Intel Job `96564418649` 均只在 `optimizedReleasePipelineHasExecutableRegressionCoverage` 失败。产品 Swift 测试均通过，失败原因是 fake `gh` 不认识新增的 `gh release view` 查询，不能说明产品代码回归。

## 根因

`scripts/resolve-release-request-attestation.sh` 原来把任何已保存 attestation 都视为永久不可替换，没有区分公开发布身份已经产生与仅有失败 workflow artifact 两种状态。

首次修复允许无 Tag/Release 时恢复，但恢复分支清空旧 JSON 后仍无条件用空值覆盖新 attestation。本地加强回归测试后复现为空输出，确认这是同一状态切换处的控制流缺陷。

## 修复

- 旧 attestation 不匹配时，分别查询指定 Tag 和 GitHub Release；任一存在都继续拒绝替换。
- 两者都不存在时保留当前请求生成的新 attestation，不复用或清空其 JSON。
- 回归测试同时覆盖公开身份存在时保持不可变、无公开身份时成功恢复，以及恢复后的请求 ID、Tag 和 `releaseReadyAt` 完整性。

## 验证

已执行：

```zsh
zsh scripts/test-release-pipeline-optimization.sh
swift test --filter optimizedReleasePipelineHasExecutableRegressionCoverage
git diff --check
```

三项均通过。该修复只改变签名前发布编排，不涉及产品运行时、GUI、硬件、签名内容或公证内容；最终边界仍需由下一次受保护 `v1.9.6` 预览发布证明。
