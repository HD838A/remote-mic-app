# 关于页版本中心

- 状态：开发完成，发布验证中
- 平台：macOS
- 对应任务：根目录 [`TODO.md`](../../TODO.md) 中“在关于页集中展示版本与更新信息”
- 人工测试手册：[`Testing/AboutUpdateCenter.md`](../../Testing/AboutUpdateCenter.md)

## 为什么开发

版本号、检查更新、预发布开关和版本历史原本分散，用户在发现新版本前也无法直接了解更新内容。开启预发布检查后切换回正式通道时，页面还必须明确刷新当前结果，避免旧候选信息造成误解。

## 用户功能介绍

- “关于”页顶部继续提供官网和 GitHub 入口。
- “版本与更新”区域同时显示当前版本、可更新版本、检查更新、重新检查、版本历史和预发布更新开关。
- 检测到新版本时，在同一区域展示当前界面语言对应的更新内容。
- 跟随系统、简体中文和 English 始终平铺显示，不使用下拉框。
- 页面不再显示术语表入口。

## 范围与非目标

本次调整“关于”页、更新信息展示和 stable/preview feed 选择，不改变 Sparkle 的下载、授权、安装、重启或自动检查周期。不会自动安装更新，也不会让预发布版本进入默认正式更新通道。

## 关键设计与开发过程

- `UpdateInformationStore` 保存检查中、已是最新、不可用和发现更新四类页面状态，并按当前语言加载与版本 ZIP 位于同一固定标签下的更新说明资产。
- App 继续只保留一个 `SPUStandardUpdaterController`。关于页打开时调用无弹窗的信息检查，用户点击更新时仍进入 Sparkle 标准更新界面。
- 正式/预发布开关变化后清除旧页面状态，切换 Cloudflare stable/preview 通道并重置 Sparkle 更新周期。
- 通道不可用时显示更新信息暂不可用，不回退到较旧稳定版本，也不显示额外候选源错误弹窗。

## 涉及文件

- `Sources/RemoteMic/SettingsView.swift`：关于页布局与版本中心界面。
- `Sources/RemoteMic/RemoteMicApp.swift`：Sparkle 检查协调、更新通道切换和 delegate 回调。
- `Sources/RemoteMic/UpdateInformationStore.swift`：更新信息与本地化说明状态。
- `scripts/notarize-release.sh`、`scripts/prepare-public-release-assets.sh`：从最终签名归档生成固定版本的中英文更新说明资产；公开发布由 `scripts/publish-preview-release.sh` 复用已验证字节完成。
- `Resources/*/Localizable.strings`、`Resources/*/ReleaseHistory.md`：界面文案和用户可见版本记录。

## 隐私与兼容边界

更新检查访问 Cloudflare appcast 通道、版本 ZIP 和更新说明 URL，不再由客户端直接访问 GitHub Releases API，也不上传本地设置、设备信息或使用数据。`CFBundleVersion` 仍由 Sparkle 用于跨版本比较。更新说明获取失败不会阻止 Sparkle 检查或安装。

## 自动化验证与当前限制

单元测试覆盖 stable/preview、Apple Silicon/Intel appcast 选择、非法 feed 拒绝、固定版本说明 URL、说明解析、语言重载和关于页结构。真实升级、签名、公证、生产通道字节、最终安装包启动和最小窗口人工验收完成后，状态才改为“已完成”。
