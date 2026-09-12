# 回眸记录过多时重复、空白、卡顿及应用记录不可见

## 复现证据

- 在回眸页准备同一日期同时存在文字记录和录音-only 记录，再在“全部应用”时间线中上下滚动。修复前，文字日期组和录音日期组都以 `yyyy-MM-dd` 作为 `ForEach` 身份；两组进入同一个 `LazyVStack` 后会产生重复身份，表现为重复日期、空白行和滚动抖动。
- 记录数量增大后，每条文字记录都通过 `model.recordingAssets.first(where:)` 扫描全部录音资产；该路径为 O(文字记录数 × 录音资产数)，可复现滚动和布局卡顿。
- “全部应用”原先渲染完整历史；应用卡片显示的是该应用全部会话数，而时间线没有时间窗口。某个应用（例如微信）的旧记录会显示计数但不在当前可见区域，用户容易看到“44 条但一条也没有”。

## 日志结论

检查本机 `Application Support/RemoteMic/Transcripts/v1` 及现有运行日志：归档加载使用 `TranscriptArchiveStore.loadAll()`，未发现 `load_failed` 或损坏记录错误；问题发生在 SwiftUI 列表身份和展示范围，不是跨应用数据读取或归档写入失败。检查仅涉及 SayAll 自己的回眸归档，没有读取第三方 App 私有文件。

## 根因

1. `TranscriptDayGroup.id` 与 `RecordingDayGroup.id` 都使用日期字符串，在同一个 `LazyVStack` 的兄弟 `ForEach` 中发生 SwiftUI identity collision。
2. 文字行对录音资产进行逐行线性查找，记录增多后产生 O(n²) 查找成本。
3. 总时间线没有“最近一周”展示窗口，也没有引导用户按应用查看更早记录。

## 修复

- 为录音日期组使用 `recording-<date>` 命名空间，同时保留独立 `dateKey` 用于本地化日期标题和展开状态。
- 预先建立 `sessionID → RecordingAssetManifest` 索引，文字行 O(1) 查找关联录音。
- “全部应用”只展示最近 7×24 小时的文字和录音记录；单个应用仍展示该应用完整历史。存在更早记录时显示“按应用查看更多记录”，无最近记录时显示明确提示。
- 新增纯函数展示策略测试，覆盖总时间线时间窗口和应用筛选保留旧记录。

## 验证

```text
swift test --filter 'TranscriptArchiveStoreTests|SettingsPageRegressionTests'
```

结果：34 项测试通过（2 个测试套件），仅有仓库既有 macOS `onChange(of:perform:)` 弃用警告。

## 未覆盖边界

- 当前环境未运行真实第三方微信 UI，也未使用真实大规模用户归档驱动 Accessibility 滚动验收；需要在签名测试包中准备超过一周、同日文字与录音混合的记录，确认视觉无重复/空白且选择微信后可见完整历史。
- 该修复不改变归档格式、删除语义或跨应用数据边界。
