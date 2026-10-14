---
title: 侧栏账号名完整显示
template: doc
lang: zh
---
## 证据与根因
旧换行提交 a2b40f0f 只存在于本地 codex/sidebar-account-name 分支，不在 origin/main f21693de。当前侧栏直接显示组件名称，没有按八位换行。

## 最小修复
SettingsView.swift 保留每个字符，每八个字符换行。文字不限制行数，保持 13pt。辅助功能读取完整名称。

## 验证
```text
swift test --disable-keychain --filter SettingsPageRegressionTests
```
59 项通过。覆盖空值、八位、九位、多行和中文。

## 范围与边界
会员组件先截断名称的问题在私有组件独立修复。宿主不能从已截断字符串恢复姓名。

本轮不发布安装包，不测试升级。2.0.0（249）保持 Draft。

## 完整设置窗口检查

生产 SettingsView 在现有交互截图入口运行。窗口为 1020×772。账号名使用隔离测试数据。私有页面通过生产提供器挂载。

中英文、浅色和深色下，账号名完整显示。推荐页没有顶部白条或可见滚动条。滚动值从 0 到 1。按键、推荐、连接、回眸、设置及个人中心均可进入。

截图位于 Screenshots/sidebar-account-name/。该组合验证使用两项宿主修复与两项私有修复，不代表真实登录、签名包或发布验收。截图格式、尺寸和摘要见 manifest.json。
