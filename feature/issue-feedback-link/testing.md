# 验证记录

## 自动化

- `FeedbackLinkTests` 验证公开入口固定为 `https://my.sayall.app/api/guest-entry?source=mac`。
- `FeedbackLinkTests` 同时锁定 HTTPS、Host、Path、唯一 `source=mac` 查询项、无凭据参数，以及“关于”页入口存在、状态栏不再重复显示。
- `LocalizationTests` 锁定中文“问题反馈”和英文“Feedback”。
- 自动化不代表真实默认浏览器、线上 Worker 或反馈提交已验收。

## 人工验收

按照 [`Testing/IssueFeedbackLink.md`](../../Testing/IssueFeedbackLink.md) 执行。完成真实浏览器跳转和线上权限检查前，功能状态保持“等待人工验收”。
