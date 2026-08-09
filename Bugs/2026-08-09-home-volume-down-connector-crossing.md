# Home and Volume-down Connector Crossing Follow-up

- 时间：2026-08-09
- 状态：UI 缺陷已修复
- 影响范围：按键映射页面；主页键与音量减
- 功能点：映射卡片分栏和连线排序
- 简单描述：主页键被放到遥控器右侧配置列，与音量减连线交叉且不符合实体位置。
- 原始记录：DEBUG.md，首次记录 b79fd0a

## 详细过程

## Observations

- Home is the lower-left physical button while Volume Down is the matching lower-right button, but both cards were placed in the right column.
- Routing Home across the remote into the right column caused its curve to intersect the Volume Down path and made the card placement feel physically incorrect.

## Fix

- Move Home to the left card column and keep Volume Down in the right card column.
- Move the central Down card to the right column to preserve balanced column counts and monotonic connector ordering.

## Validation

- The layout regression now explicitly requires Home on the left and Volume Down on the right, in addition to the existing per-column monotonic anchor check.
- The focused 3-test mapping suite and Production build passed.
- Visual inspection at `1020 x 772` in the current light appearance confirmed separate Home and Volume Down paths with no new connector crossing.
