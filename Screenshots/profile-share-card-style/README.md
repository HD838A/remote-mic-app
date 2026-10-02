# 个人中心分享与卡片样式验证

基线：`36eebf332f7d2a0d0aa48078d0693c2189c9a223`；分支：`codex/profile-share-card-style`。App 版本 `1.9.21`。截图对应本目录所在提交的生产 UI 修改，使用脱敏测试统计数据。

- `statistics-*` / `about-*`：本仓库 `scripts/build-app.sh` debug 构建的生产 `SettingsScreenshotRenderer` 输出，共 20 张 PNG。覆盖中英文浅色/深色 `1020×772`、分享展开，以及中文浅色/深色 `800×650` 和 `1606×979`。离屏入口关闭原生玻璃，不能作为其他页面原生玻璃材质的验收。
- `live-*`：生产 `RemoteMicRootView` / `SettingsView` 在本地隔离预览窗口中运行的 5 张原始 JPEG，窗口内容 `1020×772`，启用原生玻璃策略、保持生产窗口 chrome 和最小尺寸。Cua 截图字节按原始 JPEG 保存，没有转码。预览使用独立设置 suite、测试统计和独立空历史目录；预览启动器与实验源码仅保留在仓库外的 `/Users/andy/Develop/Tests/profile-share-card-style/`，不进入版本控制。
- 已检查公开侧边栏全部入口（按键、回眸、连接、设置、个人中心）、个人中心分享展开/收起、底部排行与“查看全部回眸”、回滚顶部、设置页底部无分享模块，以及返回个人中心后的状态。真实窗口交互为中文浅色，英文/深色为离屏验证。
- 所有图片的实际格式、像素尺寸、SHA-256 见 [manifest.tsv](manifest.tsv)。Retina 位图是逻辑尺寸的 2 倍。

验证命令：

```sh
xcrun swift build --disable-keychain
xcrun swift test --disable-keychain --filter 'SettingsPageRegressionTests|AppSharingTests'
CONFIGURATION=debug REMOTE_MIC_BUILD_SCRATCH_PATH="$PWD/.build" ./scripts/build-app.sh
git diff --check
```

相关测试 58 项通过，构建通过。未验证手机实扫、真实系统剪贴板失败、VoiceOver、降低透明度/增强对比度、硬件语音输入及正式签名安装包；本地 ad-hoc 包仅用于开发验证，不作为用户安装包交付。

测试手册：[个人中心](../../Testing/ProfileStatistics.md)、[官网分享](../../Testing/MacAppSharing.md)、[设置页](../../Testing/AboutUpdateCenter.md)。

本次文件变化：

| 文件 | 必要性 |
| --- | --- |
| `Sources/RemoteMic/SettingsView.swift` | 移除侧边栏与设置分享、迁移至个人中心顶部；统计与分享改用平面卡片，并移除旧分享导航/自动滚动逻辑。 |
| `Sources/RemoteMic/SettingsScreenshotRenderer.swift` | 二维码展开场景改为渲染个人中心。 |
| `Tests/RemoteMicTests/SettingsPageRegressionTests.swift` | 更新已有导航与模块顺序断言，保留宽窄统计布局验证。 |
| `Testing/MacAppSharing.md` | 更新唯一分享入口、卡片外观和回归步骤。 |
| `Testing/ProfileStatistics.md` | 更新分享顺序、侧边栏与卡片验收条件。 |
| `Testing/AboutUpdateCenter.md` | 更新设置页和固定侧边栏的分享迁移检查。 |
| `TODO.md` | 同步当前入口与历史阶段说明，保留尚未完成的实机验收状态。 |
| `design-qa.md` / `design-qa.en.md` | 同步个人中心材质例外及分享布局，保持中英文规范一致。 |
| 本截图目录 | 保留生产视图截图、格式/尺寸/摘要与验证边界。 |
