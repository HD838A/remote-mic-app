# Intel macOS 13 将 SayAll App 图标显示为完整正方形

- 时间：2026-08-21
- 状态：候选修复完成，等待真实 Intel macOS 13 的 Finder、Launchpad、Dock 与覆盖安装验收
- 影响范围：Intel Mac、macOS Ventura 13；其他仍直接显示 `.icns` 画布的 macOS 版本也可能受影响
- 功能点：App 品牌图标与 macOS 打包资源
- 简单描述：原有 AppIcon 的大尺寸图层没有 Alpha 通道，macOS 13 直接显示完整不透明画布，导致无线麦SayAll.app 图标呈正方形。

## 复现与正常边界

用户在 Intel macOS 13 上安装并查看 App 图标：

- 错误行为：Finder、Launchpad 或 Dock 把图标显示成铺满画布的完整正方形。
- 正常行为：显示已批准品牌图中的圆角图标，四角透明，不出现额外白色或纸张色方形背景。
- 当前环境无法代替真实 Intel Ventura 的系统渲染和图标缓存；仓库侧通过检查原始资源和 `.icns` 图层复现资源缺陷。

## 日志与资源证据

这是静态品牌资源和系统渲染问题，不涉及运行时业务日志。修复前检查结果：

- `Resources/AppIcon.png` 为 `1024 × 1024` RGB，`hasAlpha: no`。
- `Resources/AppIcon.icns` 展开的 128、256、512 和 1024 像素图层均为 RGB，不具备透明四角。
- `Resources/Info.plist` 已正确设置 `CFBundleIconFile = AppIcon`。
- Apple Silicon 与 Intel 打包脚本复制同一份 `AppIcon.icns`，不存在 Intel 专属图标分支。

因此根因不是 Intel 架构、SwiftUI、Bundle 配置或菜单栏模板图标；Intel macOS 13 只是暴露了不透明画布。

## 最小修复

- 使用用户提供并批准的透明圆角品牌 PNG，原始文件 SHA-256 为 `84f5dd4629c25fd41022c3a5a72bfb8e29fb6460409ebf0ce805944f7042f546`。
- 仅将原始 `1254 × 1254` PNG 等比例缩放为标准 `1024 × 1024` `Resources/AppIcon.png`；不裁切、不重绘、不自行生成圆角。
- 从该主图生成 16、32、128、256、512、1024 像素及对应 Retina 图层，重新打包 `Resources/AppIcon.icns`。
- `scripts/verify-app.sh` 展开最终 App 内的 `.icns`，校验十档图层全部存在、具有 Alpha 通道、四个角透明且中心不透明。
- `BuildSigningTests` 同时验证主 PNG 的尺寸和透明角，并锁定最终包校验门禁。

## 验证边界

自动化可以证明：

- 主 PNG 为 `1024 × 1024` RGBA，四角 Alpha 为零、中心不透明。
- `.icns` 包含完整十档图层，所有图层保留透明角。
- Apple Silicon 与 Intel 最终 App 包继续引用同一份正确图标。

自动化不能证明：

- macOS 13 Finder、Launchpad 和 Dock 的最终视觉尺寸、阴影与图标缓存已经更新。
- 从旧版本覆盖安装后，Intel Ventura 不再暂时显示缓存中的旧正方形图标。

这些项目必须使用真实 Intel macOS 13 和最终安装包完成验收，不能以当前 Apple Silicon 或较新 macOS 的预览代替。
