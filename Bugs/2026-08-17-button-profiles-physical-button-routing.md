# 键位方案实体按键未选中并触发错误音

## 复现条件

1. 打开“组合动作”中的“键位方案”页面。
2. 使用鼠标点击遥控器图片中的 TV 键。
3. 再按真实遥控器的 OK、方向键或其他已经配置普通映射的按键。

## 错误行为与正常边界

- 鼠标点击图片热点可以切换“当前按键”，说明遥控器图片热点本身正常。
- 实体按键不会更新键位方案页面当前按键，也不会在图片上显示对应选择。
- 实体按键仍执行普通按键映射；无线麦设置页前台时，部分无有效目标的键盘动作会产生系统错误提示音。
- 正常行为应为：键位方案页面处于编辑状态时，实体按键只用于选择页面中的按键，不执行普通映射或当前方案动作；离开页面后恢复正常执行。

## 日志证据

现场日志 `/Users/andy/Library/Logs/RemoteMic/runtime.log` 记录到：

```text
2026-08-16T18:40:07Z HID BUTTON button=ok trigger=singleClick action=returnKey
2026-08-16T18:40:13Z HID BUTTON button=up trigger=singleClick action=commandReturn
```

日志证明按键进入 HID 路由后仍执行了普通动作，而不是只作为编辑页选键输入。

## 根因

- `BridgeAppModel.makeHIDMonitor()` 的 `monitor.onButtonPressed` 只更新宿主的 `lastRemoteButtonPress`、遥控器 Profile 和统计，没有调用私有模块已经提供的 `noteButtonInteraction(button:)`。
- 宿主集成层没有暴露该转发入口，因此键位方案页面订阅的最近交互按键状态永远收不到真实遥控器事件。
- `onButtonPressed` 固定返回 `shouldPerformAction = true`，没有识别键位方案页面正在编辑，导致同一次实体按键继续进入原普通映射或方案动作执行路径。

## 修复范围

- 宿主转发实体按键交互给私有模块。
- 键位方案独立侧边栏页面激活时，将 HID 按键路由切换为“只选择、不执行”；离开页面后恢复执行。
- 不改变普通按键页面、组合动作页面、移动端遥控或语音按键路径。

## 验证要求

- 自动化验证实体按键通知存在，编辑页激活时 `shouldPerformAction` 为 `false`，离开页面后为 `true`。
- 鼠标点击遥控器热点仍可选择按键。
- 真实遥控器在键位方案页逐一按下可见按键时，图片选择同步变化且没有错误音。
- 真实遥控器验收前，只能声明代码、模拟和构建验证通过，不能声明真机问题已验收。
