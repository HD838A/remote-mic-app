# Onboarding 首次启动窗口偏到屏幕角落并被裁切

- 时间：2026-08-24
- 状态：已修复，隔离 Bundle ID 的真实首次启动与异常 frame 恢复复验通过
- 影响范围：没有任何 SayAll 偏好记录、首次进入 Onboarding 的 macOS 用户
- 功能点：首次启动、Onboarding 窗口尺寸与位置

## 复现

使用正式 1.9.8 (131) App 的完整副本，将 Bundle ID 改为隔离测试域并 ad-hoc 重签，确保没有历史偏好数据后首次启动。没有修改正式 App 的设置，也没有退出正式 App。

测试屏幕 frame 为 `1512 × 982`，可用区域为 `1512 × 875`。首次启动进入欢迎页后，CoreGraphics 读取到生产窗口：

```text
width=980 height=764 x=755 y=252
```

因此窗口右边界为 `1735`、下边界为 `1016`，均超出屏幕 `1512 × 982`；实际窗口不在屏幕中央且内容显示不全。隔离偏好域同时产生：

```text
NSWindow Frame RemoteMicSettings = 755 729 1 1 0 0 1512 949
```

`runtime.log` 在同一时间只记录 `ONBOARDING STEP entered=welcome`，没有权限、蓝牙或页面状态错误，说明问题发生在窗口创建和布局阶段。

## 根因

`RemoteMicApp.makeSettingsWindowController` 将 `NSHostingController` 设为窗口内容后，只设置 `minSize`，没有先建立实际内容尺寸，随后立即启用 frame autosave 并调用 `center()`。首次启动时 SwiftUI 内容仍处于近似 `1 × 1` 的临时布局，系统以该尺寸完成居中；Onboarding 随后扩张到约 `980 × 764`，原点不再重新计算，于是窗口向右下越出屏幕。

Onboarding 截图渲染器没有该问题，因为它在 `center()` 前明确调用了 `setContentSize(1020 × 772)`。

## 修复

运行时窗口与截图窗口保持同一时序：设置 Hosting Controller 后，先调用 `setContentSize(1020 × 772)`，再启用 `RemoteMicSettings` frame autosave，最后调用 `center()`。不改变 Onboarding 页面结构、步骤、窗口可缩放能力或完成后的设置页面。

## 验证要求

1. 聚焦回归测试必须保证 `setContentSize` 位于 `setFrameAutosaveName` 和 `center()` 之前。
2. 使用新的隔离 Bundle ID 和空偏好域真实首次启动，读取窗口 frame，确认完整位于当前屏幕可用区域内且中心点与可用区域中心一致。
3. 写入历史异常 `1 × 1` autosave frame 后再次以未完成 Onboarding 状态启动，确认仍以完整尺寸居中。
4. 完成 Onboarding 的普通设置窗口保持 `1020 × 772` 默认尺寸、可缩放和可关闭；浅色/深色页面内容不因本修复变化。

本用例只验证窗口创建、尺寸和位置，不代替实体遥控器、iPhone、网页版、权限、音频或第三方语音工具验收。

## 修复版复验

2026-08-24 使用当前分支 Debug 可执行文件替换正式 App 副本中的可执行文件，保留完整生产 Bundle 结构、资源和 Sparkle Framework，再使用新的隔离 Bundle ID ad-hoc 重签。正式安装版继续运行，正式偏好数据未改动。

1. 空偏好域首次启动：窗口 frame 为 `1020 × 772 @ (246,59)`，完整位于当前 `1512 × 982` 屏幕内；autosave frame 为 `246 151 1020 772 0 0 1512 949`。
2. 手工写入原始失败现场的 `755 729 1 1 0 0 1512 949` 后重新启动：窗口仍恢复为 `1020 × 772 @ (246,59)`，异常 frame 被正确覆盖。
3. 将隔离域设置为已完成 Onboarding 后启动设置页：设置窗口仍为 `1020 × 772 @ (246,59)`。
4. 真实窗口截图确认欢迎页标题、说明、三项能力、右侧插画和底部“开始设置”按钮全部显示，页面没有内部滚动或边缘裁切。

自动化验证结果：设置页聚焦回归 24 项通过，Onboarding 回归 28 项通过，完整 `swift test` 共 330 项、31 个 Suite 全部通过，`SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh` 共 42 项全部通过。测试仅出现仓库已有的 `onChange` deprecated warning，没有本次新增告警。

尚未在外接显示器、低于设计最小尺寸的缩放分辨率和 Intel Mac 上完成真实窗口复验。
