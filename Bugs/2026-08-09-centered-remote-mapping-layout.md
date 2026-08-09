# Centered Remote Mapping Layout

- 时间：2026-08-09
- 状态：UI 缺陷已修复
- 影响范围：macOS 设置页；按键映射最小窗口
- 功能点：遥控器映射可视化布局
- 简单描述：旧映射布局不够直观，遥控器与配置项、连线和按键名称缺少一一对应的空间关系。
- 原始记录：DEBUG.md，首次记录 5bceb5c

## 详细过程

## Fix

- Place the physical remote at the horizontal center and arrange all 12 configurable button cards beside their corresponding hardware controls.
- Draw each connector from the existing calibrated hardware hotspot to the adjacent card edge, with a visible start dot and endpoint arrow.
- Show the real single-click, double-click, and long-press configuration inside every card; keep the microphone key as a fixed voice/Fn card.
- Keep the remote selector, mapping enable control, selection lock, voice Fn-tap mode, and restore-default action visible without requiring page scrolling at the `1020 x 772` minimum window.

## Validation

- The focused mapping regression suite passed all 3 tests, including exact coverage of every real remote button and connector anchor.
- All 144 Swift tests and all 42 low-level self tests passed.
- The Production app built, signed, verified, and launched from `dist/Remote Mic.app`.
- Connection, Mapping, Statistics, Permissions, and About were each opened at the minimum window size without clipped headers or primary controls.
- The mapping page displayed the centered remote, all 12 configurable cards, the fixed microphone card, both footer switches, and Restore Defaults on one screen; clicking Up / Single Click opened the matching editor.
