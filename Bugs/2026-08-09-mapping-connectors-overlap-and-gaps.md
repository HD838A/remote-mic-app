# Mapping Connector Overlap and Excessive Side Gaps

- 时间：2026-08-09
- 状态：UI 缺陷已修复
- 影响范围：按键映射页面
- 功能点：连线曲线与页面空间利用
- 简单描述：映射连线过长、互相重叠，遥控器居中区域空而两侧配置拥挤。
- 原始记录：DEBUG.md，首次记录 b79fd0a

## 详细过程

## Observations

- Orthogonal connectors reused the same elbow X coordinate for buttons sharing an anchor column, creating visibly overlapping vertical segments.
- The 250-point setting cards left roughly 96 points between each card edge and the centered remote at the minimum window width, making the middle look empty while card contents remained compressed.

## Fix

- Replace shared-elbow polylines with cubic curves whose control points leave the exact hardware hotspot and approach the exact card edge from the correct side.
- Increase the card width to 285 points at the minimum layout and enlarge the remote proportionally from `174 x 352` to `184 x 372`, shortening the connectors without changing any hotspot coordinates or card order.

## Validation

- Layout regressions verify all original start/end anchors, left/right curve control direction, and the 285-point minimum-layout card width.
- Visual inspection at `1020 x 772` confirmed that connectors no longer share full segments, the lower-button curves fan out separately, all content remains on one screen, and the footer controls remain fully visible.
