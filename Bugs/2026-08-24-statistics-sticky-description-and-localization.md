# 统计页说明悬浮与排行本地化键外露

## 复现

- 环境：macOS 27，中文浅色，`800 × 650` 本地调试成品。
- 操作：打开“统计”页并向下滚动，使第一组图表进入顶部系统滚动边缘。
- 实际结果：“数据仅存本机”与周期筛选器一起固定在滚动页头左下角；部分运行路径还会直接显示 `statistics.voice_ranking.title` 和 `statistics.voice_ranking.description`。
- 预期结果：周期筛选器和数据说明都属于统计内容并随图表滚动；滚动后只保留系统标题栏背景；排行始终显示当前应用语言对应的文案。

## 日志与代码结论

复现后检查 `~/Library/Logs/RemoteMic/runtime.log`，没有资源加载、窗口几何、SwiftUI 约束或崩溃错误。代码中 `statisticsPeriodControls` 使用 `safeAreaBar` 固定筛选器和数据说明；后续只保留筛选器仍会生成内容列宽、高于系统标题栏的大矩形。排行的三个 `Text` 仍依赖隐式 `LocalizedStringKey` 查找，而同页其他文案已通过 `LocalizationStore` 显式解析。

## 修复

- 删除 `safeAreaBar`，原生 `Picker(.segmented)` 与“数据仅存本机”共同放入第一个统计数据 `Section` 的无底板 header，并随表单内容滚动。
- 滚动后只保留系统 `.unified` toolbar 生成的整宽、标题栏高度背景。
- 排行标题、说明和空状态统一使用 `localization.text(...)`，不修改现有中英文文案。
- 未修改统计数据、周期切换、排行顺序、分享或持久化行为。

## 验证边界

- Xcode 27 下完整 Swift 测试通过：32 个 suite，共 344 项测试。
- 调试成品重新构建并通过 `scripts/verify-app.sh dist/SayAll.app`；`git diff --check` 通过。
- 中文深色 `800 × 650` 真实成品窗口确认：首屏筛选器没有额外底板；向下滚动后筛选器和说明都随内容离开，标题栏只保留整宽系统背景；排行标题和说明均显示中文，没有原始键名。

统计数据来自既有本机记录；本轮不重新验证遥控器、语音、音频、蓝牙或权限链路。
