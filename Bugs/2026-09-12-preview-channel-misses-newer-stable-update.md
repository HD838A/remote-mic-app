# 开启预发布更新后漏掉更高正式版

## 复现

- 日期：2026-09-12
- 当前线上 Apple Silicon stable appcast：`1.9.21`，Build `174`
- 当前线上 Apple Silicon preview appcast：`1.9.20`，Build `173`
- 操作：在设置页开启“检查预发布版本”，再执行检查更新。
- 修复前结果：客户端只把 Sparkle feed 切到 preview，得到 `1.9.20`，不会发现 stable 的 `1.9.21`。
- 预期：预发布开关表示“同时允许候选版本”，不是排除正式版；应在同架构 stable 与 preview 中选择更高版本。

## 日志结论

修复前 `UPDATE CHECK` 日志只包含 `prerelease_enabled`、URL 是否解析成功和来源，不包含 stable/preview 候选版本，也不记录最终选择通道，因此无法从日志区分“通道请求成功”和“选中了所有允许版本中的最高版本”。

## 根因

`UpdateFeedSelection.feedURLString(checksForPreReleaseUpdates:)` 在开关开启时直接返回 preview URL。Cloudflare 的两个固定通道分别指向各自最新发布，preview 不保证复制更新的 stable appcast，所以 preview 版本低于 stable 时，Sparkle根本看不到正式版项目。

## 修复

- 预发布检查前并行下载同架构 stable 与 preview appcast，只解析 `sparkle:shortVersionString` 用于通道选择。
- 选择语义版本更高的通道，再由 Sparkle 按原有流程校验 appcast、版本、签名、下载和安装。
- 单个通道不可用时继续使用另一个；两个通道都不可用时显示更新信息不可用。
- 日志补充 stable/preview 候选版本与 `selected_channel`，不记录用户内容、路径或设备信息。

## 验证

- 修复前回归测试因缺少 `preferredFeed` 而编译失败，证明旧实现没有双通道选择能力。
- `stable=1.9.21`、`preview=1.9.20` 时选择 stable。
- 覆盖双 appcast 解析、版本比较、单通道失败和多项目选择的 `UpdateInformationTests` 通过。
- 最新 `origin/main`（`385120b9`）基线执行 `swift test --disable-keychain`：492 项测试、40 个 suite 全部通过。
- `scripts/test.sh`：44 项项目自检通过；`scripts/check-repository-boundaries.sh` 通过。
- Release 配置构建成功，`scripts/verify-app.sh dist/SayAll.app` 通过。
- 使用 Release App 在逻辑 `800 × 650` 窗口生成并逐张检查中英文浅色/深色设置页截图，Logo、本地化、页头、双栏、Release Notes、权限区和滚动均未见裁切或窗口几何变化。

## 验证边界

单元测试证明通道解析和选择策略；静态截图只证明布局。最终下载、签名验证、安装替换和重启仍由 Sparkle 的签名公证候选流程验收，不能由本次单元测试替代。
