---
title: 内嵌页面顶部白条
template: doc
lang: zh
---
## 证据与根因
真实 NSWindow 回归使用生产 fullSizeContentView 与 1020×772 内容尺寸。原实现的页面高度为 740pt，缺少 32pt 标题栏区域。

## 最小修复
SupplementalSettingsIntegration.swift 让挂载页面延伸至顶部安全区域。不修改页面背景、网址或内容。

## 验证
```text
swift test --disable-keychain --filter SupplementalSettingsIntegrationTests
```
原实现同一用例失败；修复后四项通过，页面高度为 772pt。旧组件缺失和无会员挂载基线通过。

## 范围与边界
窗口测试证明挂载几何。网页内容和线上部署由私有实现负责。

本轮不发布安装包，不测试升级。2.0.0（249）保持 Draft。
