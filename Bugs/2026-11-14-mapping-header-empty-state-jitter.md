# 按键页未连接空状态导致页头抖动

## 证据

2026-11-14 用户反馈：刚启动时按键页尚未连接遥控器，顶部过高；遥控器连上后顶部变矮，整个页面抖动。

用当前生产 `SettingsView` 的离屏入口复现，内容尺寸 `1020 × 772`，Retina PNG `2040 × 1544`：

- 未连接空状态：页头分隔线位于 `y=221–222`（Retina 像素）。
- 三张已连接设备卡：页头分隔线位于 `y=188–189`。
- 两者相差 `33px`，即 `16.5pt`；连接完成后分隔线、画布和工具行整体上移。

对照截图：

- 改动前空状态：`before-empty-zh-light-1020x772.png`，SHA-256 `8e666be763c68dab2ef2b9c384467b7bae9e4f3b693df6f791c7d5461ecee0ac`。
- 改动前设备卡：`before-cards-zh-light-1020x772.png`，SHA-256 `872ac1edd4d4ecca15f0f0ad82c38cc37268e65853d3a770e9f50e46e556d97d`。

## 根因

`Sources/RemoteMic/SettingsView.swift` 的按键页页头用 `HStack(alignment: .bottom, spacing: 14)` 放置标题区和右侧设备选择器，行高由两者中更高的一方决定。

`remoteDeviceEmptyState` 在未连接时使用纵向堆叠：图标、查找文案和“立即重新连接”按钮分成三行，加内边距后高于标题区约 `16.5pt`。连接完成后空状态被三行设备卡替换，设备卡低于标题区，行高回落到标题区高度，分隔线随之上移。问题不在设备卡本身，而在未连接空状态的高度。

## 修复

- 按键页的横向空状态改为紧凑单行：图标、查找文案和“立即重新连接”同一行排列。
- 文案最多两行，保留 `12pt` 字号和完整文本；按钮不压缩。
- 标题区仍是更高的一方，因此空状态与设备卡切换时页头行高由同一来源决定。
- 连接页的纵向空状态保留原布局；该页面没有这条页头底边对齐约束，不随本次修改变化。

## 验证

- 构建：`SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain -c debug --product RemoteMic` 通过。
- 定向自动化：`SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --disable-automatic-resolution --skip-update --filter 'SettingsPageRegression'`，79 项通过；新增 `mappingEmptyRemoteStateStaysOnOneCompactRow` 并单独复跑通过。
- 生产视图离屏渲染：`1020 × 772` 中文浅色、中文深色、英文浅色、英文深色四组中，未连接空状态和三张已连接设备卡的页头分隔线均位于 `y=188–189`，不再跳动。
- `800 × 650` 离屏压力渲染：中英文空状态文字为单行或两行，均未越过页头分隔线。
- 连接页纵向空状态与既有布局一致，未受影响。
- 改动后空状态截图 SHA-256：中文浅色 `bc438307d2ef35b89a2df367e23b82291f53eb13fb72c1b1a1f9713aa6abd2a5`，中文深色 `0f68323ee4293a351ef944588b0a5d91e4950937766c38e41dac0cc27ed941da`，英文浅色 `213dc47b5454f4d24136c99fc95bab8db2a44b508b602806bb0198b1a76f1ec0`，英文深色 `a3e4716ad6cadd11ce26aa98ffae58fe43f18e97cbb882bc13f12d7ffa39ca46`。
- 截图字节保存在仓库外 `~/Downloads/SayAll-mapping-header-jitter-20261114/`，不进入版本控制。

## 验证边界

- 离屏渲染只证明生产视图的静态布局和两种连接状态；真实蓝牙连接完成瞬间的窗口重绘、实体遥控器断连/重连和窗口缩放仍需现场验收。
- 未新增运行时日志：本问题由布局高度决定，不涉及连接状态判定或音频链路，日志不能提供额外归因。
