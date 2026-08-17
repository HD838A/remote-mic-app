# 验证记录

- `AppSharingTests`：覆盖中英文 canonical URL、已有参数与 fragment 保留、旧 `from` 覆盖、二维码 payload 与剪贴板字符串一致、二维码本地生成和写入失败。
- `FeedbackLinkTests`：覆盖关于页拥有反馈入口且状态栏不重复保留。
- `SettingsPageRegressionTests`：覆盖关于、统计、侧边栏三个入口复用同一页面内分享组件且不使用 Popover。
- `LocalizationTests`：覆盖中英文 key 完整一致和用户文案约束。

完整人工步骤和验证边界见 [`Testing/MacAppSharing.md`](../../Testing/MacAppSharing.md)。
