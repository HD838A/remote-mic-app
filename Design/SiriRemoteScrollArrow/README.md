# Siri Remote 滚动箭头设计稿

本目录保存本轮重新设计的滚动反馈视觉稿。三张 PNG 均为生成后原始字节的本地副本，未缩放或重压缩。

设计约束：

- 以 macOS `controlAccentColor` 蓝色为主色，保持与 SayAll 设置页一致。
- 滚动反馈围绕原生光标显示，不能覆盖光标热点。
- 滚动提示表达页面右侧滚动指示器的上/下方向，不再显示硬件顺时针或逆时针。
- 采用 `scroll-arrow-refine-2-orbit-notch.png` 的 Orbit 缺口与开口 Chevron 语言：光环在右侧留出方向缺口，缺口内只显示向上或向下箭头。
- 箭头数量表达速度：慢速 1 个、正常 2 个、快速 3 个；数量只能在 `1...3` 内变化，光环仍与鼠标移动反馈共用基础尺寸和速度缩放曲线。
- 设置页允许选择箭头“与页面右侧滚动指示器一致”或“相反”；该设置只改变视觉反馈，不改变实际滚动事件、自然滚动或 iPod 转盘方向。

候选方向：

1. `scroll-arrow-design-1-swift-halo-arc.png`：单段光环弧线 + 切线箭头。
2. `scroll-arrow-design-2-segmented-chevron.png`：分段弧线 + 双线 Chevron。
3. `scroll-arrow-design-3-comet-arc.png`：渐隐彗尾弧线 + 开口 V 形箭头。

## 第 3 方向精修稿

基于第 3 个方向进一步减少装饰感并强化小尺寸可读性：

- `scroll-arrow-refine-1-short-tapered-open-v.png`：短渐缩弧线 + 单个开口 V。
- `scroll-arrow-refine-2-orbit-notch.png`：弧线端点 + 双 Chevron 缺口。
- `scroll-arrow-refine-3-quiet-speed.png`：最弱光晕，并展示慢速/快速只拉长弧线的关系。

生成尺寸：1536 × 1024 PNG。

## 确认后的实现方向

- 视觉基线：`scroll-arrow-refine-2-orbit-notch.png`。
- 页面方向来源：使用已经提交给 macOS 的滚动像素正负值；正值显示滚动指示器向上，负值显示滚动指示器向下。选择“相反”时仅反转箭头。
- 速度分级：低速至少显示 1 个箭头，中速显示 2 个，高速最多显示 3 个；分级必须保持单调。
- 箭头位置：位于围绕原生光标的主题色光环右侧缺口，不覆盖系统光标或点击热点。

## 实现审查产物

生产反馈视图导出的实现截图保存在 `Implemented/`，均为 `208 × 208 PNG`；其中：

- `light-scroll-up-slow.png`：向上、慢速、1 个箭头。
- `light-scroll-down-medium.png`：向下、正常速度、2 个箭头。
- `light-scroll-up-fast.png`：向上、快速、3 个箭头。
- `dark-*`：对应深色外观，使用窗口背景色分隔描边，避免多个箭头粘连成实心块。

苹果遥控器按键页的生产 App Bundle 截图保存在 `Settings/app-light/` 与 `Settings/app-dark/`，均为 `1600 × 1300 PNG`（逻辑窗口 `800 × 650`）。方向开关位于遥控器图和键位列表之前，中文标题 13pt、说明 12pt；页面可继续纵向滚动访问全部按键。
