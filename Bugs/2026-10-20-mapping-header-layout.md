---
title: 按键页头布局修复
template: doc
lang: zh
---

## 复现

基线为 `cef59993ebc50d7243145debea82b27f9ae9e8f6`。
环境为 macOS 27.0.1（26A434）、Apple Swift 6.4、arm64。
同环境使用原生脚本构建公开宿主 Debug App，版本为2.0.0（251）。

打开1020×772按键页，使用三设备截图数据。
标题与开关横排，副标题在下方。设备卡片高于左侧文字区。
左右垂直居中使标题下沉。正常结果应是左侧三行、左右顶部对齐。
原始运行截图保存在 `Screenshots/bug-fixes/mapping-header/`。

## 日志结论

截图入口正常退出，未报告渲染错误。首轮直接运行SwiftPM产物时缺少完整资源。
该组图片不作为验收依据，已改用完整App重新复现和比较。

几何问题没有对应的业务失败日志；截图和布局代码是本次证据。
没有修改业务入口、异步结果或日志事件，因此不新增逐帧布局日志。
硬件成功、失败、取消、超时、重试和恢复均不属于本次改动。

## 根因与修复

`mappingPageHeader` 把标题和开关放在同一行，占用额外宽度。
`hardwareMappingPage` 使用垂直居中，导致标题随卡片高度下沉。
现在将标题、副标题、开关纵向排列，并把左右区域改为顶部对齐。
左栏保留按内容确定宽度，设备卡片区域因此向左扩展。

按用户追加要求，卡片可容纳时靠右排列，超宽时使用原横向滚动。
`ViewThatFits` 只选择卡片布局，不把设备区域换到页头下一行。
不修改共用25pt标题、18pt顶部边距、卡片宽度或设备逻辑。

## 背景边界

本次没有修改背景声明。
主线提交 `505819264ab5b922fc899eb0755d0b13ae74d04c` 曾统一设置窗口背景。
该历史变更把根背景改为与侧栏相同的 `controlBackgroundColor`。
不得用旧分支或旧SDK截图代替当前主线基线。

本轮同环境前后截图在(500,10)、(1200,10)、(2000,1530)取样。
浅色RGB均为(255,255,255)，深色均为(30,30,30)。
设置页前后PNG的SHA-256完全相同。
按键页标题字形顶部从66px上移至45px；设置页为46px。
两页布局边距相同，字形差异为0.5pt，不是容器偏移。

## 验证

- `swift build --disable-keychain` 通过。
- `swift test --disable-keychain --filter SettingsPageRegressionTests`：60项通过。
- `SAYALL_PRIVATE_PLATFORM_MODE=public CONFIGURATION=debug REQUIRE_SIRI_REMOTE_SIGNING=0 scripts/build-app.sh` 通过。
- `scripts/check-repository-boundaries.sh` 和 `scripts/verify-repository-governance.sh` 通过。
- `git diff --check` 通过。
- 生产SettingsView离屏检查覆盖中英文、浅深色、1020×772和800×650页头。
- 空设备和三卡状态的标题、副标题、开关完整。
- 中文浅色实际窗口已点击全部公开侧栏入口，并确认按键页滚动可达底部。

最终实际窗口使用相同二进制和隔离截图数据。
仅本地检查副本使用独立Bundle ID和ad-hoc重签名，避免绑定用户运行窗口。
生产身份与源码未改。原始JPEG保留在截图目录中，未转码。

新增断言初次因代码区间匹配到同名前缀而失败，修正匹配后整组通过。
截图格式、尺寸、SHA-256和大小见 `Screenshots/bug-fixes/mapping-header/manifest.json`。
副标题13pt、开关14pt；不缩小中文。

## 验证边界

本轮只修改共享页头，不修改语音、权限、持久化或按键执行。
公开宿主不包含私有组合动作、Siri Remote或Chromecast实现。
私有页面、真实硬件、多设备切换和最终文字上屏未在本轮验收。
800×650为离屏压力尺寸，既有画布过宽不在本次修复范围。
生产最小窗口仍为1020×772。本地ad-hoc包仅作代理检查，不提供安装分发。

测试步骤见 `Testing/UnifiedButtonConfiguration.md` 的2026-10-20小节。
