# Design QA — macOS 26 Liquid Glass 设置页

## 基准与截图

- 视觉基准：`/Users/andy/.codex/generated_images/019f8e88-5183-7e83-a916-ce5cf132815a/exec-9d9ca10f-4ff2-4a05-8baa-c362a2043668.png`（1354×1161）
- 实现视口：800×702 像素，对应 800×650 最小内容尺寸加系统标题栏
- 浅色截图：
  - `/Users/andy/.codex/visualizations/2026/07/23/019f8e88-5183-7e83-a916-ce5cf132815a/design-qa/connection-light.jpeg`
  - `/Users/andy/.codex/visualizations/2026/07/23/019f8e88-5183-7e83-a916-ce5cf132815a/design-qa/key-mapping-light.jpeg`
  - `/Users/andy/.codex/visualizations/2026/07/23/019f8e88-5183-7e83-a916-ce5cf132815a/design-qa/permissions-light.jpeg`
- 深色截图：
  - `/Users/andy/.codex/visualizations/2026/07/23/019f8e88-5183-7e83-a916-ce5cf132815a/design-qa/connection-dark.jpeg`
  - `/Users/andy/.codex/visualizations/2026/07/23/019f8e88-5183-7e83-a916-ce5cf132815a/design-qa/key-mapping-dark.jpeg`
  - `/Users/andy/.codex/visualizations/2026/07/23/019f8e88-5183-7e83-a916-ce5cf132815a/design-qa/permissions-dark.jpeg`

## 比较结果

- 全页结构：三个页面均保留窄侧栏、标题区和分层内容区；连接页、按键页、权限页与基准稿的信息分组一致。
- 聚焦状态：侧栏选中项和按键选中行使用低透明度蓝色交互玻璃，选择层级清晰且不会遮挡图标或文字。
- 字体：使用系统字体和语义字号，标题、分组标题、正文、辅助说明层级清楚；中英文与 HID 等宽文本无截断。
- 间距：800×650 最小内容尺寸下主要操作均可见；按键完整映射列表在独立滚动区中可访问；窗口放大后布局无裁切。
- 颜色与材质：浅色、深色均跟随系统；面板、状态胶囊和按钮使用 macOS 26 原生 Liquid Glass，没有手工模糊、固定白色卡片、渐变或额外阴影。
- 图片：复用 `RC003-remote-photo.png`，宽高比正确，按键热点与实物位置对应。
- 文案与功能：连接状态链、音频设置、豆包兼容、按键映射、权限状态和诊断入口均保留，未发现缺失或错位。
- 辅助显示：全部玻璃材质来自系统 `glassEffect` / `buttonStyle`，由系统处理降低透明度和增强对比度，不存在绕过系统辅助设置的自定义材质。

## 迭代记录

1. 初版深色检查发现侧栏选中态 tint 过饱和，判定为 P1。
2. 将侧栏选中态和按键选中行改为低透明度语义蓝 `.clear.tint(...)` 交互玻璃。
3. 重新构建并在浅色、深色、最小窗口和放大窗口下检查三页；未发现 P0、P1 或 P2 遗留问题。

## 最终结论

- P0: 0
- P1: 0
- P2: 0
- final result: passed
