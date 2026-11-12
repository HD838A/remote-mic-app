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

- 方案列表始终显示；旧构件在授权时用 `profiles(for:)`，未授权时用 `allProfiles` 保持只读查看。
- 旧构件用原始 `binding(...)`、`resolvedBindingText(...)` 和 `holdMode(...)` 只读展示方案内容，缺引用显示「配置不可用」而不是「不执行」。
- 创建和复制在旧构件通过 `createProfile(named:)` 与 `setBinding` / `setHoldMode` 逐条落盘，写后校验，失败删除半成品。
- 复制直接写原始 `RemoteMicButtonProfileBinding`，保留固定宏版本、快捷键/focus 类型和未知 host payload。
- 方案模型显式携带默认标记；旧构件不再同时显示「基础映射」和「默认」。
- 编辑区显示继承/覆盖/不可用状态，并为可编辑方案提供单键「清除覆盖」；网格按键仍显示实际动作，不重复「继承：」前缀。
- 从基础创建只复制显式值；未设置动作和按住保持继承，不会写成显式「不执行」或 `once`。
- 旧构件的方案内容保持只读；直接修改仍要求新版接口。
- 创建失败在旧构件按确定性存储失败报告，不再误报「保存状态未知」。
- 私有源码构建现在会探测并启用自动保存接口，源码测试不再只覆盖旧分支。
- 没有私有组件时仍不显示方案工具行，避免公开构建出现空壳。

## 验证

- 公开模式：`SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain`。跳过与本次无关的并行 release fixture 后，1389 项测试、101 个套件通过；方案快照、继承状态、会员门禁和公开兼容用例通过。全量并行运行时 `releaseControlPlaneFixtureHasExecutableRegressionCoverage` 失败，同一脚本单独执行通过。
- 私有 2.9.0 源码：`SAYALL_ENABLE_PRIVATE_SWIFTPM=1 SAYALL_ENABLE_BUTTON_PROFILES=1`，用 Tag `2.9.0` 的私有 checkout 构建。跳过同一 fixture 后，1455 项测试、110 个套件通过；旧构件集成用例覆盖列表、创建、原始复制、未知 payload、固定引用、非会员只读和默认方案识别。
- 私有主线源码：自动保存接口已由 `Package.swift` 探测启用；`mappingProfileAdapterPreservesReadOnlyDisplayAndCompleteCopy` 与相关回归通过，1455 项测试、110 个套件通过，证明新版路径仍可编译和运行。
- 生产界面：用 2.9.0 私有源码构建的 `SettingsView` 离屏入口渲染 `1020 × 772` 中文浅色与深色。顶部方案行可见，「默认」只出现一次，已有方案和右侧创建/复制入口可见；选择方案后可看到继承/覆盖状态，自动保存方案可看到「清除覆盖」。截图索引见 `Screenshots/bug-fixes/mapping-profile-list-fix/manifest.json`。
- `scripts/verify-repository-governance.sh`、`scripts/check-repository-boundaries.sh` 与 `git diff --check` 通过。

本记录只证明源码、隔离测试与生产视图静态布局；实体遥控器、真实会员到期/续费和第三方 App 的最终响应仍按测试手册单独验收。
