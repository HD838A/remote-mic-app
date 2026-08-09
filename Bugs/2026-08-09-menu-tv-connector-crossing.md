# Menu and TV Connector Crossing Follow-up

- 时间：2026-08-09
- 状态：UI 缺陷已修复
- 影响范围：按键映射页面；菜单键与 TV 键
- 功能点：映射连线排序
- 简单描述：菜单键和 TV 键的目标卡片排序不符合实体按键高度，造成两条连线交叉。
- 原始记录：DEBUG.md，首次记录 b79fd0a

## 详细过程

## Observations

- The initial curve conversion still placed the physical Menu button, located on the lower-left of the remote, in the right card column beside TV.
- Its hidden segment crossed behind the remote and emerged near the physical TV button, making the Menu and TV connectors appear swapped and intersecting.

## Fix

- Move Menu to the bottom of the left card column and keep TV at the bottom of the right card column.
- Move the central OK card to the right column and redistribute both columns so hardware-anchor height and card-target height remain monotonic on each side.

## Validation

- The layout regression now requires Menu on the left, TV on the right, and non-decreasing hardware-anchor heights for every card column.
- The focused 3-test mapping suite and Production build passed.
- Visual inspection at `1020 x 772` confirmed that Menu connects directly left, TV connects directly right, and neither line crosses another connector.
