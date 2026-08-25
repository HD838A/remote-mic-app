# 标题栏侧栏按钮被错误替换

## 复现

- 环境：macOS 设置窗口，浅色外观。
- 操作：把无线麦标题栏的“显示边栏”按钮与同屏系统设置工具栏按钮对比。
- 实际结果：为修正截图中的尺寸差异，自动侧栏按钮一度被移除并替换为手工 `Button`。
- 预期结果：由 `NavigationSplitView` 自动创建和管理侧栏按钮，应用只保证工具栏继承常规控件尺寸。

## 日志

检查最近 30 分钟的 `RemoteMic` unified log，只看到 TCC 权限请求、偏好读取和 AppKit scene 更新，没有侧栏切换或窗口异常。截图中按钮图标和功能入口均存在，因此问题限定在工具栏按钮边框形状。

## 根因

最初的异常来自根级 `.controlSize(.large)` 传播到系统 toolbar item，并非自动 `.sidebarToggle` 本身需要替换。把尺寸环境下沉到侧栏后，继续移除自动项并手工复刻系统按钮属于过度修复，还引入了重复 action、图标、边框和本地化文案。

## 修复

- 恢复 `NavigationSplitView` 自动生成的侧栏工具栏项。
- 删除 `toolbar(removing:)`、手工 toolbar item、手工 `Button`、SF Symbol、边框形状、responder-chain action 和专用本地化文案。
- 保持 `NavigationSplitView` 根和 detail 为 `.regular`，仅让侧栏搜索与侧栏内容使用 `.large`。

## 验证

- 源码门禁要求默认 toggle 不得被移除或替换，且根级控件尺寸保持 `.regular`；30 项设置页定向测试通过。
- 使用 Xcode 27 完成 342 项全量测试（32 个 suite）、本地 App 构建和 `scripts/verify-app.sh`，均通过。
- 中文浅色/深色 `800 × 650` 与浅色 `920 × 700` 共 21 张成品预览已生成并检查；真实 App 中系统按钮实际完成收起和重新展开，辅助功能名称在“隐藏边栏 / 显示边栏”之间自动切换。
- 浅色/深色、默认和最小尺寸下逐一悬停检查仍需人工完成，离屏截图不能替代该状态。
