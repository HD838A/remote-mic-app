# 开发记录

## 实现切片

- `Sources/RemoteMic/AppLinks.swift`：集中保存公开反馈入口。
- `Sources/RemoteMic/RemoteMicApp.swift`：在状态栏菜单增加入口，并使用 `NSWorkspace` 打开默认浏览器。
- `Resources/*.lproj/Localizable.strings`：提供中英文菜单文案。
- `Tests/RemoteMicTests/FeedbackLinkTests.swift`：锁定入口地址，防止误改为携带凭据的链接。

## 关键决策

采用固定公开入口换取零配置体验。Mac App 不请求、不保存任何工作台密钥；服务端只签发有效期 7 天的匿名 guest 会话。

## 已知限制

- 入口无法证明调用方一定是正版 Mac App。
- 浏览器无法打开、网络不可用或线上服务异常时，App 当前不会额外显示错误提示。
- 管理能力仍必须通过独立的管理身份进入。
