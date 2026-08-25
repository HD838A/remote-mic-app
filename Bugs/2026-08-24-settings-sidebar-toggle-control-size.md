# 设置页标题栏侧栏按钮被根级控件密度放大

## 复现

- 环境：用户提供的 2026-08-24 11:32:50 浅色真实窗口截图；当前运行中的 `dist/SayAll.app`。
- 操作：打开设置窗口的“按键”页，把指针移到标题栏系统“显示边栏”按钮上。
- 实际结果：系统侧栏按钮被放成接近触控尺寸，悬停材质圈明显过大，与标题、系统设置工具栏密度不匹配。
- 预期结果：继续使用系统自动生成的侧栏按钮，但保持 macOS 常规工具栏密度；搜索框与侧栏行仍保持较大的系统设置式密度。

## 日志结论

复现后检查 `~/Library/Logs/RemoteMic/runtime.log` 和最近 45 分钟 `RemoteMic` 统一日志，未发现 toolbar、sidebar、Auto Layout、window restoration 或约束告警。日志中的蓝牙超时断连与本次静态标题栏尺寸无关。

## 根因

`.controlSize(.large)` 位于整个 `NavigationSplitView` 根节点。该环境值原本用于增大侧栏搜索框和侧栏行，却同时传播给 SwiftUI 自动生成的 `com.apple.SwiftUI.navigationSplitView.toggleSidebar` toolbar item。

最小原生窗口差分测量显示：根级 `.large` 时该 toolbar item 为 `33.5 × 28pt`；根级 `.regular` 时为 `26.5 × 24pt`。把 `.large` 仅留在侧栏后，搜索框在两种根级设置下都保持 `124 × 28pt`，因此不需要在放大搜索框和保持标题栏紧凑之间取舍。

## 修复

- 将 `.searchable(placement: .sidebar)` 和 `.controlSize(.large)` 下沉到侧栏视图链。
- `NavigationSplitView` 根与 detail 内容显式使用 `.controlSize(.regular)`。
- 保留原生统一标题栏、原生侧栏按钮和系统悬停材质；不自绘按钮，不修改 `NSWindow` 或 `NSToolbar` 私有结构。

## 验证

- 修复前源码门禁稳定失败：根级 `.large` 会传播到系统 toolbar item。
- 修复后源码门禁通过；`SettingsView.swift` 与设置页回归测试语法解析通过，`git diff --check` 通过。
- 独立 SwiftUI/AppKit 原生窗口差分验证 toolbar item 从 `33.5 × 28pt` 恢复为 `26.5 × 24pt`，侧栏搜索框继续保持 `124 × 28pt`。
- 恢复 Xcode 27 后，30 项设置页测试、342 项全量测试、成品构建与完整性检查通过。

## 验证边界

新编译的真实 App 已完成侧栏收起与重新展开，系统辅助功能名称正确切换；中文浅色/深色 `800 × 650` 与浅色 `920 × 700` 成品预览已检查。各外观和尺寸下的逐一 hover 仍按测试手册人工复核。
