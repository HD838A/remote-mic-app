# 分支与提交管理策略

本文件规定产品开发、版本元数据、macOS 预览发布和正式晋升的最小分支边界。发布实现细节和流程设计见 RELEASING.md。

## main 不变量

- 开始任何操作前执行 git fetch origin main，并记录 origin/main 的完整 SHA。
- main 工作区只用于同步已合入的远端主线，不直接开发、保存临时改动或准备版本元数据。
- 功能、Bug、发布流程和文档改动都在独立分支和 worktree 中完成；分支创建点必须是当时最新的 origin/main。
- PR 的目标分支只能是远端 main。合入后再次 fetch，确认本地 main 与 origin/main 精确一致。
- 不使用普通 force-push、广泛 reset 或把其他 worktree 的未验收内容直接复制到发布分支。

## release-main 不变量

- `release-main` 从公开 `v1.9.19` Tag 的精确 Commit `b02b7fde2d21000d070ac252f8cdd66ef396a691` 起步，是唯一公开发布分支；Preview staging、Preview publication 和 Stable promotion 都只能从它的精确远端 HEAD 触发。
- `release-main` 不承载未经审查的功能开发或 Bug 修复；发布内容仍先通过普通 PR 审查，再按发布范围明确选入 `release-main`，不要求发布分支自动追平整个 `origin/main`。
- 发布前必须 fetch `origin/release-main`，确认发布 worktree 干净、HEAD 与 `origin/release-main` 完全一致。
- 不再创建新的 `release/pre-vX.Y.Z`、canary、rerun 或 qualification 分支；历史分支只保留审计用途，不得作为新发布入口。

## 产品开发与发布元数据

1. 功能或 Bug 先通过普通 PR 合入 main。若用户指定的 Commit 尚未进入主线，先从最新 origin/main 建立独立集成分支，只重放指定工作和必要依赖；冲突必须逐文件核对，不能以整支旧分支覆盖当前主线。
2. 版本号、Build 和中英文 ReleaseHistory 属于发布元数据，也必须在普通 PR 中修改。使用 scripts/prepare-preview-release.sh 前，分支必须是从最新 origin/main 创建的干净分支；脚本只允许修改 Resources/Info.plist 和两份 ReleaseHistory.md。
3. 元数据 PR 合入后，把该版本明确需要的已审查 Commit 选入 `release-main`；发布源是更新后的精确 `origin/release-main` SHA。不要再创建版本候选分支，也不要为同一版本创建第二个 PR。
4. 请求版本已被公开 Tag、Release 或已上传的公开分发资产占用时，脚本只递增最后一位并选择更高 Build。公开资产占用检查覆盖 canonical CDN 固定路径：11 个 payload URL 只有明确 HTTP 404 才算可用；2xx/3xx 视为占用，认证、权限、5xx、超时或其他无法判断的响应 fail closed。Runner、GitHub、Apple、签名、公证或网络故障不会占用版本，不得因为这些故障升版本。

## 预览发布引用

- 预览 staging 只从 `release-main` 的精确 SHA 触发。scripts/stage-macos-preview.sh 先读取并确认 GitHub `releases/latest` 是正式稳定版、工作区干净、`release-main` 与 `origin/release-main` 一致、发布分支双架构 CI 和依赖 pin 通过，然后 dispatch 受保护 workflow。
- 受保护 workflow 的唯一职责是 Apple Silicon 与 Intel Ventura 双架构构建、Developer ID 签名、公证、staple、最终校验，并上传不可变 payload artifact 和 stage record。它不创建 Tag、Release 或公开 appcast。
- 真实 Sparkle UI 升级必须使用该 exact artifact，在公开身份建立前完成。之后由 `release-main` 上无 Apple 凭据的 publication workflow 创建公开 Pre-release，并逐字节复用同一 artifact；首次创建 Tag 前再次确认 11 个 CDN 固定路径全部返回 404。
- 发布身份由 source SHA、Run/attempt、artifact ID/digest、asset manifest 和 UI attestation 绑定；不能用“最新 Run”或相同名称的 artifact 猜测来源。

## 失败、重试与内容变化

- 同一 SHA 的基础设施或外部服务失败：在同一 `release-main` SHA、版本、Build 和 artifact 身份上重试对应阶段；不新建分支、PR、Tag，不重新签名已经成功的字节。
- staging 成功后 publication 失败：先查询远端状态，复用已有 Tag 和已上传资产，只补缺失项或重做明确失败的公开验证。已有资产大小或 digest 不一致，或公开 Release Notes 与候选不一致时停止并保留现场。
- 公开 Pre-release 建立后，Tag、资产和 appcast 视为不可变。产品内容变化必须回到产品 PR，合入 main 后使用新的可用版本和更高 Build；不能改写旧 Tag 或覆盖资产。
- 任何失败都必须保留 Run URL、错误类别和本地验证输出，不能用多个 rerun 分支掩盖历史。

## 正式版晋升

- 不存在独立的“发布正式版”构建命令。只有用户明确指定一个已经发布且验证通过的 Pre-release，才可运行 mac-stable-promote.yml。
- 晋升前必须确认该 Tag 的 Commit 已包含在 `origin/release-main`，Release 当前确实是公开 Pre-release，provenance、资产数量、大小和 GitHub digest 完整匹配，并通过 GitHub API 核对 provenance 绑定的 staging Run/attempt、payload artifact 以及 Preview stage-record artifact（workflow、事件、`release-main` SHA、成功结论、未过期和 digest）。
- 晋升只执行 gh release edit，将同一 Release 标记为非预览并设为 latest；不构建、不签名、不公证、不上传、不移动 Tag。
- stable latest 由 GitHub `releases/latest` 在每次流程开始和结束时动态读取并校验。基线变更必须通过独立普通 PR 记录，不能由预览发布脚本隐式修改。

## worktree、提交和清理

- 发布只能从干净、已 Push、与目标远端 SHA 一致的隔离 worktree 执行；原开发 worktree 的脏状态不应被整理或覆盖。
- 每个独立工作项创建只包含该工作项的 commit，并在交付时报告完整 SHA、Push 状态和验证命令。
- 需要移除本地文件或 worktree 时，先精确核对目标并移动到 macOS Trash；不得永久删除或使用无法恢复的批量清理。
- 远端旧分支的清理不是发布成功条件。只有在确认没有用户工作、Tag、Release 或审计证据依赖后，才可按单独授权清理。

## 私有 Draft 边界

- 私有内部 Draft 使用 private-draft-release skill 指定的 GetSayAll/SayAll 仓库，先确认 visibility 为 PRIVATE。
- 私有 Draft 不在公开源码仓库创建 Tag 或 Release，也不调用公开 Preview publication workflow。
- 可安装的私有 macOS 包仍必须 Developer ID 签名、公证、staple 和下载后复验；私有分发不降低信任要求。
