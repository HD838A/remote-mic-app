# 常用 macOS 快捷键

## 为什么开发

遥控器按键映射需要覆盖高频的窗口与文本编辑动作；无线麦自身也应遵循 macOS 用户对 `Command-Q` 和 `Command-W` 的标准预期。

## 用户功能

- “基础按键”提供 `Command-W`、`Command-X`、`Command-A`、`Command-Z`、`Command-Shift-Z`、`Command-F`、`Command-S`。
- 保留已有的 `Command-Return`、`Shift-Return`、`Command-C`、`Command-V` 和 `Command-Q`。
- 无线麦自身支持 `Command-Q` 退出和 `Command-W` 关闭当前窗口。

## 范围与非目标

- 固定快捷键只发送一次，不支持按住重复。
- 不替代“自定义快捷键”；没有加入会新建窗口或打开文件选择器的 `Command-N`、`Command-O`。
- 不改变已有动作的 raw value、用户映射或配置导入导出结构。

## 关键实现与涉及文件

- `Sources/RemoteMic/RemoteButtons.swift`：定义动作、显示名、分类和重复策略。
- `Sources/RemoteMic/KeyboardInjector.swift`：发送对应键码和修饰键。
- `Sources/RemoteMic/RemoteMicApp.swift`：安装标准应用菜单和文件菜单。
- `Tests/RemoteMicTests/RemoteButtonsTests.swift`：验证分类、禁止重复和键码。

## 隐私与兼容边界

快捷键仍通过现有辅助功能权限路径发送，不读取键盘内容。新增枚举 case 使用独立 raw value，旧配置可以继续解码。

## 验证与状态

当前状态：已实现。动作分类、重复策略、键码、项目自检、应用构建和验证脚本均通过；桌面实测确认 `Command-W` 关闭设置窗口但保留进程，`Command-Q` 退出进程。实体遥控器触发仍需按 [`testing.md`](testing.md) 完成人工验收。
