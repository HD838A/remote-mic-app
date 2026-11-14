# 回眸页首次切换耗时过长

## 基本信息

- 时间：2026-11-14
- 状态：候选修复完成，等待 PR 必需检查和更大规模归档复验
- 影响范围：macOS 2.0.0 Build 377/381；设置窗口侧边栏“回眸”；最新日期包含大量文字或录音记录时
- 功能点：本地语音转写与原始录音历史
- 简单描述：点击“回眸”后约 1.5 秒才显示新页面，同一窗口切换到其他页面明显更快

## 原始记录

用户反馈点击“回眸”后很久才切换页面。本机实测运行时为 Build 377，macOS 27.0.1 (26A434)，本机归档为 350 条文字记录和 589 条录音 manifest；最新一天 61 条记录。

逐帧截图计时：

- 连接 → 回眸：第一次出现回眸页面的帧在按键后约 1.3–1.7 秒
- 回眸 → 连接：接近即时
- 连接 → 按键映射：不到 0.2 秒

`sample` 主线程采样（6 秒，2 ms 间隔）显示 2065 个主线程样本中约 815 个位于 `CA::Transaction::commit`，778 个位于 `NSWindow layout`；约 1.6 秒耗在 SwiftUI 布局/提交。没有磁盘 I/O、网络或权限等待。

## 根因

1. `TranscriptHistorySection` 默认展开最新一天；外层 `LazyVStack` 只懒加载日期组，展开日内部使用普通 `VStack` 和 `ForEach`，导致该日全部记录行同时创建、测量和布局。
2. 每行包含 App 图标、时间、最多 5 个操作按钮和可选择文本，记录行数量直接放大首帧成本。
3. 每次进入页面都重新加载文字和录音；`refreshTranscriptRecords()` 内还会重新订阅录音开关并立即再触发一次 `refreshRecordingAssets()`，产生重复的 `@Published` 更新和重排。
4. 行内同步调用 `NSWorkspace` 查询图标，且每行新建 `DateFormatter` / `NumberFormatter`，缺少跨行缓存。

## 修复

- 将时间线扁平化为日期头和记录行同级的单一 `LazyVStack`，只创建视口附近的记录行；保留“最新日期默认展开”和逐日折叠语义。
- 将时间线行构造提取为 `TranscriptHistoryPresentationPolicy.timelineItems(for:expandedDayKeys:)`，增加纯函数回归测试。
- 录音开关订阅移到 `BridgeAppModel` 初始化阶段，不再在每次刷新时重建。
- 文字和录音数组加载完成后先比较再赋值，避免数据未变化时触发重排。
- 增加 App 图标、App URL、时间格式器和数字格式器缓存。

## 验证

```text
swift test --disable-keychain --filter 'SettingsPageRegressionTests|TranscriptArchiveStoreTests'
```

修复后 Build 381 在同一台机器、同一份真实归档上逐帧截图计时：连接 → 回眸第一次出现新页面的帧约在按键后 0.5–1.0 秒；滚动到更早记录仍能正常加载。生产视图截图使用 `REMOTE_MIC_SETTINGS_SCREENSHOT_MIXED_HISTORY=1` 的合成数据，覆盖中文/英文和浅色/深色，未读取用户正文。

## 未覆盖边界

- 尚未用超过 63 条/天的真实大规模归档验证更极端行数。
- 未在 Intel Mac 上复测版本。
- 截图和主线程采样只能证明本机页面切换成本，不能替代真实语音输入、第三方 App 与实体遥控器验收。
