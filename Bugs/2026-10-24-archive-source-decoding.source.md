---
title: 历史来源值导致整日归档不可见
template: doc
---

## 现象与根因

旧记录可以包含 `source=apple_siri_remote`。
当前来源枚举不识别这个值。
解码一条记录失败后，读取器跳过整个日期文件。
这会隐藏同日其他有效记录。

## 修复

`AppSettings.swift` 将旧来源映射为现行蓝牙来源。
未知字符串映射为 `unknown`，避免同类兼容错误。
非字符串仍按格式错误处理。
现行来源的编码值保持不变。
读取操作不改写历史文件。
后续追加沿用现有保存流程。

## 可重复证据

测试先保存两条合成记录，再替换其中一条的来源。
分别使用旧 Siri 来源和未知来源。
修复前，两种情况都无法读取同日记录。
修复后，两条记录都应可见，并能继续追加。
测试同时检查读取不改写文件、现行编码兼容和错误类型拒绝。

## 验证命令与边界

运行 `swift test --disable-keychain --filter 'TranscriptArchiveStoreTests|RecordingAssetStoreTests|UsageStatistics'`。
全量测试和构建结果见对应 PR。
此修复不改音频、按键、权限或第三方应用集成。
自动化只使用合成记录，不修改用户归档。
真实界面显示仍需在候选 App 中复核。
