# Chrome 键位方案方向快捷键调试记录

## 观察

- 用户确认在 Chrome 中直接按物理键盘 `Command + Option + 左/右箭头` 可以切换标签页。
- 同一快捷键通过遥控器键位方案执行时，Chrome 标签页没有变化。
- `~/Library/Logs/RemoteMic/runtime.log` 在用户测试时间段记录了 `HID BUTTON ... action=private_feature`，说明 HID 事件已进入私有功能路由，但日志没有记录最终 keyCode、修饰键和 Chrome 的结果。
- 录入层已经会从方向键快捷键中移除 macOS 自动附带的 Fn 标志，但真实 Chrome 场景仍失败。
- 页面中的快捷键文字被截断，不能仅凭 UI 文案判断持久化值是否正确。

## 待验证假设

1. 执行时的方向键事件仍携带 `.maskSecondaryFn` 或其他不应存在的修饰标志。
2. 方向键事件缺少真实键盘会携带的扩展键标志，Chrome 因而不把它识别为方向键快捷键。
3. 只给主键事件设置组合 flags、没有分别发送修饰键按下与释放，Chrome 不接受该事件序列。
4. 保存的 keyCode 或 modifiers 与页面显示不一致。
5. 私有键位方案虽然返回“已处理”，但没有真正执行对应快捷键，或执行后被编辑页面的选键拦截逻辑覆盖。
6. 页面内录入的快捷键绕过宿主成熟注入器，异步包装成一次临时组合动作；入口立即返回成功，实际投递结果不可见且没有执行级回归测试。

## 实验记录

- 读取本机 `button-profiles.json` 与 `local-automation-profiles.json`：Chrome 左右键分别引用 keyCode 123/124，修饰键为 Command、Option，排除保存值错误。
- 运行日志显示 Left/Right 已进入 `private_feature`，且不在“设置按键”拦截状态，排除修复前的原生方向键提前透传问题。
- 代码检查确认宿主动作会同步进入 `KeyboardInjector`；页面内录入快捷键则通过 `Task → MacroRuntime → RemoteMicMacroExecutor` 异步投递，但 `executeBoundAction` 在任务开始前就返回 `true`。
- 既有测试 `savedShortcutCanBeReusedByAButtonProfile` 只断言绑定可以读取，从未调用快捷键执行器；所谓“通过”不能证明键盘事件已投递。
- 在当前自动化进程中尝试 Quartz 和 System Events 时，连 `Command + T` 也无法送达 Chrome，因此该进程不能作为真实 Chrome 结果的有效验收环境；没有把这组失败误判为具体 flags 根因。
- 新增定向测试后，录入快捷键会同步调用宿主 performer，并把 keyCode 124 与规范化后的 Command、Option 传给宿主；宿主测试确认方向键投递补齐 `.maskNumericPad`。

## 根因

页面内录入的快捷键使用了一条与普通按键、宿主动作不同且没有执行级测试的异步注入路径。该路径在实际键盘事件产生前就向 HID 层报告“已处理”，既无法把投递失败返回给调用方，也让现有日志形成假成功。方向键事件还缺少真实扩展键常见的 Numeric Pad 标志。

## 修复与回归

- 键位方案的单快捷键绑定不再包装成临时组合动作，改为同步交给宿主 `KeyboardInjector`。
- 宿主统一解析修饰键并记录 keyCode、修饰键与 handled 结果；方向键补齐 `.maskNumericPad`，旧记录继续忽略展示层的伪 Fn。
- 私有模块测试锁定“执行时同步调用 performer”，宿主测试锁定 `Command + Option + Right + NumericPad` flags。
- 自动化只能证明生产路由、参数和注入调用正确；最终 Chrome 标签页变化仍必须用签名 App、真实 Chrome 与真实遥控器验收。
