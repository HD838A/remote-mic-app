# 侧边栏品牌与个人中心图标验证

2026-10-02，基线 `b2ba6be6e6b48dfa942401a617214b60f9db853d`，App `1.9.21 (228)`，Apple Silicon 公开本地构建。实现及原始截图随本 PR 提交；不修改版本或发布资产。

顶部固定 `SayAll` 与 Bundle 版本号，不显示图标；品牌与中间导航相对首轮实现整体上移 `15pt`。分享保持原图标及定位、展开行为；个人中心复用 App 图标目录并跟随当前设置。按 SwiftUI 布局模式把中间导航放入滚动区，品牌与底部入口保持固定。

## 生产视图证据

默认及生产最小窗口均为 `1020 × 772pt`，原始 Retina 输出 `2040 × 1544px`。所有文件均小于 `5MB`，格式、尺寸和 SHA-256 已验证，完整摘要见 [sha256.txt](sha256.txt)。图片未重绘、缩放或重新压缩。

- [默认图标、中文浅色](safe-15pt/standard/zh-Hans-light/mapping-1020x772.png)
- [默认图标、中文深色](safe-15pt/standard/zh-Hans-dark/mapping-1020x772.png)
- [几何鸭、中文浅色](safe-15pt/faceted-duck/zh-Hans-light/about-1020x772.png)
- [几何鸭、中文深色](safe-15pt/faceted-duck/zh-Hans-dark/about-1020x772.png)
- [英文浅色](safe-15pt/standard/en-light/mapping-1020x772.png)
- [英文深色](safe-15pt/standard/en-dark/mapping-1020x772.png)
- [未知标识回退](safe-15pt/unavailable/zh-Hans-light/mapping-1020x772.png)

`safe-15pt/` 共提交 35 张 PNG：以上 7 个语言、外观、图标组合，各包含按键、回眸、连接、个人中心和设置 5 个公开页面。生产 App 隐藏离屏入口使用正式 `SettingsView` 与资源，偏好、录音、转写与 Agent 授权均使用隔离空目录，统计及更新状态使用既有固定样例。公开构建不可用的私有页面不会以回退页冒充验证证据。离屏入口使用既有兼容材质，不代表 macOS 26 原生玻璃动态效果或窗口 chrome 验收。

生成参数为 `REMOTE_MIC_SETTINGS_SCREENSHOT_DIR`、`REMOTE_MIC_SETTINGS_SCREENSHOT_SIZE=1020x772`、`REMOTE_MIC_SETTINGS_SCREENSHOT_LANGUAGE`、`REMOTE_MIC_SETTINGS_SCREENSHOT_APPEARANCE` 及 `REMOTE_MIC_SETTINGS_SCREENSHOT_APP_ICON`，从本轮原生 App 构建运行。逐页复核文字、导航、对比度与裁切；对相同页面像素核对确认上移 `30px = 15pt`、底部固定、品牌与分享不随图标变化、个人中心随选择变化、未知标识回退默认图标。

## 实际窗口交互

`final-15pt/runtime/` 的 4 张 JPEG 是本轮 15pt 布局构建的原始窗口截图，早于仅限截图模式的历史与授权隔离补丁；UI 源码与最终布局一致。

- [切换前](final-15pt/runtime/settings-standard-zh-hans-light.jpg)
- [切换后即时同步](final-15pt/runtime/settings-faceted-duck-zh-hans-light.jpg)
- [分享定位并展开](final-15pt/runtime/share-expanded-zh-hans-light.jpg)
- [切换到按键页](final-15pt/runtime/mapping-faceted-duck-zh-hans-light.jpg)

在默认及最小尺寸逐一点击全部公开入口：按键、回眸、连接、设置和个人中心；检查品牌固定、主要内容滚动和导航可访问。默认与几何鸭切换后个人中心即时同步，分享仍定位并展开设置末尾模块；原生红黄绿按钮与品牌不重叠。没有修改系统权限、授权或用户历史。

重启验证未完成：后续启动被本机其他 SayAll 实例的共享单实例锁阻止，未停止其他任务进程。截图不证明 Dock、应用切换器、重启恢复、私有可选入口或 Intel 真机；这些边界仍按 [测试手册](../../Testing/AboutUpdateCenter.md) 验收，不把原有 App icon 的未完成条目标记完成。

## 自动化与范围

- `swift test --disable-keychain`：785 tests / 60 suites 通过。
- 原生 `scripts/build-app.sh` debug/local 构建通过；`codesign --verify --deep --strict` 通过。本地 ad-hoc 包不上传、不交付为安装包。
- `git diff --check`、仓库边界与治理检查通过。
- 复用既有 App icon 稳定标识、缺失资源回退、持久化与 `APP_ICON CHANGE` 脱敏日志；本功能不新增异步业务操作，取消、超时与重试不适用。
- 未改共享协议、语音、蓝牙、HID、会员语义或配置格式；未访问第三方 App 私有数据。真实硬件、音频、系统权限、第三方工具和跨平台验收不在本次 UI 变更范围。
