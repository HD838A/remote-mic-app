# Chrome 键位方案方向快捷键失效

## 复现场景

1. 为 Chrome 创建自动键位方案。
2. 将遥控器左右键绑定为 `Command + Option + 左/右箭头`。
3. 让 Chrome 位于前台并打开多个标签页。
4. 按遥控器左右键。

错误行为：无线麦SayAll.app 记录按键已进入键位方案，但 Chrome 不切换标签页。

正常边界：在同一 Chrome 窗口直接按物理键盘快捷键可以切换标签页。

## 日志结论

HID 日志只能证明事件进入 `private_feature` 路由，不能证明合成键盘事件已被 Chrome 接受。详细假设和实验见 `DEBUG.md`。

## 根因

页面内录入的快捷键没有复用宿主成熟的 `KeyboardInjector`，而是异步包装为临时组合动作；HID 入口在实际投递前就返回成功，现有测试也只验证绑定存在，没有验证执行器被调用。方向键注入还缺少真实扩展键常见的 Numeric Pad 标志。

## 修复

- 单快捷键绑定同步交给宿主键盘注入器，失败可返回调用方。
- 方向键快捷键补齐 Numeric Pad 标志，保留 Command、Option 等用户修饰键，并继续忽略旧数据中的伪 Fn。
- 日志新增实际 keyCode、修饰键和 handled 结果。

## 验证

- 私有模块定向测试验证保存的 Chrome 下一标签页快捷键会同步传递 keyCode 124、Command、Option。
- 宿主定向测试验证最终 flags 为 Command、Option、NumericPad。
- 2026-08-18 用户使用真实 Chrome 与实体遥控器确认 `Command + Option + 左/右箭头` 可以切换标签页。
- 自动化仍负责防止执行路径和 flags 回归，用户实测负责确认 WindowServer 与 Chrome 的最终可见结果。
