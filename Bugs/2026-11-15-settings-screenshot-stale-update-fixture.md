# 设置页截图夹具显示旧版本更新

## 现象与证据

用户提供的设置页截图显示：

- 当前版本：`版本 2.0.2 (Build 320)`
- 状态：`可更新`
- 更新内容标题：`1.9.22 更新内容`
- 更新内容：`优化设置页面结构`、`权限与日志集中管理`、`修复已知问题`

截图的版本关系矛盾：`2.0.2` 高于 `1.9.22`，但页面仍显示可更新到 `1.9.22`。

代码核查确认，截图中的三条更新内容和 `1.9.22 (Build 183)` 与
`Sources/RemoteMic/SettingsScreenshotRenderer.swift` 的 `seedAvailableUpdate`
完全一致。该函数在截图/评审模式下无条件注入更新候选，没有读取当前 App 版本。

运行日志进一步确认截图进程来源。2026-11-15 13:46–14:01（Asia/Shanghai）多次出现：

```
ver=2.0.2 build=320 UPDATE BADGE phase=completed result=shown
reason=new_update_detected display_version=1.9.22 build_version=183
```

每次记录后紧跟：

```
APP_ICON CHANGE ... source=screenshot requested=faceted-duck
```

当天没有 `UPDATE CHECK` 记录；真实更新检查会先写入 `UPDATE CHECK`。因此这些
Badge 记录来自截图渲染，不是真实检查。

仓库内历史截图也有同样组合：`Screenshots/sidebar-brand-production/zh-Hans-light/about-1020x772.png`
显示 `2.0.0 (Build 268)` 和 `1.9.22` 更新内容。该截图由同一夹具生成，说明问题
在夹具数据，不在版本比较逻辑。

真实更新源检查：

- 稳定通道：`1.9.21`，`sparkle:version = 174`
- 预发布通道：`1.9.20`，`sparkle:version = 173`
- GitHub 上没有 `v1.9.22` Tag 或 Release

这两个 Build 都低于 `320`。Sparkle 按 Build 比较，不会把它们判定为更新；
`UpdateVersion.isNewer("1.9.22", "2.0.2")` 也返回 `false`。

## 根因与修复

根因是截图夹具硬编码了固定的演示候选：

```swift
updateInformation.setAvailable(
    displayVersion: "1.9.22",
    buildVersion: "183",
    ...
)
```

当前版本号来自真实 `Bundle.main`，夹具候选却没有随 App 版本升级。版本越过
`1.9.x` 后，截图就会显示“从 2.0.x 更新到 1.9.22”。

修复改为从当前 Bundle 元数据生成演示候选：

- 读取 `CFBundleShortVersionString` 和 `CFBundleVersion`。
- 最后一个版本段加 1，Build 加 1。
- 例如 `2.0.2 (320)` 生成 `2.0.3 (321)`。
- 版本或 Build 无法解析时回退到 `999.0.0 (999999999)`。
- 只在截图/评审模式使用；生产更新检查和 Sparkle 路径不变。

新增 `SettingsScreenshotRenderer.demoUpdateCandidate(currentVersion:currentBuild:)`
纯函数，并在 `SettingsPageRegressionTests` 增加三个回归用例，覆盖补丁版本、
两段/四段版本和缺失 Bundle 元数据回退。

## 验证

- `swift test --disable-keychain --filter SettingsPageRegressionTests` 通过 83 项。
- `swift test --disable-keychain --filter UpdateInformationTests` 通过 17 项；真实更新比较和频道选择未回归。
- `SAYALL_PRIVATE_PLATFORM_MODE=public SAYALL_BUILD_CHANNEL=public CODE_SIGN_IDENTITY=- REQUIRE_SIRI_REMOTE_SIGNING=0 CONFIGURATION=release scripts/build-app.sh` 通过。
- `scripts/verify-app.sh dist/SayAll.app` 通过，输出 `APP VERIFY PASS`。
- 使用当前 `2.0.2 (Build 320)` 的公开 Release App，在 `1020 × 772` 下重新渲染
  12 张 About 页面截图：英文/中文、浅色/深色、标准图标、`SIDEBAR_FIXTURE=1`
  和 `long` 账户名。全部为 `2040 × 1544` PNG，逐张确认显示当前版本
  `2.0.2 (Build 320)`、`可更新`、`2.0.3 更新内容` 和 `更新到 2.0.3`，
  不含 `1.9.22`。
- 截图索引：`Screenshots/2026-11-15-about-update-fixture/manifest.json`。
  图片字节保存在仓库外持久目录，PR 附件在交付时补齐。
- 自动化只证明夹具版本计算和静态页面文本；真实更新检查、Sparkle 下载安装、
  真实窗口导航、权限、蓝牙、音频和硬件验收不在本次范围。

## 影响边界

- 普通用户生产路径不受影响：不设置 `REMOTE_MIC_SETTINGS_SCREENSHOT_DIR` 时不会
  进入截图模式；生产窗口的“检查更新”仍绑定真实 Sparkle 动作。
- 截图模式使用独立 `UserDefaults` 并在结束时清理，不会污染用户偏好或已读状态。
- 修复不修改 `Resources/Info.plist`、appcast、发布流程、版本比较逻辑或真实更新源。
- 旧截图和旧哈希按历史证据保留，不删除、不重写；测试手册已标注其历史状态。
