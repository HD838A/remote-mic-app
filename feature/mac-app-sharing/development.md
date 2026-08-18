# 开发记录

## 涉及文件

- `Sources/RemoteMic/AppSharing.swift`：使用 `URLComponents` 构造链接，使用 CoreImage 生成二维码，并封装可测试的剪贴板写入。
- `Sources/RemoteMic/SettingsView.swift`：共享页面内分享面板、关于和统计入口、侧边栏左下入口，以及关于页问题反馈入口。
- `Sources/RemoteMic/RemoteMicApp.swift`：移除状态栏旧反馈入口。
- `Resources/*.lproj/Localizable.strings`：中英文分享、复制结果和反馈说明。
- `Tests/RemoteMicTests/*`：URL、二维码输入、剪贴板、反馈迁移、侧边栏与页面结构回归。

## 关键决策

三个入口只控制同一个 `expandedShareSection`，侧边栏入口导航到关于页并展开分享面板。页面内平铺避免 Sheet 或 Popover，也不会占用或伪造原生侧边栏 selection。

URL 构造会保留已有 query 和 fragment，移除大小写不敏感的旧 `from` 后追加唯一 `from=mac_share`。当前中文 URL 为 `https://sayall.app/?from=mac_share`，英文 URL 为 `https://sayall.app/en/?from=mac_share`。

## 已知限制

- 二维码能否被具体手机相机识别仍需真实扫码验收。
- 系统剪贴板可能被安全软件或系统策略拒绝；页面会显示失败，不影响其他功能。
- App 不跟踪链接打开或分享转化；`from` 参数仅供官网按自身策略识别来源。
