# 私有 Draft 被错误创建到公开源码仓库

## 复现

1. 从已完成签名、公证和真实 Sparkle UI 验收的候选执行 `scripts/publish-staged-preview.sh <attestation> draft`。
2. `macOS Preview Publication` 接受 `publication_mode=draft`，并使用当前 `GITHUB_REPOSITORY` 创建 Release 和产品 Tag。

错误行为：私有内部测试 Draft、安装资产和 `vX.Y.Z` Tag 被写入公开源码仓库 `HD838A/remote-mic-app`。

正确行为：私有 Draft 只能写入已确认且 `visibility=PRIVATE` 的分发仓库 `GetSayAll/SayAll`；公开源码仓库的 publication workflow 只能创建公开 Pre-release。

## 日志与证据

- 错误 Draft：Release ID `376198508`，Tag `v1.9.12`，包含 12 项资产。
- 错误 Tag 指向候选 Commit `cdca0624588407aea91b8d7452cbf1c1ba958558`。
- 私有 Draft repository map 已明确把源码远端映射到 `GetSayAll/SayAll`，但公开 Preview workflow 没有读取该映射，也没有验证目标仓库可见性。
- 纠正后私有 Draft：`internal-mac-v1.9.12-build138-20260825`，Release ID `376287120`，`Draft=true`、`Pre-release=false`。

## 根因

公开 Pre-release 与私有 Draft 共用了 `macOS Preview Publication` 的 `publication_mode` 输入。workflow 和 dispatcher 默认使用源码仓库，导致 `draft` 只改变 Release 分类，没有改变分发仓库。执行时又遗漏了私有 Draft skill 要求的 `visibility=PRIVATE` 强制门禁。

## 修复

- `macOS Preview Publication` 删除 `publication_mode`，固定执行 `resume-prerelease`。
- `publish-staged-preview.sh` 只接受一个 UI attestation 参数，并验证公开 Pre-release 的仓库身份和 `PUBLIC` 可见性。
- `publish-release.sh` 在入口拒绝 `draft` 和 `resume-draft`，提示改走 `GetSayAll/SayAll` 私有 Draft 路径。
- `RELEASING.md` 明确分离公开 Pre-release 和私有 Draft 的仓库、Tag 与工具边界。

## 验证

- `scripts/test-release-pipeline-optimization.sh`
- `scripts/test-release-resume-workflow.sh`
- `swift test` 中 `BuildSigningTests` 的发布入口静态门禁
- `private-draft-release` skill 校验
- GitHub 远端复核：公开源码仓库不存在错误 Draft 和 `v1.9.12` Tag；正确私有 Draft 的远端摘要、逐字节比较、Developer ID、Team ID、公证和 Gatekeeper 复验通过。

## 自动化与真实环境边界

本修复只改变 Release/API 编排控制面，不改变已签名 App、DMG、PKG、Sparkle 元数据或产品行为，因此不重新构建或签名候选。私有 Draft 的两个最终 DMG 已在上传前及远端下载后完成真实 macOS 分发资产验证。
