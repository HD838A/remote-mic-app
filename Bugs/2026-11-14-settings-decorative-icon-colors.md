# 设置相关页面装饰性图标颜色不一致

## 现象与证据

用户现场截图显示，设置页「通用」分区的「应用语言」行使用绿色地球图标，
同一分区的「启动行为」「重新运行设置向导」以及其上方的「应用图标」等行均为
强调色（当前本机为珊瑚橙）。绿色在该页面只用于「已开启」「已是最新版本」等
成功状态，装饰性行图标不应单独使用。

代码检查确认 `Sources/RemoteMic/SettingsView.swift` 的「应用语言」行硬编码了
`.foregroundStyle(.green)`。该行在 `d34e9dd4`（About 更新中心）迁入通用分区时
一并加入，之后没有颜色调整记录。

进一步扫描同一页面族发现，个人中心「单次语音时长排行」也是同类写法：
标题旁的 `waveform` 图标和第 1–3 名序号硬编码 `.orange`（由 `b59fa7c5` 加入）。
当前系统强调色恰好是橙色，所以现场不容易看出差异；换成蓝色或紫色强调色后，
这两处不会跟随全局强调色。

## 根因与修复

两处都把装饰性强调色写成了固定语义色，而不是使用 `Color.accentColor`。
绿色和橙色在本页面族中已有明确状态含义（成功、警告、等待），装饰图标复用
这些颜色会让用户误读状态，也无法跟随系统强调色。

修复只改颜色 token：

- 「应用语言」地球图标改为 `Color.accentColor`。
- 个人中心语音排行标题图标和前三名序号改为 `Color.accentColor`。

图标形状、行布局、语言选择器、排行数据和点击行为均不变。
`SettingsPageRegressionTests` 增加源码断言，锁定语言行不得再出现绿色，
语音排行面板不得再出现硬编码橙色。

## 验证

- `swift build --disable-keychain` 通过。
- `swift test --disable-keychain --filter SettingsPageRegressionTests` 通过 78 项。
- 生产 `SettingsView` 离屏渲染（`REMOTE_MIC_SETTINGS_SCREENSHOT_DIR`）：
  - 设置页中文浅色，`1020×1400`：
    `SHA-256 e9adcfe6c85d696a2d5fc85ff84d3897943b8366fb95211e0807b2148da9cd60`
  - 设置页中文深色，`1020×1400`：
    `SHA-256 ffaf3b6bb60beb0dcac6e9a15388f3a9951ae7ea4c43ad0cc513be2a656e6f64`
  - 设置页英文浅色，`1020×1400`：
    `SHA-256 6d5b79f94b7d8f608f7ebcd4cdbc74316590aba967c9f8127932b96c304b7e2c`
  - 个人中心中文浅色，`1020×772`：
    `SHA-256 3bb5b5a5daff8803bf621333720fb5e3c17df828d4caabd316283bf757f419a5`
  - 个人中心中文深色，`1020×772`：
    `SHA-256 500fbedf0a5b74c1267e4d8e70f1bcc0da5e446e28bc0524d0fda326453ea051`
  - 个人中心英文浅色，`1020×772`：
    `SHA-256 ccf1bb54c53823b2a5633051c73d485ef7d09a1fdccdf0684601fed83ad13953`
  - 外部持久路径：
    `/Users/andy/Develop/Src/AISrc/open-voice-bridge-evidence/settings-language-icon-20261114/pr-evidence/`
- `git diff --check` 通过。
- 未覆盖：在真实设置窗口中切换系统强调色后的交互验收；本次只调整颜色 token，
  未改变控件布局、点击区域、语言切换或排行数据。当前本机强调色为橙色，所以
  离屏截图不能直接展示“切换为蓝色后跟随”的差异，颜色绑定由源码断言锁定。
