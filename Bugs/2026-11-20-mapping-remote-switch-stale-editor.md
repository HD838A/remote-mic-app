# 切换遥控器后残留上一台设备的按键编辑区

- 时间：2026-11-20
- 状态：已修复，等待多遥控器真实窗口验收
- 影响范围：macOS 按键页；同时连接小米、苹果或 Chromecast 遥控器时
- 功能点：按键页设备切换、动作编辑区、动作分类胶囊、键位方案选择、语音键设置面板
- 简单描述：在一台遥控器上打开“主页键 / 单击”等编辑区后切到苹果遥控器，仍显示该编辑区和动作胶囊，并先显示页面顶部再滚动。
- 原始记录：用户现场反馈。小米遥控器选中主页键单击后切到苹果遥控器，苹果页面仍显示“主页键 单击”；打开动作胶囊后切换遥控器，胶囊仍存在且页面先到顶部再滚动。

## 错误证据

- 小米遥控器存在主页键，苹果遥控器没有主页键；`RemoteButton.xiaomiCases` 才包含 `.home`。
- 设备卡片可以切换到不同型号，按键页按型号分别显示小米、Siri 和 Chromecast 页面。
- 现象只在打开过按键编辑状态后出现；从页面顶部直接切换设备时不会出现旧编辑区。

## 根因

- 按键页在 `SettingsView` 中按当前遥控器型号切换 `mappingPage`、`siriRemoteMappingPage` 和 `chromecastMappingPage`，见 `Sources/RemoteMic/SettingsView.swift` 的 `.mapping` 分支。
- 设备切换清理原来挂在 `hardwareMappingPage` 内部。跨型号切换时整个页面子树被替换，旧的 `onChange` 不会执行。
- `mappingEditingTarget`、`mappingActionFilter`、`editingMappingProfileID` 等状态保存在 `SettingsView` 父层，因此不会随子树销毁。新页面继续把旧编辑目标当成有效状态。
- 新页面的 `onAppear` 又读取这个旧目标并异步滚到动作胶囊；同时 `.id(selectedRemoteProfileID)` 已经创建了从顶部开始的新滚动容器，于是出现“先顶部再滚动”。
- 页面状态没有设备标识，清理完成前旧状态仍可参与布局和滚动。

## 修复

- 把设备切换清理移到 `SettingsView` 父层，监听器不再位于会被型号页面替换的子树中。
- 增加 `mappingPageStateDeviceID`，旧遥控器的编辑区在清理前也不参与布局、onAppear 滚动和编辑面板显示。
- 切换设备时统一清空动作编辑目标、按住编辑、语音面板、快捷键捕获、动作筛选、方案选择、保存反馈和选中按键；新页面固定从顶部开始。
- 组合动作页跳转到指定按键时，先标记目标设备并清除旧面板状态，避免父层监听把刚设置的编辑目标清掉。
- `onAppear` 只恢复属于当前设备的编辑区，不再用旧目标滚动。

## 验证

- `swift build --disable-keychain` 通过。
- `swift test --disable-keychain`：1573 项测试、113 个 suite 全部通过。
- `swift test --disable-keychain --filter SettingsPageRegressionTests`：85 项通过。
- 新增回归断言：设备监听位于父层、跨型号页面状态带设备标识、编辑区和语音面板受设备标识门控、切换时清理动作筛选和方案选择。
- 需要真实窗口复验：小米“主页键 / 单击”切到苹果后编辑区消失、胶囊消失、页面停在顶部；苹果语音面板切回小米不残留；同型号双设备切换；从组合动作页跳转到按键仍能滚到目标编辑区。
