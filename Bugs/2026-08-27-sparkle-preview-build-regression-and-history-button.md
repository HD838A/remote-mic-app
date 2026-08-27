# 预览包 Build 回退导致更新误判与版本历史按钮误导

- 时间：2026-08-27
- 状态：代码已修复，待下一候选包真实 Sparkle 验收
- 影响范围：从私有内测包 1.9.13 (Build 141) 检查公开预览 1.9.16 (Build 137) 的用户
- 功能点：Sparkle 更新检查、关于页更新信息
- 简单描述：Sparkle 按 Build 比较时把较新的语义版本误判为“当前版本更高”；无更新提示还提供会下载纯文本文件的“版本历史”按钮。
- 原始记录：用户反馈截图；提交 `d34e9dd4`（经 PR #6 集成的 About update center）

## 复现与日志

仓库保留的内测分支 `codex/internal-draft-main-v1.9.13-build141-20260827` 使用 1.9.13 / Build 141；公开 `v1.9.16` appcast 使用 1.9.16 / Build 137。Sparkle 以 `CFBundleVersion`（Build）作为比较值，因此返回“比最新版本更新”的无更新结果，同时提示文本仍列出 1.9.16 和正在运行的 1.9.13。

本机 `~/Library/Logs/RemoteMic/runtime.log` 没有该 1.9.13 安装实例的现场记录；现有记录只能确认更新源解析成功，不能替代用户现场日志。

Sparkle 默认的 `SPUStandardUserDriver` 会在无更新提示中显示 Version History 按钮；未实现标准用户驱动代理时，它直接打开 appcast 的 `releaseNotesLink`。当前公开 appcast 链接到 CDN `.txt` 资产，系统会按下载文件处理。

## 根因

1. 预览内测包在未合入主线的分支上继续递增 Build，随后公开预览从较旧主线生成较小 Build；语义版本递增与 Sparkle 的 Build 单调性不一致。
2. App 未提供 `SPUStandardUserDriverDelegate` 的版本历史策略，Sparkle 因此保留默认外部链接按钮。

## 修复

- `RemoteMicAppDelegate` 接管 Sparkle 标准用户驱动并关闭 Version History 按钮；关于页保留直接展示最新本地化更新内容的路径。
- 处理 Sparkle “host Build 高于最新 Build”但语义版本确实更高的回调，将关于页状态恢复为可更新并记录诊断日志，避免继续显示“已是最新”。
- 关于页移除独立版本历史按钮与 Sheet，最新版本内容直接显示在版本中心。

## 验证边界

- 相关 Swift 测试和项目自检需要通过。
- 自动化无法证明 Sparkle 在真实已安装 1.9.13 (141) 上可以安装 Build 更低的 1.9.16 (137)；该公开资产仍属于不可安装的 Build 回退，发布修复候选时必须生成全局递增 Build，并用真实签名包执行跨版本安装验收。
