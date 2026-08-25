# Icon Composer App 图标测试手册

## 适用范围

- 适用版本：包含 `Resources/AppIcon.icon` 三层图稿及其导出资源的开发分支、后续 `release/pre-v*` 候选。
- 图标源工程使用 Apple Icon Composer；当前 SwiftPM/App 打包仍消费已提交的 `AppIcon.png` 与 `AppIcon.icns`，以兼容 Apple Silicon macOS 14 及 Intel macOS 13。
- 本手册只验证 App 图标的编辑源、渲染和系统显示，不替代 Developer ID 签名、公证或完整发布验收。

## 测试前准备

1. 在安装了当前 Xcode 与 Icon Composer 的 macOS 上检出待测提交。
2. 确认 `Resources/AppIcon.icon`、`Resources/AppIconLayers/`、`Resources/AppIcon.png` 和 `Resources/AppIcon.icns` 均存在。
3. 准备一台 Apple Silicon macOS 14 或更高版本设备；Intel 兼容回归另准备真实 Intel macOS Ventura 13 设备。
4. 覆盖安装用例需保留已安装旧版无线麦，记录旧版和待测版的版本号、Build 与测试时间。

## 用例 1：Icon Composer 分层与三种外观

1. 使用 Icon Composer 打开 `Resources/AppIcon.icon`。
2. 确认唯一分组名称为 `SayAll`，从上到下依次为 `03-microphone`、`02-duck`、`01-signal`。
3. 依次切换 Default、Dark、Mono 外观，并查看 1024、256、64、32 和 16pt 预览。

预期结果：默认外观为蓝色系统材质背景，青色无线信号位于小鸭之后，麦克风位于前景；深色外观仍可分辨眼睛、嘴部、信号与麦克风；单色外观不丢失主体轮廓。64pt 及以上能同时识别小鸭、无线与语音，32pt 和 16pt 至少能稳定识别小鸭与麦克风轮廓。

失败判定：图层顺序变化、任一层缺失、元素在边缘被裁切、深色或单色外观主体消失、材质导致眼睛或麦克风不可辨，或小尺寸缩放后只剩无语义色块。

## 用例 2：从 Icon Composer 生成兼容资源

1. 运行 `scripts/render-app-icon.sh`。
2. 使用 `sips -g pixelWidth -g pixelHeight -g hasAlpha Resources/AppIcon.png` 检查主图。
3. 将 `Resources/AppIcon.icns` 展开为 iconset，确认存在 16、32、128、256、512 与对应 Retina 共十档 PNG。
4. 运行 `swift test --filter BuildSigningTests`。

预期结果：脚本只从 `AppIcon.icon` 的 macOS Default rendition 生成资源；主图为 `1024 × 1024` 且包含 Alpha；十档图层四角透明、中心不透明；测试全部通过。

失败判定：需要手工覆盖源文件、导出尺寸或平台错误、PNG 没有 Alpha、任一 `.icns` 图层缺失、四角不透明、中心透明，或测试失败。

## 用例 3：Finder、Launchpad 与 Dock 实际显示

1. 构建待测 `SayAll.app`，在 Finder 的图标视图和列表视图分别查看图标，并使用快速查看放大。
2. 把 App 放入 `/Applications` 后打开 Launchpad，分别在浅色与深色外观下查看。
3. 启动无线麦并在 Dock 查看普通、正在运行、未激活与放大状态；在 App 切换器中再检查一次。
4. 调整显示缩放后重复查看，不重启系统。

预期结果：所有位置均显示同一品牌图标；圆角由透明外缘自然呈现，不出现额外方形底色；小鸭、无线信号与麦克风居中且没有被系统遮罩裁切；浅色与深色桌面均有足够区分度。

失败判定：Finder、Launchpad、Dock 或 App 切换器显示旧图、白色/黑色方块、异常锐边、裁切、糊成色块，或不同位置使用了不一致的图标。

## 用例 4：覆盖安装与 Intel Ventura 缓存回归

1. 在真实 Intel macOS 13 上记录旧版图标，然后使用同一安装入口覆盖安装待测版本。
2. 不手工删除系统图标缓存，依次检查 Finder、Launchpad、Dock、App 切换器和“关于本机”的存储 App 列表。
3. 退出并重新启动无线麦，再注销并重新登录一次，重复检查。
4. 在 Apple Silicon macOS 14 或更高版本设备执行同一覆盖安装流程。

预期结果：覆盖安装后系统在正常刷新周期内显示新图标；Intel Ventura 不再把图标显示为不透明完整正方形；重新启动与重新登录后不会回退旧图。

失败判定：必须清空系统缓存或重装系统才能显示新图、任一入口长期保留旧图、Intel 重新出现完整正方形，或 Apple Silicon 与 Intel 显示不同资源。

## 稳定功能回归

- 菜单栏模板图标与连接状态图标保持原样，不被 App Icon 资源替换。
- `CFBundleIconFile` 继续指向 `AppIcon`，Apple Silicon 与 Intel 构建使用同一份 `.icns`。
- App 构建、签名结构、Sparkle 更新与安装器入口不因新增 `.icon` 编辑源而变化。
- 图标许可继续覆盖 PNG、ICNS、Icon Composer 工程和三份 SVG 源图层。

## 日志与证据收集

- 保存 Icon Composer 的 Default、Dark、Mono 与 16/32/64/256/1024pt 截图。
- 保存 `sips` 元数据、展开后的 iconset 文件名与 `BuildSigningTests` 输出。
- 系统显示问题需记录 macOS 版本、架构、显示缩放、外观、安装方式、旧版与新版版本号、发生位置和时间，并提供 Finder、Launchpad、Dock 的截图。
- 若怀疑缓存，先记录未经干预的结果；不要把手工清缓存后的显示当作覆盖安装已通过。

## 自动化、代理实测和用户实测边界

- 自动化可证明源工程结构、导出命令、PNG 尺寸与 Alpha、十档 ICNS 图层和 App 打包引用。
- 代理可在当前 Mac 使用真实 Icon Composer 检查三种外观，并在 Finder 查看本地 ad-hoc App；这不能证明其他系统版本的缓存行为。
- 真实 Intel Ventura 与 Apple Silicon macOS 14 的 Launchpad、Dock、覆盖安装和登录后缓存必须在对应真实设备完成；Developer ID 候选仍需按发布门禁单独签名、公证和复验。
