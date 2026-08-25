# 设置窗口缺少标准菜单、快捷键与窗口位置记忆

## 复现

- 环境：macOS 27,`dist/SayAll.app` 调试构建;对照同机「系统设置」。
- 操作:激活设置窗口,检查菜单栏;按 ⌘M / ⌘H / ⌘F / ⌘[ / ⌘];移动窗口后关闭重开。
- 实际结果:菜单栏只有 App(仅退出)/ 文件 / 编辑三个菜单;⌘M、⌘H、⌥⌘H、⌘F、⌘[、⌘] 全部无效;窗口每次强制居中,不记忆上次位置;侧栏可拖宽 220~280pt,系统设置侧栏固定;状态栏「关于」弹老式 NSAlert,与设置内关于页是两套。
- 预期结果:标准 App/显示/窗口菜单与快捷键可用,窗口位置由系统记忆,侧栏固定 232pt,「关于」直接进入设置关于页。

## 日志结论

纯菜单与窗口行为问题,`~/Library/Logs/RemoteMic/runtime.log` 无相关条目;界面布局不写专用日志。

## 根因

- `RemoteMicApp.swift` 自建 `mainMenu` 只装配 App/文件/编辑三个菜单;本地键盘监听只处理 ⌘Q/⌘W,标准快捷键没有菜单项承载。
- `makeSettingsWindowController` 在 `setFrameAutosaveName` 后无条件 `window.center()`,覆盖了 autosave 恢复的位置。
- 侧栏 `navigationSplitViewColumnWidth(min: 220, ideal: 232, max: 280)` 允许拖动。
- `showAbout` 是重构前遗留的 NSAlert 实现,未接入设置关于页。

## 修复

- 菜单栏补全:App 菜单(关于、隐藏 ⌘H、隐藏其他 ⌥⌘H、全部显示、退出 ⌘Q)、编辑菜单末尾「查找 ⌘F」、新增显示菜单(返回 ⌘[、前进 ⌘])与窗口菜单(最小化 ⌘M、缩放、全部移到前台,并设为 `NSApp.windowsMenu`);标准动作 target=nil 走 responder chain。
- 新增 `SettingsNavigationCoordinator`:App 菜单命令经 PassthroughSubject 路由进 SwiftUI;`validateMenuItem` 按窗口与历史状态启停返回/前进/查找;`.searchFocused` 为 macOS 15+ API,用 `#available` 扩展 `searchFocusedWhenAvailable`,macOS 14 上菜单项诚实禁用。
- 窗口位置:`setContentSize` → `setFrameAutosaveName` → 仅 `setFrameUsingName` 失败(无存档)时才 `center()`。
- 侧栏锁定 `min: 232, ideal: 232, max: 232`。
- `showAbout` 改为打开设置窗口关于页(复用 `selectSection` 命令),删除 NSAlert 与 `about.alert.description_with_version` 文案。
- 新增菜单文案使用 `menu.view / menu.window / menu.find / menu.hide_app / menu.hide_others / menu.show_all / menu.minimize / menu.zoom / menu.bring_all_to_front` 新语义 key,中英 strings 同步。

## 验证

- 修复前:⌘M/⌘H/⌘F/⌘[/⌘] 无响应,窗口重开总是居中。
- 修复后:31 项设置页定向测试(含新增 `systemSettingsInteractionAlignmentRound` 门禁)、344 项全量测试(32 个 suite)通过;Xcode 27 工具链 `CONFIGURATION=debug scripts/build-app.sh` 与 `scripts/verify-app.sh dist/SayAll.app` 通过;`git diff --check` 通过。
- 真实窗口:800×674 存档位置退出重开后窗口精确恢复在 `-1427,-126`,不再强制居中;真实窗口与中文浅色/深色、英文 `800 × 650` 离屏渲染逐页检查通过。

## 验证边界

本会话无辅助功能权限,⌘F/⌘[/⌘]/⌘M/⌘H 的实际按键触发、菜单项逐一点击、隐藏/最小化行为未做代理实测,按 `Testing/NativeSettingsInterface.md` 人工复核;实体遥控器、音频回环、iPhone/Watch、网页版连接不在本轮范围。
