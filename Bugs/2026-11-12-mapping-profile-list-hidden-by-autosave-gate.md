# 旧私有构件下按键页方案列表整体消失

## 证据

2026-11-12 用户反馈：安装 Build 338 后，按键页顶部悬浮的键位方案列表消失。
此前 Build 332 的界面截图仍有列表。

- 用户现场表现与本机固定私有依赖 `2.9.0` 的能力一致；该版本没有 `displayProfiles()` 等自动保存接口。
- PR #1012 在 `SettingsView.mappingProfileToolbar` 外层加入 `supportsMappingProfileAutosave` 条件，缺接口时整行不渲染。
- 同一条件也隐藏了右侧创建/复制入口；该入口原本可通过旧接口完成。
- `MacroFeatureIntegration.mappingProfiles(device:)` 在同一能力缺失时直接返回空数组，旧构件虽仍能列出方案也没有数据。
- 当时验证使用的私有构件包含新版接口，因此列表、创建和复制的自动化与截图均未覆盖旧构件路径。

## 根因与修复

方案列表的可见性被错误地绑定到新版自动保存能力，右侧创建/复制入口也随整行一起消失。列表和创建/复制都是可用入口，不应依赖写入接口。

修复边界：

- 方案列表始终显示；旧构件用既有 `profiles(for:)` 读取方案。
- 旧构件用既有 `binding(...)`、`resolvedBindingText(...)` 和 `holdMode(...)` 只读展示方案内容。
- 创建和复制在旧构件通过 `createProfile(named:)` 与 `setBinding` / `setHoldMode` 逐条落盘，写后校验，失败删除半成品。
- 旧构件的方案内容保持只读；直接修改仍要求新版接口。
- 没有私有组件时仍不显示方案工具行，避免公开构建出现空壳。

## 验证

- 公开模式：`SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain`。跳过与本次无关的并行 release fixture 后，1384 项测试、100 个套件通过；方案列表静态回归与公开兼容用例通过。全量并行运行时 `releaseControlPlaneFixtureHasExecutableRegressionCoverage` 失败，同一脚本单独执行通过。
- 私有 2.9.0 源码：`SAYALL_ENABLE_PRIVATE_SWIFTPM=1 SAYALL_ENABLE_BUTTON_PROFILES=1`，用 Tag `2.9.0` 的私有 checkout 构建。跳过同一 fixture 后，1450 项测试、109 个套件通过；`legacyComponentKeepsProfileListVisibleAndSupportsCreateAndCopy` 证明旧构件能列出方案、创建和复制方案、读取显式绑定并保持只读。
- 新版私有构件：使用含自动保存接口的预构件完成编译。手动运行自动保存集成用例时缺少私有资源 Bundle 而中止，该结果不作为本轮结论。
- 生产界面：用 2.9.0 私有源码构建的 `SettingsView` 离屏入口渲染 `1020 × 772` 中文浅色与深色。顶部方案行可见，包含「基础映射」「默认」和测试方案；右侧「复制为新的键位方案」入口可见。
- `scripts/verify-repository-governance.sh`、`scripts/check-repository-boundaries.sh` 与 `git diff --check` 通过。

本记录只证明源码、隔离测试与生产视图静态布局；实体遥控器、真实会员到期/续费和第三方 App 的最终响应仍按测试手册单独验收。
