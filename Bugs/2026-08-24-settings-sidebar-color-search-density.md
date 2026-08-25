# 设置页侧栏图标、搜索密度与状态色偏离系统设置

> 后续对图标比例和各页面右侧布局的复核见 `Bugs/2026-08-24-settings-icon-scale-and-detail-layout.md`。11:39 的同屏系统设置对照图又确认 16pt 底板偏小，当前规格以 `Bugs/2026-08-24-settings-sidebar-icon-size-and-row-spacing.md` 为准。根节点 `.large` 放大系统标题栏侧栏按钮的问题已在 `Bugs/2026-08-24-settings-sidebar-toggle-control-size.md` 中继续修正。

## 复现

- 环境：macOS 当前系统外观，`dist/SayAll.app`，窗口 `800 × 650`。
- 操作：打开设置窗口，对照“系统设置 → 触控板”，依次查看侧栏、连接页与权限页。
- 实际结果：侧栏只有跟随强调色的单色 SF Symbols；根视图统一 `.regular` 控件尺寸使搜索与侧栏密度偏小；“语音已就绪”和 Fn 硬件映射使用蓝色，容易被理解为链接或可操作状态；权限行由手写 `HStack` 排版，右侧状态与按钮未使用系统表单的标签列对齐。
- 预期结果：侧栏分类图标具有与系统设置相近的彩色辨识度，搜索与侧栏行采用系统设置密度；普通状态使用 primary/secondary，只有真实连接、警告和成功使用语义色；表单左右列由原生 `LabeledContent` 对齐。

## 日志结论

复现后检查最近 10 分钟 `RemoteMic` 统一日志。窗口可以正常启动和切换页面，未出现 SwiftUI 布局、资源加载或崩溃错误；现有 CoreSpotlight donation 警告与本次静态视觉问题无关。界面布局本身不写专用运行日志，因此根因继续由生产窗口与源码对照确认。

## 根因

1. 根 `NavigationSplitView` 上的 `.controlSize(.regular)` 同时影响侧栏搜索和源列表，无法分别匹配系统设置的较大侧栏密度与常规内容控件密度。
2. 侧栏图标使用 `.symbolRenderingMode(.hierarchical)`，没有当前系统设置分类图标的彩色辨识层。
3. 两个非交互语音状态直接使用 `Color.accentColor`，把强调色错误用作普通状态文字。
4. 权限行用自定义 `HStack` 分配空间，没有复用 grouped `Form` 的 `LabeledContent` 标签/值列布局。

## 修复

- `.searchable(placement: .sidebar)` 和 `.large` 控件密度只应用于侧栏，`NavigationSplitView` 根与 detail 内容显式保持 `.regular`；搜索框和侧栏行获得系统设置式尺寸，同时不放大表单与系统标题栏控件。
- 侧栏继续使用原生 `.sidebar` `List` 和系统选择态；当前分类图标以 20pt 系统色底板、12pt SF Symbols、AppKit 动态系统色和 5pt 连续圆角呈现，不新增位图资源或自绘选择背景。
- 未在录音的语音就绪状态与 Fn 映射状态改用 `.secondary`；录音中、初始化、失败和成功仍按语义使用橙、红、绿。
- 权限行改为 `LabeledContent`，左侧图标/标题/说明和右侧状态/按钮使用系统表单列对齐。

## 验证

- `swift test --filter SettingsPageRegressionTests`：26 项通过。
- `CONFIGURATION=debug scripts/build-app.sh`：通过，生成本地 ad-hoc `dist/SayAll.app`。
- 中文浅色与深色全部设置页均由生产 `SettingsView` 在 `800 × 650` 渲染；连接页和权限页已检查图标、搜索高度、左右列对齐、状态色和滚动边界。
- 深色生产 App 真实窗口已逐页检查按键、统计、回眸、连接、权限和关于；侧栏搜索过滤与清空恢复通过，338 项 Swift 测试、资源校验、`scripts/verify-app.sh` 与 `git diff --check` 通过。

## 验证边界

本修复不改变蓝牙、HID、音频、权限请求或移动端连接行为。实体遥控器、真实权限弹窗、音频回环、iPhone、Apple Watch 和网页版未因此获得真机验收结论。
