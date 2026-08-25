# 统计周期控件重复背景

## 复现

- 环境：macOS 设置窗口，统计页，浅色外观。
- 操作：打开“统计”，观察“日 / 周 / 全部”周期选择及其下方“数据仅存本机”。
- 实际结果：分段控件外还有 grouped Form 单行生成的整块横向圆角背景，形成双层容器；控件又通过 `NSViewRepresentable` 改写选中底色，看起来不像完全由系统管理。
- 预期结果：直接使用系统原生分段 Picker，只显示控件自身背景；本机隐私说明保持为该筛选分区的 footer。

## 日志

检查最近 30 分钟的 `RemoteMic` unified log，只看到 TCC 权限请求和偏好读取，没有统计周期状态、绑定或运行时错误。截图中三个周期与选中态均可见，因此问题限定在视图容器样式。

## 根因

`statisticsPeriodPicker` 使用自定义 `NSViewRepresentable` 包装 `NSSegmentedControl`，并设置 `selectedSegmentBezelColor`。该控件同时位于 grouped `Form` 的普通 `Section` 行中，Form 又为整行绘制圆角背景，最终出现控件背景与行背景叠加。

## 修复

- 删除 `StatisticsPeriodSegmentedControl` 桥接类型和选中底色覆盖。
- 使用 SwiftUI 原生 `Picker(.segmented)`，保留原有周期枚举和绑定；480pt 只作为居中布局槽，控件高度和每段宽度由系统控件尺寸管理。
- 透明 Form 行仍会保留 grouped Section 底板，因此最终把筛选器与本机说明放入首个数据 Section 的无底板 header；二者随内容滚动，不使用 `safeAreaBar` 或 `safeAreaInset`。
- 滚动后的整宽、标题栏高度背景由系统 `.unified` toolbar 生成，图表、排行和分享分区不变。

## 验证

- 源码门禁要求存在原生 segmented Picker、禁止固定安全区容器，并禁止重新引入统计控件桥接。
- `swiftc -frontend -parse` 覆盖 `SettingsView.swift` 与 `SettingsPageRegressionTests.swift`；最小 SwiftUI 探针已独立类型检查 `Picker(.segmented)`、`.controlSize(.large)` 和透明 Form 行 API。
- `git diff --check` 检查补丁格式。
- 最终方案的完整自动化、成品构建与完整性检查以 `Testing/NativeSettingsInterface.md` 最新小节为准；中文深色真实窗口已经确认首屏只保留分段控件自身背景，滚动后筛选器随内容离开。
