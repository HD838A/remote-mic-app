# 滚动区域与翻页动作

## 为什么开发

遥控器没有翻页键，长对话、长文档只能靠「向上滚动 / 向下滚动」一行一行移动，按住很久才能翻一屏。而且行级滚动固定打在前台窗口中心：窗口里有侧栏、标签条、正文、终端等多个滚动容器时，事件落到哪块全看几何位置。

本功能补两件事：**按页滚动**，以及**让每个 App 有一个明确的滚动区域**。

## 用户功能

- 「基础按键」组新增「向上翻页 / 向下翻页」两个动作，滚动当前前台 App 的内容区一屏。
- 原生支持翻页动作的 App 由系统定义一屏；其余 App 用分块行滚轮：每块 30 行（实测约 215 pt），块数按区域高度减 10% 计算并封顶 3 块，块间 60 ms，WorkBuddy 实测一次约 644 pt。
- 已完成真机验证的 App 默认可用、不需要学习：cmux、企业微信（原生翻页动作），Chrome、Slack、Codex（内容容器），WorkBuddy（整窗 WebArea 按窗口矩形）。其余 App 显示「需学习」，不凭 Bundle ID 猜测区域。
- 未验证的 App 与自定义 App 需要学习一次：按键映射页的自定义 App 区块里点「学习滚动区域」，倒计时内点一下要翻页的区域（也可以不点，以指针位置为准）。验证过的 App 也可以学习，用来覆盖默认区域。
- 提供「测试向上翻页 / 测试向下翻页」和「恢复预置」；测试会真实翻一次，并报告内容是否移动。
- 只有不在预置列表里的 App 才显示「需学习」；预置 App 一律显示「预置可用」。

## 范围与非目标

- 不定义按住连发：间隔、白名单、松手停止由独立的连发策略处理，本功能只决定「一次触发滚多少」。
- 不做键盘焦点导航，不移动焦点、不移动指针、不点击区域中心。
- 不读取区域内容：只读 role、identifier、祖先结构、frame 和 action 名称，不读 `AXValue`、不截图。
- 不做覆盖层提示：确认靠真实翻页与结构位移（role + identifier + 尺寸），不做内容比对、不在 SayAll 窗口里画框。
- 不把记录写进输入框字段：滚动区域是独立字段，与 `accessibilityTarget` 并列、互不覆盖。

## 实现

- `Sources/RemoteMic/ScrollRegionTarget.swift`：区域记录模型、预置规则、页步长、方向语义、预置筛选与匹配评分（纯逻辑，可单测）。
- `Sources/RemoteMic/ScrollRegionInjector.swift`：Accessibility 遍历、点击命中抓取（窗口优先取 `AXWindow` 属性，父链遍历到 40 层）、翻页执行（先试 `AXScrollUpByPage` / `AXScrollDownByPage`，否则向区域中心分块投递行滚轮；每块前重新校验前台 App 与窗口，切换即取消剩余块）。
- `Sources/RemoteMic/RemoteButtons.swift`：两个动作、独立的 `scrollRegionTarget` 字段、不参与按住连发。
- `Sources/RemoteMic/KeyboardInjector.swift`：动作执行接入口。
- `Sources/RemoteMic/AppSettings.swift`：配置持久化、便携配置校验、完整备份不迁移区域记录。

## 隐私与兼容

- 只使用公开 Accessibility 接口，不读取其他 App 的文件、数据库、私有协议或沙盒内容。
- 日志只记 bundle、方向、策略、结果、是否验证到位、耗时，不记标题或内容。
- 完整 `.sayall` 备份与按键级 / 便携导出都不携带区域记录，导入后要求重新学习。
- 旧配置没有该字段时按「未学习」处理；新动作只在 macOS 提供，Windows 侧不映射成其他行为。

## 当前状态

自动化：20 项滚动区域测试通过（块数换算、方向、预置白名单、匹配与歧义、矩形越界、配置兼容、动作分组与连发白名单），全量 1099 项通过。

待真机验收：真实遥控器逐 App 触发、Electron 是否接受像素滚轮、原生翻页动作是否真的滚动、系统「自然滚动」下的方向、全屏与多显示器。步骤见 [`Testing/ScrollAreaPageActions.md`](../../Testing/ScrollAreaPageActions.md)。
